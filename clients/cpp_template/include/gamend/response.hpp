// What a call answered.
//
// Every Gamend reply is one of four shapes: `{data}`, `{data, meta}`,
// `{ok: true}` or `{error, message?, errors?}`. `data()`, `meta()`, `code()`
// and `message()` read them without touching `body` directly.
#pragma once

#include <functional>
#include <optional>
#include <string>

#include "gamend/codec.hpp"
#include "gamend/json.hpp"

namespace gamend {

namespace models {
template <class T>
struct Page;
}  // namespace models

struct Response {
  /// The HTTP status; 0 when no reply arrived (the transport failed, or the
  /// SDK refused to send the call because a required field was missing).
  int status = 0;
  /// The decoded body; null when it was empty or not JSON.
  json body;
  /// The body as it arrived: the bytes of a download, for one.
  std::string text;
  /// Empty on success. Otherwise the server's error code (`not_found`,
  /// `validation_failed`, ...), `http_<status>` when it gave none, or what
  /// went wrong before a reply arrived.
  std::string error;

  bool ok() const { return status >= 200 && status < 300 && error.empty(); }
  /// `body.data`: the object or list the call answered. Null otherwise.
  const json& data() const { return field(body, "data"); }
  /// `body.meta` of a paged list: page, page_size, total_count, ...
  const json& meta() const { return field(body, "meta"); }
  /// `body.error`, the machine-readable code; empty on success.
  std::string code() const { return gamend::text(body, "error"); }
  /// `body.message`, the human-readable one, when the server sent it.
  std::string message() const { return gamend::text(body, "message"); }
  /// `body.errors`: `{field: [messages]}` for `validation_failed`.
  const json& errors() const { return field(body, "errors"); }

  /// `data()` as a typed value: `as<models::Lobby>()`, or
  /// `as<std::vector<std::string>>()`. Nothing when it is not that kind of
  /// value at all; a field that is missing keeps its default.
  template <class T>
  std::optional<T> as() const {
    T value{};
    if (!Codec<T>::read(data(), value)) return std::nullopt;
    return value;
  }
  /// A page of `T` with its `meta`: `page<models::Lobby>()` for
  /// `GET /lobbies`. Include `gamend/models.hpp` to use it.
  template <class T>
  std::optional<models::Page<T>> page() const {
    models::Page<T> value{};
    if (!Codec<models::Page<T>>::read(body, value)) return std::nullopt;
    return value;
  }
};

using Callback = std::function<void(const Response&)>;

}  // namespace gamend
