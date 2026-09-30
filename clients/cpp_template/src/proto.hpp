// Protobuf realtime events, as `Config::realtime_format = Protobuf` asks the
// server to send them: the binary payloads `proto/gamend_realtime.proto`
// describes, turned back into the payload the event has in JSON mode.
//
// No protobuf library: the file uses a small part of the language (proto3
// scalars, messages, optional, repeated, map<string, V>, oneof), so a field
// table generated from it (`src/proto_schema.cpp`) and a wire reader do.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

#include "gamend/json.hpp"

namespace gamend::detail {

namespace proto {

/// Offered every bytes field that is not `*_json` (a game's own protobuf in
/// `metadata_pb` or `data_pb`): the message and field it is in, its bytes,
/// and the fields decoded so far. A value replaces the field, under its name
/// without `_pb`; nothing leaves it as base64.
using BytesHook = std::function<std::optional<json>(std::string_view message,
                                                    std::string_view field,
                                                    std::string_view bytes, const json& decoded)>;

}  // namespace proto

/// The payload of a binary `event` on `topic`, or nothing when this SDK has
/// no decoder for it (or the bytes do not decode).
std::optional<json> decode_binary_event(const std::string& topic, const std::string& event,
                                        const std::string& bytes,
                                        const proto::BytesHook* hook = nullptr);

namespace proto {

enum class Type : std::uint8_t { Bool, Int32, Int64, Uint32, Uint64, Sint32, Sint64, String, Bytes, Message };
/// Singular: proto3 implicit presence. Optional: explicit presence (and
/// oneof members). Map: `map<string, type>`.
enum class Label : std::uint8_t { Singular, Optional, Repeated, Map };

struct Field {
  std::uint32_t number;
  std::string_view name;
  Label label;
  /// The value's type; a map's value type.
  Type type;
  /// For `Type::Message`: its index in `kMessages`; -1 otherwise.
  int message;
};

struct Message {
  std::string_view name;
  const Field* fields;
  std::size_t count;
};

extern const Message kMessages[];
extern const std::size_t kMessageCount;

const Message* find(std::string_view name);

/// `bytes` as JSON with the message's field names. `defaults` fills the
/// fields a proto3 message leaves out for being zero, as protobufjs's
/// `toObject({defaults: true})` does; explicitly optional ones stay absent.
/// `X_json` bytes come out parsed, as `X`; other bytes as base64.
std::optional<json> decode(const Message& message, std::string_view bytes, bool defaults,
                           const BytesHook* hook = nullptr);

/// `value`, keyed by field name, on the wire. Bytes fields take a string of
/// the raw bytes; fields `value` leaves out are left out.
std::string encode(const Message& message, const json& value);

std::string base64(std::string_view bytes);
/// Nothing when `text` is not base64.
std::optional<std::string> unbase64(std::string_view text);

}  // namespace proto
}  // namespace gamend::detail
