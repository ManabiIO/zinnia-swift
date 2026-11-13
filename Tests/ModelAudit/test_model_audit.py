"""Artifact safety and coverage regressions. No model download is required."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("model_audit", ROOT / "Tools/ModelAudit/model_audit.py")
audit = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = audit
SPEC.loader.exec_module(audit)


def model_bytes(labels=("あ", "イ", "一"), features=((0, 0.5), (3, -0.25)), bias=0.125):
    body = b""
    for label in labels:
        body += label.encode("utf-8").ljust(16, b"\0")
        body += struct.pack("<f", bias)
        body += b"".join(struct.pack("<if", *feature) for feature in features)
        body += struct.pack("<if", -1, 0)
    return struct.pack("<III", (12 + len(body)) ^ audit.MAGIC_ID, 1, len(labels)) + body


def fix_magic(data):
    return struct.pack("<I", len(data) ^ audit.MAGIC_ID) + data[4:]


class ParserTests(unittest.TestCase):
    def test_valid_model_and_exact_inventory(self):
        model = audit.parse_model(model_bytes())
        self.assertEqual(model.labels, ("あ", "イ", "一"))
        self.assertEqual(model.feature_count, 6)
        self.assertEqual(audit.label_inventory(model.labels), "あ\nイ\n一\n")

    def test_rejects_truncated_headers(self):
        for length in range(12):
            with self.subTest(length=length), self.assertRaises(audit.AuditError):
                audit.parse_model(model_bytes()[:length])

    def test_rejects_magic_mismatch(self):
        with self.assertRaisesRegex(audit.AuditError, "size/magic"):
            audit.parse_model(model_bytes() + b"extra")

    def test_rejects_wrong_version(self):
        data = bytearray(model_bytes())
        struct.pack_into("<I", data, 4, 2)
        with self.assertRaisesRegex(audit.AuditError, "version"):
            audit.parse_model(bytes(data))

    def test_rejects_impossible_class_count(self):
        data = bytearray(model_bytes())
        struct.pack_into("<I", data, 8, 0xFFFFFFFF)
        with self.assertRaisesRegex(audit.AuditError, "class count"):
            audit.parse_model(bytes(data))

    def test_rejects_missing_sentinel_even_if_magic_is_updated(self):
        data = fix_magic(model_bytes(labels=("あ",))[:-8])
        with self.assertRaisesRegex(audit.AuditError, "sentinel"):
            audit.parse_model(data)

    def test_rejects_invalid_label_encodings(self):
        for label in (b"\xff\0".ljust(16, b"\0"), b"x" * 16, b"\0" * 16):
            data = bytearray(model_bytes())
            data[12:28] = label
            with self.subTest(label=label), self.assertRaises(audit.AuditError):
                audit.parse_model(bytes(data))

    def test_rejects_duplicate_labels(self):
        with self.assertRaisesRegex(audit.AuditError, "duplicate"):
            audit.parse_model(model_bytes(labels=("あ", "あ")))

    def test_rejects_non_finite_bias_and_features(self):
        for value in (float("nan"), float("inf"), -float("inf")):
            with self.subTest(value=value), self.assertRaisesRegex(audit.AuditError, "non-finite"):
                audit.parse_model(model_bytes(bias=value))
            with self.subTest(value=value), self.assertRaisesRegex(audit.AuditError, "non-finite"):
                audit.parse_model(model_bytes(features=((0, value),)))

    def test_rejects_invalid_feature_index(self):
        with self.assertRaisesRegex(audit.AuditError, "feature index"):
            audit.parse_model(model_bytes(features=((-2, 1.0),)))

    def test_rejects_duplicate_or_unsorted_feature_indices(self):
        for features in (((2, 1.0), (2, 0.5)), ((2, 1.0), (1, 0.5))):
            with self.subTest(features=features), self.assertRaisesRegex(audit.AuditError, "strictly increasing"):
                audit.parse_model(model_bytes(features=features))

    def test_rejects_trailing_bytes_even_if_magic_is_updated(self):
        with self.assertRaisesRegex(audit.AuditError, "trailing"):
            audit.parse_model(fix_magic(model_bytes() + b"extra"))

    def test_empty_feature_vector_is_valid(self):
        self.assertEqual(audit.parse_model(model_bytes(features=())).feature_count, 0)


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.repertoire = audit.load_repertoire(ROOT / "Tools/ModelAudit/kana-repertoire.json")
        self.model = audit.parse_model(model_bytes())

    def test_missing_labels_are_not_inferred_from_script_conversion(self):
        report = audit.make_report(self.model, self.repertoire, [])
        self.assertIn("ア", report["group_coverage"]["katakana-basic"]["missing_labels"])
        self.assertIn("が", report["group_coverage"]["hiragana-voiced"]["missing_labels"])
        self.assertIn("ぁ", report["group_coverage"]["hiragana-small"]["missing_labels"])
        self.assertFalse(report["recognition_accuracy_evaluated"])

    def test_pinned_digest_detects_weight_change_with_same_labels(self):
        report = audit.make_report(self.model, self.repertoire, [])
        baseline = {"schema_version": 1, "artifact": report["artifact"]}
        changed = audit.make_report(audit.parse_model(model_bytes(bias=0.5)), self.repertoire, [])
        self.assertEqual(changed["artifact"]["label_inventory_sha256"], report["artifact"]["label_inventory_sha256"])
        failures = audit.check_baseline(changed, baseline)
        self.assertTrue(any("sha256" in message for message in failures))
        self.assertTrue(any("git_blob" in message for message in failures))

    def test_baseline_must_pin_all_fields(self):
        report = audit.make_report(self.model, self.repertoire, [])
        with self.assertRaisesRegex(audit.AuditError, "pin every"):
            audit.check_baseline(report, {"schema_version": 1, "artifact": {"label_count": 3}})

    def test_fixture_coverage_counts_absent_samples_and_unique_labels(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.xml"
            path.write_text("<character-collection><set><character><utf8>あ</utf8></character><character><utf8>ア</utf8></character><character><utf8>ア</utf8></character></set></character-collection>", encoding="utf-8")
            coverage = audit.fixture_coverage(path, set(self.model.labels))
            self.assertEqual(coverage["sample_count"], 3)
            self.assertEqual(coverage["unique_label_count"], 2)
            self.assertEqual(coverage["samples_with_absent_label"], 2)
            self.assertEqual(coverage["missing_labels"], ["ア"])

    def test_manifest_contains_explicit_nonoverlapping_modern_labels(self):
        labels = "".join(group["labels"] for group in self.repertoire["groups"].values() if group["required_for_modern_kana"])
        self.assertEqual(len(labels), 167)
        self.assertEqual(len(set(labels)), 167)

    def test_pinned_inventory_retains_kanji_and_exposes_kana_gap(self):
        directory = ROOT / "Tools/ModelAudit"
        baseline = json.loads((directory / "shipping-japanese-0.3.json").read_text(encoding="utf-8"))
        inventory = (directory / "shipping-japanese-0.3.labels.txt").read_bytes()
        labels = inventory.decode("utf-8").splitlines()
        self.assertEqual(hashlib.sha256(inventory).hexdigest(), baseline["artifact"]["label_inventory_sha256"])
        self.assertEqual(len(labels), baseline["artifact"]["label_count"])
        self.assertEqual(len(labels), len(set(labels)))
        self.assertEqual(labels, sorted(labels))
        self.assertEqual(sum(audit.label_kind(label) == "cjk_unified_ideographs" for label in labels), 6356)
        required = set("".join(group["labels"] for group in self.repertoire["groups"].values() if group["required_for_modern_kana"]))
        self.assertEqual(len(required - set(labels)), 115)
        license_data = (directory / baseline["license_document"]["local_copy"]).read_bytes()
        self.assertEqual(hashlib.sha256(license_data).hexdigest(), baseline["license_document"]["sha256"])

    def test_cli_reports_failure_without_losing_report(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model"
            report_path = Path(directory) / "report.json"
            path.write_bytes(model_bytes())
            with contextlib.redirect_stdout(io.StringIO()):
                code = audit.main([str(path), "--require-modern-kana", "--json-output", str(report_path)])
            self.assertEqual(code, 1)
            self.assertFalse(json.loads(report_path.read_text())["verification"]["passed"])

    def test_cli_refuses_to_overwrite_model(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model"
            original = model_bytes()
            path.write_bytes(original)
            with contextlib.redirect_stderr(io.StringIO()):
                code = audit.main([str(path), "--labels-output", str(path)])
            self.assertEqual(code, 2)
            self.assertEqual(path.read_bytes(), original)

    def test_source_archive_checks_license_and_source_member_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.zip"
            members = {"COPYING": b"example license", "source.xml": b"<dictionary/>"}
            with zipfile.ZipFile(path, "w") as archive:
                for name, data in members.items():
                    archive.writestr(name, data)
            expected = {"schema_version": 1, "source_archive": {
                "bytes": path.stat().st_size,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "members": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for name, data in members.items()},
            }}
            self.assertEqual(audit.check_source_archive(path, expected), [])
            expected["source_archive"]["members"]["COPYING"]["sha256"] = "0" * 64
            self.assertTrue(audit.check_source_archive(path, expected))
            changed = bytearray(path.read_bytes())
            changed[-1] ^= 1
            path.write_bytes(changed)
            self.assertIn("source archive SHA-256", audit.check_source_archive(path, expected)[0])

    def test_rejects_source_archive_without_baseline(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(audit.main(["model", "--source-archive", "source.zip"]), 2)


if __name__ == "__main__":
    unittest.main()
