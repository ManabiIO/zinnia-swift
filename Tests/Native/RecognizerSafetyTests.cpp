#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <vector>
#include <unistd.h>
#include "zinnia.h"

namespace {

void require(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << std::endl;
    std::exit(1);
  }
}

void word(std::vector<char> *bytes, uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) {
    bytes->push_back(static_cast<char>((value >> shift) & 0xff));
  }
}

void replace_word(std::vector<char> *bytes, size_t offset, uint32_t value) {
  for (size_t i = 0; i < 4; ++i) {
    (*bytes)[offset + i] = static_cast<char>((value >> (8 * i)) & 0xff);
  }
}

uint32_t bits(float value) {
  uint32_t result = 0;
  std::memcpy(&result, &value, sizeof(result));
  return result;
}

void fix_size(std::vector<char> *model) {
  replace_word(model, 0, static_cast<uint32_t>(model->size()) ^ 0x0ef71821u);
}

std::vector<char> model(float bias = 2, float weight = 3) {
  std::vector<char> bytes;
  word(&bytes, 0);
  word(&bytes, 1);
  word(&bytes, 1);
  const char *label = "一";
  bytes.insert(bytes.end(), label, label + std::strlen(label));
  bytes.resize(28, 0);
  word(&bytes, bits(bias));
  word(&bytes, 0);  // Feature zero is always one for nonempty handwriting.
  word(&bytes, bits(weight));
  word(&bytes, 0xffffffffu);
  word(&bytes, 0);
  fix_size(&bytes);
  return bytes;
}

typedef std::unique_ptr<zinnia_recognizer_t, decltype(&zinnia_recognizer_destroy)> Recognizer;
typedef std::unique_ptr<zinnia_character_t, decltype(&zinnia_character_destroy)> Character;
typedef std::unique_ptr<zinnia_result_t, decltype(&zinnia_result_destroy)> Result;

void expect_valid(zinnia_recognizer_t *recognizer, const zinnia_character_t *character) {
  Result result(zinnia_recognizer_classify(recognizer, character, 10), zinnia_result_destroy);
  require(result.get() != 0, "valid model returns a result");
  require(zinnia_result_size(result.get()) == 1, "candidate count is bounded by the model");
  require(std::strcmp(zinnia_result_value(result.get(), 0), "一") == 0, "candidate label is preserved");
  require(zinnia_result_score(result.get(), 0) == 5, "feature-bearing model score is preserved");
  require(zinnia_result_value(result.get(), 1) == 0, "out-of-range result value is null");
  require(zinnia_result_score(result.get(), 1) == -1, "out-of-range result score is the native sentinel");
}

void expect_rejected(zinnia_recognizer_t *recognizer, const zinnia_character_t *character,
                     const std::vector<char> &bytes) {
  require(zinnia_recognizer_open_from_ptr(recognizer, bytes.data(), bytes.size()) == 0,
          "malformed model is rejected");
  require(zinnia_recognizer_size(recognizer) == 0, "failed open clears the old model");
  require(zinnia_recognizer_classify(recognizer, character, 10) == 0,
          "failed open cannot classify with stale model pointers");
  const char *error = zinnia_recognizer_strerror(recognizer);
  require(error != 0 && *error != '\0', "failed open preserves an error message");
}

}  // namespace

