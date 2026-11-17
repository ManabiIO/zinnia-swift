#!/usr/bin/env bash
set -euo pipefail

package_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_directory="$(mktemp -d "${TMPDIR:-/tmp}/zinnia-native-safety.XXXXXX")"
trap 'rm -rf "$build_directory"' EXIT

compiler="${CXX:-c++}"
source_directory="$package_directory/Sources/zinnia"
sanitizers="${ZINNIA_SANITIZERS:-address,undefined}"
sanitizer_flags=()
if [[ "$sanitizers" != "none" ]]; then
    sanitizer_flags=("-fsanitize=$sanitizers" -fno-sanitize-recover=all -fno-omit-frame-pointer)
fi

"$compiler" -std=c++11 -g -O1 -DHAVE_CONFIG_H "${sanitizer_flags[@]}" \
    -I "$source_directory" \
    "$package_directory/Tests/Native/RecognizerSafetyTests.cpp" \
    "$source_directory/character.cpp" \
    "$source_directory/feature.cpp" \
    "$source_directory/libzinnia.cpp" \
    "$source_directory/param.cpp" \
    "$source_directory/recognizer.cpp" \
    "$source_directory/sexp.cpp" \
    "$source_directory/svm.cpp" \
    "$source_directory/trainer.cpp" \
    -o "$build_directory/recognizer-safety-tests"

"$build_directory/recognizer-safety-tests"
