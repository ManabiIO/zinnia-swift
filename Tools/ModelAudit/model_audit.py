#!/usr/bin/env python3
"""Audit a Zinnia v1 model without loading native code or changing its weights."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import unicodedata
import xml.etree.ElementTree as ET
import zipfile


MAGIC_ID = 0x0EF71821
FORMAT_VERSION = 1
HEADER = struct.Struct("<III")
FEATURE = struct.Struct("<if")
FLOAT = struct.Struct("<f")
HERE = Path(__file__).resolve().parent
MAX_MODEL_BYTES = 256 * 1024 * 1024


class AuditError(ValueError):
    """The artifact is malformed or the audit inputs are inconsistent."""


@dataclass(frozen=True)
class Model:
    byte_count: int
    sha256: str
    git_blob: str
    format_version: int
    labels: tuple[str, ...]
    feature_count: int


def parse_model(data: bytes) -> Model:
    """Read the exact little-endian, 32-bit layout used by Zinnia's converter.

    Bounds are checked before every read; malformed data never reaches the
    native recognizer. This audits bundled artifacts, not arbitrary dictionaries
    from untrusted users. It does not estimate recognition accuracy.
    """
    size = len(data)
    if size < HEADER.size:
        raise AuditError("truncated model header")
    if size > MAX_MODEL_BYTES:
        raise AuditError(f"model exceeds the {MAX_MODEL_BYTES}-byte audit limit")
    magic, version, class_count = HEADER.unpack_from(data)
    if magic ^ MAGIC_ID != size:
        raise AuditError("model size/magic mismatch")
    if version != FORMAT_VERSION:
        raise AuditError(f"unsupported model version: {version}")
    # Even a zero-feature class needs 16 label bytes, a bias and a sentinel.
    if class_count == 0 or class_count > (size - HEADER.size) // 28:
        raise AuditError("invalid class count for model length")

    offset = HEADER.size
    labels: list[str] = []
    seen: set[str] = set()
    feature_count = 0
    for class_index in range(class_count):
        if offset + 20 > size:
            raise AuditError(f"truncated class header at class {class_index}")
        label_bytes = data[offset : offset + 16]
        terminator = label_bytes.find(b"\0")
        if terminator <= 0:
            raise AuditError(f"empty or unterminated label at class {class_index}")
        try:
            label = label_bytes[:terminator].decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise AuditError(f"invalid UTF-8 label at class {class_index}") from error
        if label in seen:
            raise AuditError(f"duplicate label: {label!r}")
        bias = FLOAT.unpack_from(data, offset + 16)[0]
        if not math.isfinite(bias):
            raise AuditError(f"non-finite bias for {label!r}")
        offset += 20
        previous_index = -1
        while True:
            if offset + FEATURE.size > size:
                raise AuditError(f"missing feature sentinel for {label!r}")
            index, value = FEATURE.unpack_from(data, offset)
            offset += FEATURE.size
            if index == -1:
                break
            if index < 0:
                raise AuditError(f"invalid feature index for {label!r}: {index}")
            if index <= previous_index:
                raise AuditError(f"feature indices are not strictly increasing for {label!r}")
            if not math.isfinite(value):
                raise AuditError(f"non-finite feature for {label!r}")
            previous_index = index
            feature_count += 1
        seen.add(label)
        labels.append(label)
    if offset != size:
        raise AuditError(f"trailing model data: {size - offset} bytes")

    return Model(
        byte_count=size,
        sha256=hashlib.sha256(data).hexdigest(),
        git_blob=hashlib.sha1(b"blob " + str(size).encode("ascii") + b"\0" + data).hexdigest(),
        format_version=version,
        labels=tuple(labels),
        feature_count=feature_count,
    )


def read_model(path: Path) -> Model:
    if path.stat().st_size > MAX_MODEL_BYTES:
        raise AuditError(f"model exceeds the {MAX_MODEL_BYTES}-byte audit limit")
    # Bound the actual read as well as the stat: the file may grow or be replaced
    # between these operations. One extra byte lets parse_model reject overflow.
    with path.open("rb") as model_file:
        data = model_file.read(MAX_MODEL_BYTES + 1)
    return parse_model(data)


def label_inventory(labels: tuple[str, ...]) -> str:
    """Canonical UTF-8 inventory, scalar-order sorted with one trailing LF."""
    if any("\n" in label or "\r" in label for label in labels):
        raise AuditError("newline in label cannot be represented in the inventory")
    return "".join(label + "\n" for label in sorted(labels))


def label_kind(label: str) -> str:
    if len(label) != 1:
        return "multiple_scalars"
    codepoint = ord(label)
    if 0x3040 <= codepoint <= 0x309F:
        return "hiragana_block"
    if 0x30A0 <= codepoint <= 0x30FF:
        return "katakana_block"
    if 0x4E00 <= codepoint <= 0x9FFF:
        return "cjk_unified_ideographs"
    if "0" <= label <= "9":
        return "ascii_digits"
    return "other"


def load_repertoire(path: Path) -> dict:
    repertoire = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(repertoire, dict) or repertoire.get("schema_version") != 1:
        raise AuditError("unsupported repertoire manifest schema")
    groups = repertoire.get("groups")
    if not isinstance(groups, dict) or not groups:
        raise AuditError("repertoire manifest has no groups")
    for name, group in groups.items():
        if not isinstance(group, dict):
            raise AuditError(f"invalid repertoire group: {name}")
        labels = group.get("labels")
        if not isinstance(labels, str) or not labels or len(set(labels)) != len(labels):
            raise AuditError(f"invalid or duplicate repertoire labels in {name}")
        if unicodedata.normalize("NFC", labels) != labels:
            raise AuditError(f"repertoire labels must be NFC in {name}")
        if not isinstance(group.get("required_for_modern_kana"), bool):
            raise AuditError(f"missing kana requirement flag in {name}")
    return repertoire


def fixture_coverage(path: Path, available: set[str]) -> dict:
    """Check expected labels in Tegaki XML; do not mislabel this as accuracy."""
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        raise AuditError(f"invalid fixture XML in {path.name}: {error}") from error
    labels = []
    for character in root.iter("character"):
        label = character.findtext("utf8")
        if not label:
            raise AuditError(f"fixture character has no label in {path.name}")
        labels.append(label)
    if not labels:
        raise AuditError(f"fixture contains no characters: {path.name}")
    absent = set(labels) - available
    return {
        "file": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "sample_count": len(labels),
        "unique_label_count": len(set(labels)),
        "samples_with_absent_label": sum(label in absent for label in labels),
        "missing_labels": sorted(absent),
    }


def make_report(model: Model, repertoire: dict, fixtures: list[Path]) -> dict:
    available = set(model.labels)
    inventory = label_inventory(model.labels)
    coverage = {}
    for name, group in repertoire["groups"].items():
        expected = set(group["labels"])
        coverage[name] = {
            "expected_count": len(expected),
            "present_count": len(expected & available),
            "missing_labels": sorted(expected - available),
        }
    return {
        "schema_version": 1,
        "artifact": {
            "bytes": model.byte_count,
            "sha256": model.sha256,
            "git_blob": model.git_blob,
            "format_version": model.format_version,
            "label_count": len(model.labels),
            "label_inventory_sha256": hashlib.sha256(inventory.encode("utf-8")).hexdigest(),
        },
        "feature_count": model.feature_count,
        "finite_weights_and_strictly_increasing_indices": True,
        "label_kinds": dict(sorted(Counter(label_kind(label) for label in model.labels).items())),
        "all_labels_single_scalar": all(len(label) == 1 for label in model.labels),
        "all_labels_nfc": all(unicodedata.normalize("NFC", label) == label for label in model.labels),
        "group_coverage": coverage,
        "fixture_label_coverage": [fixture_coverage(path, available) for path in fixtures],
        "recognition_accuracy_evaluated": False,
    }


def check_baseline(report: dict, baseline: dict) -> list[str]:
    if not isinstance(baseline, dict) or baseline.get("schema_version") != 1:
        raise AuditError("unsupported model baseline schema")
    expected = baseline.get("artifact")
    if not isinstance(expected, dict) or set(expected) != set(report["artifact"]):
        raise AuditError("baseline must pin every artifact field, including both hashes")
    return [
        f"baseline mismatch for {key}: expected {value!r}, found {report['artifact'][key]!r}"
        for key, value in expected.items()
        if report["artifact"][key] != value
    ]


def check_source_archive(path: Path, baseline: dict) -> list[str]:
    """Verify the pinned distribution and its model, source, and license members.

    The archive is never extracted. Its byte hash must match before any member
    is read, and expected member sizes are checked before decompression.
    """
    expected = baseline.get("source_archive")
    if not isinstance(expected, dict) or not all(key in expected for key in ("bytes", "sha256", "members")):
        raise AuditError("baseline does not pin a source archive")
    if path.stat().st_size != expected["bytes"]:
        return ["source archive byte count differs from pinned upstream distribution"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected["sha256"]:
        return ["source archive SHA-256 differs from pinned upstream distribution"]
    failures = []
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            for name, member in expected["members"].items():
                if names.count(name) != 1:
                    failures.append(f"source archive missing or duplicates member: {name}")
                    continue
                info = archive.getinfo(name)
                if info.file_size != member["bytes"] or info.file_size > MAX_MODEL_BYTES:
                    failures.append(f"source archive member byte count differs: {name}")
                    continue
                if hashlib.sha256(archive.read(name)).hexdigest() != member["sha256"]:
                    failures.append(f"source archive member SHA-256 differs: {name}")
    except zipfile.BadZipFile as error:
        raise AuditError(f"invalid pinned source archive: {error}") from error
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path)
    parser.add_argument("--repertoire", type=Path, default=HERE / "kana-repertoire.json")
    parser.add_argument("--baseline", type=Path, help="require exact bytes, weights and labels from a pinned baseline")
    parser.add_argument("--source-archive", type=Path, help="also verify the upstream source/license ZIP pinned by --baseline")
    parser.add_argument("--require-group", action="append", default=[], metavar="NAME")
    parser.add_argument("--require-modern-kana", action="store_true", help="fail if any required modern kana label is absent")
    parser.add_argument("--fixtures", type=Path, action="append", default=[], help="Tegaki XML expected-label coverage only; repeatable")
    parser.add_argument("--json-output", type=Path, help="also save the deterministic report to this file")
    parser.add_argument("--labels-output", type=Path, help="save the complete sorted model label inventory")
    args = parser.parse_args(argv)
    try:
        # Never overwrite the model or input manifests, including through symlinks.
        inputs = {path.resolve() for path in [args.model, args.repertoire, *args.fixtures]}
        if args.baseline:
            inputs.add(args.baseline.resolve())
        if args.source_archive:
            inputs.add(args.source_archive.resolve())
            if not args.baseline:
                raise AuditError("--source-archive requires --baseline")
        outputs = [path.resolve() for path in [args.json_output, args.labels_output] if path]
        if len(set(outputs)) != len(outputs) or any(path in inputs for path in outputs):
            raise AuditError("output paths must be distinct from each other and every input")
        repertoire = load_repertoire(args.repertoire)
        required = set(args.require_group)
        if args.require_modern_kana:
            required.update(name for name, group in repertoire["groups"].items() if group["required_for_modern_kana"])
        unknown = required - repertoire["groups"].keys()
        if unknown:
            raise AuditError("unknown repertoire group: " + ", ".join(sorted(unknown)))
        model = read_model(args.model)
        report = make_report(model, repertoire, args.fixtures)
        failures = []
        if args.baseline:
            baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
            failures.extend(check_baseline(report, baseline))
            if args.source_archive:
                failures.extend(check_source_archive(args.source_archive, baseline))
        for name in sorted(required):
            missing = report["group_coverage"][name]["missing_labels"]
            if missing:
                failures.append(f"{name}: {len(missing)} required labels absent ({''.join(missing)})")
        report["verification"] = {
            "baseline_checked": args.baseline is not None,
            "source_archive_checked": args.source_archive is not None,
            "required_groups": sorted(required),
            "passed": not failures,
            "failures": failures,
        }
        output = json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        if args.json_output:
            args.json_output.write_text(output, encoding="utf-8")
        if args.labels_output:
            args.labels_output.write_text(label_inventory(model.labels), encoding="utf-8")
        sys.stdout.write(output)
        return 1 if failures else 0
    except (OSError, AuditError, json.JSONDecodeError) as error:
        print(f"model audit failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