int main(int argc, char **argv) {
  Recognizer recognizer(zinnia_recognizer_new(), zinnia_recognizer_destroy);
  Character character(zinnia_character_new(), zinnia_character_destroy);
  require(recognizer.get() != 0 && character.get() != 0, "native handles allocate");
  zinnia_character_set_width(character.get(), 500);
  zinnia_character_set_height(character.get(), 500);
  require(zinnia_character_add(character.get(), 0, 50, 250) == 1, "first point adds");
  require(zinnia_character_add(character.get(), 0, 450, 250) == 1, "second point adds");

  std::vector<char> valid = model();
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), valid.data(), valid.size()) == 1,
          "valid pointer model opens");
  expect_valid(recognizer.get(), character.get());

  // This was accepted by the parser but dereferenced as misaligned FeatureNode
  // objects by the classifier. UBSan detects that independently of the assertions.
  std::vector<char> unaligned(1, 0);
  unaligned.insert(unaligned.end(), valid.begin(), valid.end());
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), unaligned.data() + 1, valid.size()) == 1,
          "unaligned byte-buffer model opens");
  expect_valid(recognizer.get(), character.get());

  if (argc == 2 && std::strcmp(argv[1], "--alignment-only") == 0) return 0;

  size_t malformed_count = 0;
  for (size_t length = 0; length < valid.size(); ++length) {
    std::vector<char> truncated(valid.begin(), valid.begin() + length);
    if (truncated.size() >= 4) fix_size(&truncated);
    expect_rejected(recognizer.get(), character.get(), truncated);
    ++malformed_count;
  }

  std::vector<std::vector<char> > malformed;
  std::vector<char> bad = valid;
  replace_word(&bad, 8, 0xffffffffu);
  malformed.push_back(bad);
  bad = valid;
  std::fill(bad.begin() + 12, bad.begin() + 28, 'a');
  malformed.push_back(bad);
  bad = valid;
  bad[12] = 0;
  malformed.push_back(bad);
  bad = valid;
  replace_word(&bad, 40, 1);  // Remove the sentinel at the end of the buffer.
  malformed.push_back(bad);
  bad = valid;
  bad.push_back(0);
  fix_size(&bad);
  malformed.push_back(bad);

  for (float invalid : {std::numeric_limits<float>::quiet_NaN(),
                        std::numeric_limits<float>::infinity(),
                        -std::numeric_limits<float>::infinity()}) {
    malformed.push_back(model(invalid, 3));
    malformed.push_back(model(2, invalid));
  }

  bad = valid;
  replace_word(&bad, 32, 0xfffffffeu);  // -2 is not a feature or the -1 terminator.
  malformed.push_back(bad);
  bad = valid;
  bad.insert(bad.begin() + 40, valid.begin() + 32, valid.begin() + 40);
  fix_size(&bad);  // Duplicate feature zero violates sparse vector ordering.
  malformed.push_back(bad);

  for (const std::vector<char> &bytes : malformed) {
    expect_rejected(recognizer.get(), character.get(), bytes);
    ++malformed_count;
  }

  // Finite coefficients can still overflow a float score. They must not reach
  // partial_sort as infinities or NaNs.
  std::vector<char> overflow = model(std::numeric_limits<float>::max(), std::numeric_limits<float>::max());
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), overflow.data(), overflow.size()) == 1,
          "finite model coefficients are accepted");
  require(zinnia_recognizer_classify(recognizer.get(), character.get(), 10) == 0,
          "unrepresentable scores do not become candidates");

  require(zinnia_recognizer_open(recognizer.get(), 0) == 0, "null filename fails safely");
  require(zinnia_recognizer_open(recognizer.get(), "") == 0, "empty filename fails safely");
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), 0, 12) == 0, "null buffer fails safely");
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), valid.data(),
          std::numeric_limits<size_t>::max()) == 0, "unrepresentable model size fails before pointer arithmetic");
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), valid.data(), valid.size()) == 1,
          "recognizer recovers after invalid input");
  require(zinnia_recognizer_classify(recognizer.get(), character.get(), 0) == 0,
          "zero requested results are safe");

  for (size_t i = 0; i < 1000; ++i) expect_valid(recognizer.get(), character.get());

  zinnia_character_clear(character.get());
  zinnia_character_set_width(character.get(), 1);
  zinnia_character_set_height(character.get(), 1);
  require(zinnia_character_add(character.get(), 0,
          std::numeric_limits<int>::min(), std::numeric_limits<int>::min()) == 1,
          "minimum native coordinates add");
  require(zinnia_character_add(character.get(), 0,
          std::numeric_limits<int>::max(), std::numeric_limits<int>::max()) == 1,
          "maximum native coordinates add");
  expect_valid(recognizer.get(), character.get());

  char filename[] = "/tmp/zinnia-safety-XXXXXX";
  const int descriptor = mkstemp(filename);
  require(descriptor >= 0, "temporary model file creates");
  require(write(descriptor, valid.data(), valid.size()) == static_cast<ssize_t>(valid.size()),
          "temporary model file writes");
  require(close(descriptor) == 0, "temporary model file closes");
  require(zinnia_recognizer_open(recognizer.get(), filename) == 1, "file model opens");
  expect_valid(recognizer.get(), character.get());
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), valid.data(), valid.size()) == 1,
          "external pointer model replaces a mapped file");
  expect_valid(recognizer.get(), character.get());
  require(unlink(filename) == 0, "temporary model file removes");
  size_t error_length = 0;
  for (size_t i = 0; i < 1000; ++i) {
    require(zinnia_recognizer_open(recognizer.get(), filename) == 0, "missing file fails repeatedly");
    require(zinnia_recognizer_size(recognizer.get()) == 0, "missing file leaves no model");
    const size_t current_error_length = std::strlen(zinnia_recognizer_strerror(recognizer.get()));
    if (i == 0) error_length = current_error_length;
    require(current_error_length == error_length, "repeated failures do not accumulate old error messages");
  }

  std::cout << "PASS: " << malformed_count
            << " malformed models; unaligned buffers; finite scores; null paths; recovery; "
            << "1000 result lifetimes; 1000 failed opens" << std::endl;
  return 0;
}
