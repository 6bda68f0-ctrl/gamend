// Reading a reply into a typed value, and writing one back.
//
// `Codec<T>` is specialized for every model in `gamend/models.hpp`, for the
// JSON scalars, and for vectors and optionals of any of them, so
// `response.as<models::Lobby>()` and `response.as<std::vector<std::string>>()`
// both work. Reads are lenient and never abort, exceptions or not: a field
// that is missing or of the wrong type keeps its default, and only a value
// that is not even the right kind (an object for a model, an array for a
// vector) reads as a failure.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "gamend/json.hpp"

namespace gamend {

template <class T, class Enable = void>
struct Codec;

template <>
struct Codec<std::string> {
  static bool read(const json& j, std::string& out) {
    if (!j.is_string()) return false;
    out = j.get<std::string>();
    return true;
  }
  static json write(const std::string& v) { return v; }
};

template <>
struct Codec<std::int64_t> {
  static bool read(const json& j, std::int64_t& out) {
    if (!j.is_number()) return false;
    out = j.get<std::int64_t>();
    return true;
  }
  static json write(std::int64_t v) { return v; }
};

template <>
struct Codec<double> {
  static bool read(const json& j, double& out) {
    if (!j.is_number()) return false;
    out = j.get<double>();
    return true;
  }
  static json write(double v) { return v; }
};

template <>
struct Codec<bool> {
  static bool read(const json& j, bool& out) {
    if (!j.is_boolean()) return false;
    out = j.get<bool>();
    return true;
  }
  static json write(bool v) { return v; }
};

template <>
struct Codec<json> {
  static bool read(const json& j, json& out) {
    out = j;
    return true;
  }
  static json write(const json& v) { return v; }
};

template <class T>
struct Codec<std::vector<T>> {
  static bool read(const json& j, std::vector<T>& out) {
    out.clear();
    if (!j.is_array()) return false;
    out.reserve(j.size());
    for (const auto& item : j) {
      T value{};
      if (Codec<T>::read(item, value)) out.push_back(std::move(value));
    }
    return true;
  }
  static json write(const std::vector<T>& v) {
    json out = json::array();
    for (const auto& item : v) out.push_back(Codec<T>::write(item));
    return out;
  }
};

template <class T>
struct Codec<std::map<std::string, T>> {
  static bool read(const json& j, std::map<std::string, T>& out) {
    out.clear();
    if (!j.is_object()) return false;
    for (auto it = j.begin(); it != j.end(); ++it) {
      T value{};
      if (Codec<T>::read(*it, value)) out.emplace(it.key(), std::move(value));
    }
    return true;
  }
  static json write(const std::map<std::string, T>& v) {
    json out = json::object();
    for (const auto& [key, item] : v) out[key] = Codec<T>::write(item);
    return out;
  }
};

template <class T>
struct Codec<std::optional<T>> {
  static bool read(const json& j, std::optional<T>& out) {
    out.reset();
    if (j.is_null()) return true;
    T value{};
    if (!Codec<T>::read(j, value)) return false;
    out = std::move(value);
    return true;
  }
  static json write(const std::optional<T>& v) {
    return v ? Codec<T>::write(*v) : json(nullptr);
  }
};

namespace detail {

/// `object[key]` into `out` when it is there and reads; `out` keeps its
/// default otherwise.
template <class T>
void read_field(const json& object, std::string_view key, T& out) {
  auto it = object.find(key);
  if (it != object.end()) Codec<T>::read(*it, out);
}

}  // namespace detail
}  // namespace gamend
