#include "phoenix.hpp"

#include <algorithm>

namespace gamend::detail {
namespace {

std::string frame(const std::string* join_ref, const std::string& ref, const std::string& topic,
                  const std::string& event, const json& payload) {
  json parts = json::array({join_ref ? json(*join_ref) : json(nullptr), ref, topic, event, payload});
  return dump(parts);
}

// Binary frame kinds, as `Phoenix.Socket.V2.JSONSerializer` numbers them.
constexpr unsigned char kPush = 0;
constexpr unsigned char kReply = 1;
constexpr unsigned char kBroadcast = 2;

// Reads length-prefixed pieces off a binary frame, refusing to run past it.
class Reader {
 public:
  explicit Reader(std::string_view bytes) : bytes_(bytes) {}
  bool byte(std::size_t& out) {
    if (at_ >= bytes_.size()) return false;
    out = static_cast<unsigned char>(bytes_[at_++]);
    return true;
  }
  bool text(std::size_t size, std::string& out) {
    if (bytes_.size() - at_ < size) return false;
    out.assign(bytes_.substr(at_, size));
    at_ += size;
    return true;
  }
  std::string rest() const { return std::string(bytes_.substr(at_)); }

 private:
  std::string_view bytes_;
  std::size_t at_ = 0;
};

}  // namespace

std::string Phoenix::fresh_ref() { return std::to_string(next_ref_++); }

const std::string* Phoenix::join_ref_of(const std::string& topic) const {
  for (const auto& [joined, join_ref] : joins_) {
    if (joined == topic) return &join_ref;
  }
  return nullptr;
}

void Phoenix::forget(const std::string& topic) {
  joins_.erase(std::remove_if(joins_.begin(), joins_.end(),
                              [&](const auto& join) { return join.first == topic; }),
               joins_.end());
}

std::pair<std::string, std::string> Phoenix::join(const std::string& topic, const json& payload) {
  auto ref = fresh_ref();
  forget(topic);
  joins_.emplace_back(topic, ref);
  return {ref, frame(&ref, ref, topic, "phx_join", payload)};
}

std::optional<std::pair<std::string, std::string>> Phoenix::leave(const std::string& topic) {
  const auto* join_ref = join_ref_of(topic);
  if (join_ref == nullptr) return std::nullopt;
  auto ref = fresh_ref();
  auto text = frame(join_ref, ref, topic, "phx_leave", json::object());
  forget(topic);
  return std::make_pair(ref, text);
}

std::optional<std::pair<std::string, std::string>> Phoenix::push(const std::string& topic,
                                                                 const std::string& event,
                                                                 const json& payload) {
  const auto* join_ref = join_ref_of(topic);
  if (join_ref == nullptr) return std::nullopt;
  auto ref = fresh_ref();
  return std::make_pair(ref, frame(join_ref, ref, topic, event, payload));
}

bool Phoenix::joined(const std::string& topic) const { return join_ref_of(topic) != nullptr; }

bool Phoenix::heartbeat(std::chrono::milliseconds now, std::string& out) {
  out.clear();
  if (now - last_heartbeat_ < kHeartbeat) return true;
  if (!pending_heartbeat_.empty()) return false;
  auto ref = fresh_ref();
  out = frame(nullptr, ref, "phoenix", "heartbeat", json::object());
  pending_heartbeat_ = ref;
  last_heartbeat_ = now;
  return true;
}

std::optional<Frame> Phoenix::decode(std::string_view text) {
  auto parts = parse(text);
  if (parts.is_discarded() || !parts.is_array() || parts.size() != 5) return std::nullopt;
  auto str = [&](std::size_t i) {
    return parts[i].is_string() ? parts[i].get<std::string>() : std::string();
  };
  Frame out;
  out.ref = str(1);
  out.topic = str(2);
  out.event = str(3);

  if (out.topic == "phoenix") {
    if (out.ref == pending_heartbeat_) pending_heartbeat_.clear();
    return std::nullopt;
  }
  if (out.event == "phx_reply") {
    const auto& reply = parts[4];
    out.kind = Frame::Kind::Reply;
    out.event.clear();
    out.status = gamend::text(reply, "status");
    out.payload = field(reply, "response");
    return out;
  }
  if (out.event == "phx_error" || out.event == "phx_close") forget(out.topic);
  out.kind = Frame::Kind::Message;
  out.payload = std::move(parts[4]);
  return out;
}

std::optional<Frame> Phoenix::decode_binary(std::string_view bytes) {
  Reader reader(bytes);
  std::size_t kind = 0;
  if (!reader.byte(kind)) return std::nullopt;
  Frame out;
  std::string ignored;
  if (kind == kPush) {
    std::size_t join_ref_size = 0, topic_size = 0, event_size = 0;
    if (!reader.byte(join_ref_size) || !reader.byte(topic_size) || !reader.byte(event_size) ||
        !reader.text(join_ref_size, ignored) || !reader.text(topic_size, out.topic) ||
        !reader.text(event_size, out.event)) {
      return std::nullopt;
    }
  } else if (kind == kReply) {
    std::size_t join_ref_size = 0, ref_size = 0, topic_size = 0, status_size = 0;
    if (!reader.byte(join_ref_size) || !reader.byte(ref_size) || !reader.byte(topic_size) ||
        !reader.byte(status_size) || !reader.text(join_ref_size, ignored) ||
        !reader.text(ref_size, out.ref) || !reader.text(topic_size, out.topic) ||
        !reader.text(status_size, out.status)) {
      return std::nullopt;
    }
    out.kind = Frame::Kind::Reply;
  } else if (kind == kBroadcast) {
    std::size_t topic_size = 0, event_size = 0;
    if (!reader.byte(topic_size) || !reader.byte(event_size) ||
        !reader.text(topic_size, out.topic) || !reader.text(event_size, out.event)) {
      return std::nullopt;
    }
  } else {
    return std::nullopt;
  }
  out.bytes = reader.rest();
  return out;
}

void Phoenix::reset(std::chrono::milliseconds now) {
  joins_.clear();
  pending_heartbeat_.clear();
  last_heartbeat_ = now;
}

}  // namespace gamend::detail
