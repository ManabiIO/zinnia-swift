#!/usr/bin/env bash
set -euo pipefail

package_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -ne 1 ]]; then
    echo "usage: bash Tools/ModelAudit/test-native-model.sh /path/to/zinnia.model" >&2
    exit 2
fi
model_path="$1"
python3 "$package_directory/Tools/ModelAudit/model_audit.py" "$model_path" \
    --baseline "$package_directory/Tools/ModelAudit/shipping-japanese-0.3.json" >/dev/null

build_directory="$(mktemp -d "${TMPDIR:-/tmp}/zinnia-model-compatibility.XXXXXX")"
trap 'rm -rf "$build_directory"' EXIT
source_directory="$package_directory/Sources/zinnia"
compiler="${CXX:-c++}"
sanitizers="${ZINNIA_SANITIZERS:-address,undefined}"
sanitizer_flags=()
if [[ "$sanitizers" != "none" ]]; then
    sanitizer_flags=("-fsanitize=$sanitizers" -fno-sanitize-recover=all -fno-omit-frame-pointer)
fi

"$compiler" -std=c++11 -g -O1 -DHAVE_CONFIG_H "${sanitizer_flags[@]}" \
    -I "$source_directory" \
    "$package_directory/Tests/ModelAudit/ModelCompatibilityTests.cpp" \
    "$source_directory/character.cpp" \
    "$source_directory/feature.cpp" \
    "$source_directory/libzinnia.cpp" \
    "$source_directory/param.cpp" \
    "$source_directory/recognizer.cpp" \
    "$source_directory/sexp.cpp" \
    "$source_directory/svm.cpp" \
    "$source_directory/trainer.cpp" \
    -o "$build_directory/model-compatibility-tests"

"$build_directory/model-compatibility-tests" "$model_path"
