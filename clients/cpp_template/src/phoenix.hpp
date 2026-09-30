// Phoenix Channels, protocol V2, with no socket in it: refs, joins, the
// heartbeat and frame decoding, fed text, bytes and a clock by `Realtime`.
//
// Wire shape of a text frame, both directions: `[join_ref, ref, topic,
// event, payload]`, refs being stringified counters or null. A binary frame
// (the server's protobuf events) is a kind byte, sizes, then the strings and
// the payload bytes; see `Phoenix.Socket.V2.JSONSerializer`.
#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "gamend/json.hpp"

namespace gamend::detail {

struct Frame {
  enum class Kind {
    /// The reply to a join, leave or push, correlated by `ref`.
    Reply,
    /// A server-pushed event on a topic.
    Message,
  };
  Kind kind = Kind::Message;
  std::string topic;
  std::string event;   // Message: the event; Reply: empty
  std::string ref;     // Reply: the ref it answers
  std::string status;  // Reply: "ok" or "error"
  json payload;        // Message: the payload; Reply: the response
  /// A binary frame's payload, undecoded. `payload` is null then.
  std::optional<std::string> bytes;
};

class Phoenix {
 public:
  /// Phoenix's own rhythm: a beat every thirty seconds, and a beat still
  /// unanswered when the next is due means the server is gone.
  static constexpr std::chrono::milliseconds kHeartbeat{30000};

  explicit Phoenix(std::chrono::milliseconds now = {}) : last_heartbeat_(now) {}

  /// The frame that joins `topic`, and the ref its reply carries.
  std::pair<std::string, std::string> join(const std::string& topic, const json& payload);
  /// The frame that leaves `topic`, or nothing when it was never joined.
  std::optional<std::pair<std::string, std::string>> leave(const std::string& topic);
  /// The frame that pushes `event` to a joined topic, or nothing when it
  /// was never joined.
  std::optional<std::pair<std::string, std::string>> push(const std::string& topic,
                                                          const std::string& event,
                                                          const json& payload);
  bool joined(const std::string& topic) const;

  /// A heartbeat frame when one is due (empty otherwise), or false when the
  /// last one went unanswered: the connection is dead.
  bool heartbeat(std::chrono::milliseconds now, std::string& frame);

  /// A text frame, decoded; nothing for internal traffic (heartbeat replies)
  /// and for text that is not a frame.
  std::optional<Frame> decode(std::string_view text);
  /// A binary frame, decoded; nothing when it is not one.
  std::optional<Frame> decode_binary(std::string_view bytes);

  /// Forget every join: the socket closed, and a new one starts clean.
  void reset(std::chrono::milliseconds now);

 private:
  std::string fresh_ref();
  const std::string* join_ref_of(const std::string& topic) const;
  void forget(const std::string& topic);

  std::uint64_t next_ref_ = 1;
  std::vector<std::pair<std::string, std::string>> joins_;  // topic, join_ref
  std::chrono::milliseconds last_heartbeat_;
  std::string pending_heartbeat_;
};

}  // namespace gamend::detail
