// The one value type the SDK speaks: nlohmann/json, as `gamend::json`.
//
// The core builds without exceptions, and so can a game that includes it.
// nlohmann/json then aborts where it would have thrown, so read a reply with
// the accessors that cannot fail: `find`, `value(key, fallback)`, `is_string()`
// before `get<std::string>()`, and `gamend::text` / `gamend::number` below.
// `operator[]` on a *const* json with a missing key is undefined behaviour.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

#include <nlohmann/json.hpp>

namespace gamend {

using json = nlohmann::json;

/// `object[key]` as text, or `fallback` when it is missing or not a string.
inline std::string text(const json& object, std::string_view key, std::string fallback = {}) {
  if (!object.is_object()) return fallback;
  auto it = object.find(key);
  if (it == object.end() || !it->is_string()) return fallback;
  return it->get<std::string>();
}

/// `object[key]` as an integer, or `fallback` when it is missing or not a number.
inline std::int64_t number(const json& object, std::string_view key, std::int64_t fallback = 0) {
  if (!object.is_object()) return fallback;
  auto it = object.find(key);
  if (it == object.end() || !it->is_number()) return fallback;
  return it->get<std::int64_t>();
}

/// `object[key]`, or null when it is missing. Never inserts, never aborts.
inline const json& field(const json& object, std::string_view key) {
  static const json null_value;
  if (!object.is_object()) return null_value;
  auto it = object.find(key);
  return it == object.end() ? null_value : *it;
}

/// Serialized for the wire. Invalid UTF-8 is replaced rather than thrown on.
inline std::string dump(const json& value) {
  return value.dump(-1, ' ', false, json::error_handler_t::replace);
}

/// Parsed, or a discarded value (`is_discarded()`) when `text` is not JSON.
inline json parse(std::string_view text) { return json::parse(text, nullptr, false); }

}  // namespace gamend
