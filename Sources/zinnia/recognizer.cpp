//
//  Zinnia: Online hand recognition system with machine learning
//
//  $Id$;
//
//  Copyright(C) 2008 Taku Kudo <taku@chasen.org>
//
#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif
#include <iostream>
#include <vector>
#include <cmath>
#include <algorithm>
#include <functional>
#include <limits>
#include "common.h"
#include "mmap.h"
#include "zinnia.h"
#include "feature.h"

namespace {

inline bool finite_float(float value) {
  const float limit = std::numeric_limits<float>::max();
  return value >= -limit && value <= limit;
}

// open_from_ptr accepts byte buffers, whose feature records need not have native
// alignment. Copy each record before reading it, retaining the mapped model's
// storage and the original scoring arithmetic without an additional model copy.
inline double dot_model(const char *model, const zinnia::FeatureNode *input) {
  double sum = 0;
  while (input->index >= 0) {
    zinnia::FeatureNode feature;
    std::memcpy(&feature, model, sizeof(feature));
    if (feature.index < 0) break;
    if (feature.index == input->index) {
      sum += feature.value * input->value;
      model += sizeof(feature);
      ++input;
    } else if (feature.index < input->index) {
      model += sizeof(feature);
    } else {
      ++input;
    }
  }
  return sum;
}

static inline char *read_ptr(char **ptr, size_t size) {
  char *r = *ptr;
  *ptr += size;
  return r;
}

template <typename T>
inline void read_static(char **ptr, T *value) {
  char *r = read_ptr(ptr, sizeof(T));
  memcpy(value, r, sizeof(T));
}

#ifndef WORDS_LITENDIAN
template <>
inline void read_static<unsigned int>(char **ptr, unsigned int *value) {
    unsigned char *buf = reinterpret_cast<unsigned char *>(*ptr);
    *value = (buf[0]) | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
    *ptr += 4;
}

template <>
inline void read_static<float>(char **ptr, float *value) {
    unsigned int x;
    read_static<unsigned int>(ptr, &x);
    memcpy(value, &x, sizeof(x));
}
#endif

}

namespace zinnia {

class ResultImpl: public Result {
 public:
  void add(const char *character, float score) {
    results_.push_back(std::make_pair(score, character));
  }
  void clear() { results_.clear(); }
  const char *value(size_t i) const {
    return (i >= results_.size()) ? 0 : results_[i].second;
  }
  float score(size_t i) const {
    return (i >= results_.size()) ? -1 : results_[i].first;
  }
  size_t size() const { return results_.size(); }
  ResultImpl() {}
  virtual ~ResultImpl() {}
 private:
  std::vector<std::pair<float, const char*> > results_;
};

class RecognizerImpl: public Recognizer {
 public:
  bool open(const char *filename);
  bool open(const char *ptr, size_t size);
  bool close();
  size_t size() const { return model_.size(); }
  const char *value(size_t i) const;
  Result* classify(const Character &character,
                   size_t nbest) const;
  const char *what() { return what_.str(); }
  explicit RecognizerImpl() {}
  virtual ~RecognizerImpl() { close(); }

 private:
  struct Model {
    const char *character;
    float bias;
    const char *x;
  };

  bool open_model(const char *ptr, size_t size);

