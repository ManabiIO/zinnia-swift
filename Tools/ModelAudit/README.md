# Japanese model audit

This tool pins the existing Manabi Japanese model and makes its missing kana
coverage visible to release checks. It does not train a model, change weights,
or substitute another handwriting engine.

The model is supplied by the consuming app, not bundled in this Swift package.
The verified Reader resource is `ManabiPlatform/Resources/zinnia.model`.

## Run

Python 3.10 or newer is sufficient; there are no third-party dependencies.
Run from the root of the `zinnia-swift` checkout:

```sh
python3 -m unittest discover -s Tests/ModelAudit -v

python3 Tools/ModelAudit/model_audit.py /path/to/zinnia.model \
  --baseline Tools/ModelAudit/shipping-japanese-0.3.json \
  --json-output /tmp/zinnia-model-audit.json \
  --labels-output /tmp/zinnia-model-labels.txt
```

The baseline requires the exact model bytes, SHA-256, Git blob, format version,
class count and label-inventory hash. A model with the same labels but changed
kanji weights fails this check. The parser also validates bounds, UTF-8 label
termination, unique labels, finite biases/weights, strictly increasing
nonnegative feature indices, sentinel termination, and exact end of file.

An inspection without `--baseline` is useful for evaluating an alternative
artifact, but passing inspection alone does not approve it for a release.
JSON output is deterministic and contains no timestamps or absolute paths.

### Run the actual native engine against the pinned model

```sh
bash Tools/ModelAudit/test-native-model.sh /path/to/zinnia.model
```

This first verifies the artifact baseline, then compiles the package's current
C++ sources with AddressSanitizer and UndefinedBehaviorSanitizer. It loads all
6,420 classes, checks the existing `一` and `中` fixtures at ranks 1 and 2, and
requires every top-ten label and score to match exactly between the mapped file
and a deliberately unaligned borrowed buffer. These are compatibility smoke
tests, not a handwriting accuracy benchmark. `CXX` can select a compiler;
`ZINNIA_SANITIZERS=none` is available for systems without sanitizer support.
When the execution environment blocks LeakSanitizer's process inspection, run
with `ASAN_OPTIONS=detect_leaks=0` and record that leak detection was excluded.

### Verify corresponding source and license

Download the distribution identified in `shipping-japanese-0.3.json`, then add
`--source-archive /path/to/tegaki-zinnia-japanese-0.3.zip` to the baseline command.
The tool checks the archive's pinned SHA-256 before reading any ZIP member. It
then verifies the model, training XML, model Makefile, metadata and COPYING
against their pinned hashes. The ZIP is never extracted by the audit tool.

The verified [upstream Tegaki 0.3 archive](https://github.com/tegaki/tegaki/releases/download/v0.3/tegaki-zinnia-japanese-0.3.zip)
contains byte-identical shipping weights and their source. This is stronger
evidence than finding a similarly named model in another application. The
matching source XML is also present in the
[pinned Tegaki source tree](https://github.com/tegaki/tegaki/blob/7a74e442c4130cccc226a7e7c2b683ac94c0cccb/tegaki-models/data/train/japanese/handwriting-ja.xml).

Keep the model's license record separate from the engine and Swift wrapper.
The model archive carries the GNU Lesser General Public License v2.1 text; an
unmodified copy is retained in `licenses/tegaki-model-COPYING`. This developer
directory does not automatically place that notice in an application's bundle.
When packaging this model in Reader or Flow, retain the model notice and a
durable distribution of the matching XML, Makefile and COPYING identified by
the manifest. Check the final app's notice/source distribution as part of its
release, rather than assuming this package's code license covers the weights.

## Coverage is not recognition accuracy

The pinned artifact contains **6,420 labels**: 6,356 CJK unified ideographs,
46 hiragana, six katakana, ten digits, `々` and `〆`. The six katakana are
`イエオジラン` (five unvoiced characters and one voiced character).

`kana-repertoire.json` explicitly defines **167 modern kana output labels**
and 14 optional historic, extended or iteration labels. Only **52 of 167**
modern labels occur in this model. To require direct classifier coverage:

```sh
python3 Tools/ModelAudit/model_audit.py /path/to/zinnia.model \
  --require-modern-kana
```

**This command currently exits 1, with 115 required labels absent.** A smaller
scope can be checked with repeated `--require-group`, for example
`--require-group hiragana-basic`. The exact supported label list is checked in
as `shipping-japanese-0.3.labels.txt`; it is sorted by Unicode scalar value and
hashed as UTF-8 with LF line endings.

`--fixtures /path/to/corpus.xml` can be repeated to compare the labels in Tegaki
XML samples with the classifier inventory. It does not execute the recognizer
or estimate top-k accuracy. The existing writer1 fixtures have 74 hiragana and
73 katakana samples. This model lacks the labels for 28 and 67 of those samples,
respectively. Empty `<set>` entries do not become samples. These corpora lack
small-kana examples and do not establish multi-writer generalization.

Script conversion, voicing and size selection can be useful explicit user
controls. They are output transformations, and do not establish recognition of
an absent drawn label. Small and large kana also require an explicit product
decision: stroke normalization discards absolute drawing size, so even label
presence alone cannot establish that distinction reliably.

## Alternative model checked

The [Tomoe/KanjiVG model in iOS-Zinnia-Japanese-Handwriting-Input](https://github.com/shinjukunian/iOS-Zinnia-Japanese-Handwriting-Input/blob/15fb03dc1d55f8ad9704b677ff7c38404748bf47/ZinniaCocoaTouch/handwriting.model)
has 6,440 labels. Its extra 20 labels are CJK characters; it has exactly the same
kana labels as the shipping model and misses the same 95 fixture labels.
`candidate-review.json` records the pinned artifact, hashes and coverage. It
was rejected as a kana fix; no candidate weights were adopted. Its README's
KanjiVG attribution also requires distinct source/license provenance before
any future redistribution.

## Completing kana recognition

Preserve the pinned kanji weights. A future supplemental kana model needs a
separate identity, source/license manifest, reproducible training procedure and
evaluation against held-out writers. The existing one-writer corpus can
provide smoke-test input, not a shipping-quality training/validation split.
Train/evaluate modern base, voiced and semi-voiced kana explicitly; qualify
stroke order variants and finger/stylus input before claiming support.

Keep the supplemental classifier behind an explicit Kana input scope. Raw
scores from independently trained models are not calibrated probabilities and
must not be merged into a common ranking without a measured calibration
method. Any future unified model must additionally demonstrate no kanji
recognition regression. This audit's hash gate deliberately fails a weight
replacement until its baseline and evidence are intentionally reviewed.

Exit codes: **0** for all requested checks passing, **1** for baseline or label
coverage failures (a report is still emitted), **2** for invalid audit inputs or
malformed artifacts. No command downloads assets or modifies a model.
