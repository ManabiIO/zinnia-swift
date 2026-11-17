#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <memory>
#include <string>
#include <utility>
#include <vector>
#include "zinnia.h"

namespace {

void require(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << std::endl;
    std::exit(1);
  }
}

typedef std::unique_ptr<zinnia_recognizer_t, decltype(&zinnia_recognizer_destroy)> Recognizer;
typedef std::unique_ptr<zinnia_character_t, decltype(&zinnia_character_destroy)> Character;
typedef std::unique_ptr<zinnia_result_t, decltype(&zinnia_result_destroy)> Result;
typedef std::vector<std::pair<std::string, float> > Candidates;

Candidates recognize(zinnia_recognizer_t *recognizer, const char *expected,
                     const char *input, size_t expected_rank) {
  Character character(zinnia_character_new(), zinnia_character_destroy);
  require(character.get() != 0, "character allocates");
  require(zinnia_character_parse(character.get(), input) == 1, "fixture parses");
  Result result(zinnia_recognizer_classify(recognizer, character.get(), 10), zinnia_result_destroy);
  require(result.get() != 0, "shipping model classifies fixture");
  require(zinnia_result_size(result.get()) == 10, "ten candidates are returned");
  Candidates candidates;
  size_t rank = 0;
  for (size_t index = 0; index < zinnia_result_size(result.get()); ++index) {
    const char *value = zinnia_result_value(result.get(), index);
    float score = zinnia_result_score(result.get(), index);
    require(value != 0 && std::isfinite(score), "candidate label and score are valid");
    candidates.push_back(std::make_pair(std::string(value), score));
    if (std::strcmp(value, expected) == 0) rank = index + 1;
  }
  require(rank == expected_rank, "existing kanji fixture rank is preserved");
  return candidates;
}

std::vector<Candidates> recognize_fixtures(zinnia_recognizer_t *recognizer) {
  require(zinnia_recognizer_size(recognizer) == 6420, "all shipping classes load");
  std::vector<Candidates> results;
  results.push_back(recognize(recognizer, "一",
      "(character (width 500) (height 500) (strokes ((50 250) (450 250))))", 1));
  results.push_back(recognize(recognizer, "中",
      "(character (width 500) (height 500) (strokes ((50 200) (50 300)) "
      "((50 200) (450 200) (450 300)) ((50 300) (450 300)) ((250 100) (250 400))))", 2));
  return results;
}

}  // namespace

int main(int argc, char **argv) {
  require(argc == 2 || (argc == 3 && std::strcmp(argv[2], "--file-only") == 0),
          "usage: model-compatibility-tests MODEL [--file-only]");
  Recognizer recognizer(zinnia_recognizer_new(), zinnia_recognizer_destroy);
  require(recognizer.get() != 0, "recognizer allocates");
  require(zinnia_recognizer_open(recognizer.get(), argv[1]) == 1, "shipping file model opens");
  const std::vector<Candidates> mapped = recognize_fixtures(recognizer.get());
  const char *labels[] = {"一", "中"};
  for (size_t index = 0; index < mapped.size(); ++index) {
    std::cout << labels[index];
    for (const auto &candidate : mapped[index]) {
      std::cout << '\t' << candidate.first << ':' << std::hexfloat << candidate.second;
    }
    std::cout << '\n';
  }
  if (argc == 3) return 0;

  // Exercise the same full model through the formerly misaligned feature path.
  std::ifstream file(argv[1], std::ios::binary);
  require(file.good(), "shipping model bytes open");
  std::vector<char> unaligned(1, 0);
  unaligned.insert(unaligned.end(), std::istreambuf_iterator<char>(file),
                   std::istreambuf_iterator<char>());
  require(unaligned.size() == 26068669, "shipping model byte count matches");
  require(zinnia_recognizer_open_from_ptr(recognizer.get(), unaligned.data() + 1,
                                        unaligned.size() - 1) == 1,
          "unaligned full shipping model opens");
  const std::vector<Candidates> buffered = recognize_fixtures(recognizer.get());
  require(buffered == mapped, "all fixture candidate labels/scores match mapped model exactly");
  // End the borrowed-buffer lifetime explicitly before releasing its storage.
  require(zinnia_recognizer_close(recognizer.get()) == 1, "borrowed model closes");
  std::cout << "PASS: 6420 classes; 一 rank 1; 中 rank 2; mapped and unaligned scores identical\n";
  return 0;
}