  Mmap<char> mmap_;
  std::vector<Model> model_;
  whatlog what_;
};

const char *RecognizerImpl::value(size_t i) const {
  return (i >= model_.size()) ? 0 : model_[i].character;
}

bool RecognizerImpl::open(const char *filename) {
  close();
  CHECK_FALSE(filename && *filename) << "invalid model file path";
  CHECK_FALSE(mmap_.open(filename))
      << "no such file or directory: " << filename;
  return open_model(mmap_.begin(), mmap_.file_size());
}

bool RecognizerImpl::open(const char *p, size_t ptr_size) {
  close();
  return open_model(p, ptr_size);
}

bool RecognizerImpl::open_model(const char *p, size_t ptr_size) {
  CHECK_CLOSE_FALSE(p && ptr_size >= 3 * sizeof(unsigned int)
                    && ptr_size <= std::numeric_limits<unsigned int>::max())
      << "model file is broken";
  char *ptr = const_cast<char *>(p);
  const char *begin = ptr;
  const char *end = ptr + ptr_size;
  unsigned int version = 0;
  unsigned int magic = 0;
  read_static<unsigned int>(&ptr, &magic);
  CHECK_CLOSE_FALSE((magic ^ DIC_MAGIC_ID) == ptr_size)
      << "model file is broken";

  read_static<unsigned int>(&ptr, &version);
  CHECK_CLOSE_FALSE(version == DIC_VERSION)
      << "incompatible version: " << version;

  unsigned int size = 0;
  read_static<unsigned int>(&ptr, &size);

  // Every model needs a label, bias and at least a sentinel feature. Check
  // the count before allocating or advancing through untrusted model bytes.
  const size_t minimum_model_size = 16 + sizeof(float) + sizeof(FeatureNode);
  CHECK_CLOSE_FALSE(size <= static_cast<size_t>(end - ptr) / minimum_model_size)
      << "model file is broken";
  model_.resize(size);
  for (size_t i = 0; i < size; ++i) {
    CHECK_CLOSE_FALSE(static_cast<size_t>(end - ptr) >= minimum_model_size)
        << "model file is broken";
    Model &m = model_[i];
    m.character = read_ptr(&ptr, 16);
    CHECK_CLOSE_FALSE(m.character[0] && std::memchr(m.character, '\0', 16))
        << "model character is empty or not null terminated";
    float bias = 0.0;
    read_static<float>(&ptr, &bias);
    CHECK_CLOSE_FALSE(finite_float(bias)) << "model bias is not finite";
    m.bias = bias;
    m.x = ptr;
    int previous_index = -1;
    for (;;) {
      CHECK_CLOSE_FALSE(static_cast<size_t>(end - ptr) >= sizeof(FeatureNode))
          << "model file is broken";
      FeatureNode feature;
      std::memcpy(&feature, ptr, sizeof(feature));
      ptr += sizeof(FeatureNode);
      if (feature.index == -1) break;
      CHECK_CLOSE_FALSE(feature.index > previous_index && finite_float(feature.value))
          << "model features are invalid";
      previous_index = feature.index;
    }
  }

  CHECK_CLOSE_FALSE(static_cast<size_t>(ptr - begin) == ptr_size)
      << "size of model file is invalid";

  return true;
}

bool RecognizerImpl::close() {
  mmap_.close();
  model_.clear();
  return true;
}

Result *RecognizerImpl::classify(const Character &character,
                                 size_t nbest) const {
  if (model_.empty() || nbest <= 0) {
    return 0;
  }

  Features feature;
  if (!feature.read(character)) {
    return 0;
  }
  const FeatureNode *x = feature.get();

  std::vector<std::pair<float, const char*> > results;
  results.reserve(size());
  for (size_t i = 0; i < model_.size(); ++i) {
    const double score = model_[i].bias + dot_model(model_[i].x, x);
    const float limit = std::numeric_limits<float>::max();
    // Finite model coefficients can still overflow when combined. Nonfinite
    // scores cannot participate in the strict ordering required by partial_sort.
    if (!(score >= -limit && score <= limit)) continue;
    results.push_back(std::make_pair(static_cast<float>(score), model_[i].character));
  }

  if (results.empty()) return 0;

  nbest = _min(nbest, results.size());

  std::partial_sort(results.begin(),
                    results.begin() + nbest, results.end(),
                    std::greater<std::pair<float, const char*> >());

  ResultImpl *result = new ResultImpl;
  for (size_t i = 0; i < nbest; ++i)
    result->add(results[i].second, results[i].first);

  return result;
}

Recognizer* Recognizer::create() {
  return new RecognizerImpl;
}

Recognizer* createRecognizer() {
  return new RecognizerImpl;
}
}
