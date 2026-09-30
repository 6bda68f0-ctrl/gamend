#include "gamend/realtime.hpp"

#include <algorithm>
#include <utility>

#include "core.hpp"
#include "gamend/events.hpp"
#include "phoenix.hpp"
#include "proto.hpp"
#include "query.hpp"

namespace gamend {

struct Realtime::Topic {
  std::string name;
  json params;
  bool joined = false;
  /// A join frame is out and its reply has not come.
  bool joining = false;
  /// What `join` callers wait on: the next join reply.
  std::vector<ReplyCallback> waiting;
  std::uint64_t rejoin_timer = 0;
};

struct Realtime::Pending {
  std::string topic;
  bool join = false;
  ReplyCallback done;
  std::uint64_t timer = 0;
};

namespace {

Reply reply_of(const std::string& status, json response) {
  Reply reply;
  reply.status = status;
  reply.ok = status == "ok";
  reply.response = std::move(response);
  if (!reply.ok) {
    reply.error = text(reply.response, "error", text(reply.response, "reason", status));
  }
  return reply;
}

Reply local_reply(const std::string& status) { return reply_of(status, json::object()); }

// How long a channel that errored waits before it tries to join again.
constexpr std::chrono::milliseconds kRejoin{1000};

}  // namespace

Realtime::Realtime(detail::Core& core)
    : core_(core), phoenix_(std::make_unique<detail::Phoenix>()) {}

Realtime::~Realtime() = default;

void Realtime::connect() {
  core_.loop->exclusive([&] {
    if (wanted_) return;
    wanted_ = true;
    ever_opened_ = false;
    attempt_ = 0;
    open();
  });
}

void Realtime::disconnect() {
  core_.loop->exclusive([&] {
    wanted_ = false;
    close_socket();
    for (auto& topic : topics_) core_.loop->cancel(topic.rejoin_timer);
    std::vector<ReplyCallback> waiting;
    for (auto& topic : topics_) {
      for (auto& done : topic.waiting) waiting.push_back(std::move(done));
    }
    topics_.clear();
    for (auto& done : waiting) {
      if (done) done(local_reply("disconnected"));
    }
    set_state(RealtimeState::Disconnected);
  });
}

void Realtime::close_socket() {
  ++generation_;  // whatever the old socket still reports is about nothing now
  core_.loop->cancel(heartbeat_timer_);
  core_.loop->cancel(reconnect_timer_);
  heartbeat_timer_ = reconnect_timer_ = 0;
  if (auto* socket = core_.config.websocket.get()) socket->close();
  for (auto& topic : topics_) topic.joined = topic.joining = false;
  fail_pending("disconnected");
}

std::string Realtime::url() const {
  std::string base = core_.base_url;
  if (base.rfind("https://", 0) == 0) {
    base = "wss://" + base.substr(8);
  } else if (base.rfind("http://", 0) == 0) {
    base = "ws://" + base.substr(7);
  }
  auto session = core_.auth.session();
  std::string url = base + "/socket/websocket?vsn=2.0.0";
  url += "&token=" + detail::escape(session ? session->access_token : "");
  url += "&client_session=" + detail::escape(core_.run_id);
  if (core_.config.realtime_format == RealtimeFormat::Protobuf) url += "&format=protobuf";
  return url;
}

void Realtime::open() {
  auto* socket = core_.config.websocket.get();
  auto session = core_.auth.session();
  if (!wanted_) return;
  if (socket == nullptr || !session) {
    core_.log(LogLevel::Error, socket == nullptr ? "gamend: realtime has no WebSocket transport"
                                                 : "gamend: realtime needs a signed-in player");
    wanted_ = false;
    set_state(RealtimeState::Disconnected);
    return;
  }
  if (!user_id_.empty() && session->user_id != user_id_) {
    // Another player: their channels, none of the last one's.
    std::vector<ReplyCallback> waiting;
    for (auto& topic : topics_) {
      core_.loop->cancel(topic.rejoin_timer);
      for (auto& done : topic.waiting) waiting.push_back(std::move(done));
    }
    topics_.clear();
    for (auto& done : waiting) {
      if (done) done(local_reply("disconnected"));
    }
  }
  user_id_ = session->user_id;
  auto user = "user:" + user_id_;
  if (find(user) == nullptr) {
    Topic topic;
    topic.name = user;
    topic.params = json::object();
    topics_.insert(topics_.begin(), std::move(topic));
  }

  auto generation = ++generation_;
  last_opened_ = false;
  set_state(ever_opened_ ? RealtimeState::Reconnecting : RealtimeState::Connecting);
  auto post = core_.post;
  WebSocketHandlers handlers;
  handlers.on_open = [this, post, generation] {
    post([this, generation] { opened(generation); });
  };
  handlers.on_text = [this, post, generation](std::string text) {
    post([this, generation, text = std::move(text)] { received(generation, text); });
  };
  handlers.on_binary = [this, post, generation](std::string bytes) {
    post([this, generation, bytes = std::move(bytes)] { received_binary(generation, bytes); });
  };
  handlers.on_close = [this, post, generation](int code, std::string reason) {
    post([this, generation, why = "closed (" + std::to_string(code) + ") " + reason] {
      dropped(generation, why);
    });
  };
  handlers.on_error = [this, post, generation](std::string error) {
    post([this, generation, error = std::move(error)] { dropped(generation, error); });
  };
  socket->open(url(), std::move(handlers));
}

void Realtime::opened(std::uint64_t generation) {
  if (generation != generation_) return;
  ever_opened_ = last_opened_ = true;
  attempt_ = 0;
  phoenix_->reset(core_.loop->now());
  set_state(RealtimeState::Connected);
  for (auto& topic : topics_) send_join(topic);
  schedule_heartbeat();
}

void Realtime::send_join(Topic& topic) {
  core_.loop->cancel(topic.rejoin_timer);
  topic.rejoin_timer = 0;
  auto [ref, text] = phoenix_->join(topic.name, topic.params);
  topic.joining = true;
  topic.joined = false;
  track(ref, topic.name, true, {});
  core_.config.websocket->send_text(std::move(text));
}

void Realtime::schedule_heartbeat() {
  core_.loop->cancel(heartbeat_timer_);
  heartbeat_timer_ = core_.loop->after(detail::Phoenix::kHeartbeat, [this, generation = generation_] {
    if (generation != generation_) return;
    std::string beat;
    if (!phoenix_->heartbeat(core_.loop->now(), beat)) {
      core_.log(LogLevel::Warning, "gamend: the server missed a heartbeat; reconnecting");
      close_socket();
      schedule_reconnect();
      return;
    }
    if (!beat.empty()) core_.config.websocket->send_text(std::move(beat));
    schedule_heartbeat();
  });
}

void Realtime::received(std::uint64_t generation, const std::string& text) {
  if (generation != generation_) return;
  if (auto decoded = phoenix_->decode(text)) frame(std::move(*decoded));
}

void Realtime::received_binary(std::uint64_t generation, const std::string& bytes) {
  if (generation != generation_) return;
  if (auto decoded = phoenix_->decode_binary(bytes)) frame(std::move(*decoded));
}

void Realtime::frame(detail::Frame frame) {
  if (frame.kind == detail::Frame::Kind::Reply) {
    auto it = pending_.find(frame.ref);
    if (it == pending_.end()) return;
    Pending pending = std::move(it->second);
    pending_.erase(it);
    core_.loop->cancel(pending.timer);
    json response = frame.bytes ? json(nullptr) : std::move(frame.payload);
    Reply reply = reply_of(frame.status, std::move(response));
    if (pending.join) {
      std::vector<ReplyCallback> waiting;
      if (auto* topic = find(pending.topic)) {
        topic->joining = false;
        topic->joined = reply.ok;
        waiting.swap(topic->waiting);
        if (!reply.ok) {
          core_.log(LogLevel::Warning,
                    "gamend: joining " + pending.topic + " failed: " + reply.error);
          // A refusal the server will repeat: stop asking.
          if (reply.error == "unauthorized" || reply.error == "forbidden" ||
              reply.error == "not_found" || reply.error == "invalid topic") {
            topics_.erase(std::remove_if(topics_.begin(), topics_.end(),
                                         [&](const Topic& t) { return t.name == pending.topic; }),
                          topics_.end());
          } else {
            schedule_rejoin(pending.topic);
          }
        }
      }
      if (reply.ok && pending.topic == "user:" + user_id_) core_.kv.user_channel_joined();
      for (auto& done : waiting) {
        if (done) done(reply);
      }
    }
    if (pending.done) pending.done(reply);
    return;
  }

  if (frame.event == "phx_error") {
    // The channel crashed on the server; Phoenix's clients join it again.
    if (auto* topic = find(frame.topic)) {
      topic->joined = topic->joining = false;
      schedule_rejoin(frame.topic);
    }
  } else if (frame.event == "phx_close") {
    // The server closed the channel (a kick, a disband): not rejoined.
    topics_.erase(std::remove_if(topics_.begin(), topics_.end(),
                                 [&](const Topic& t) { return t.name == frame.topic; }),
                  topics_.end());
  }

  Event event;
  event.topic = std::move(frame.topic);
  event.event = std::move(frame.event);
  event.kind = std::string(events::signal_of(event.topic, event.event));
  event.binary = frame.bytes.has_value();
  if (frame.bytes) {
    detail::proto::BytesHook hook = [this](std::string_view message, std::string_view field,
                                           std::string_view bytes,
                                           const json& decoded) -> std::optional<json> {
      if (field == "metadata_pb") {
        // The message a metadata map rides in names whose it is.
        std::string entity = message == "Lobby" ? "lobby"
                             : message == "Group" ? "group"
                             : message == "Party" ? "party"
                                                  : "user";
        auto it = metadata_decoders_.find(entity);
        return it == metadata_decoders_.end() ? std::nullopt : it->second(bytes);
      }
      if (field == "data_pb" && message == "KvEntry") {
        auto key = text(decoded, "key");
        const BytesDecoder* best = nullptr;
        std::size_t best_length = 0;
        for (const auto& [pattern, decoder] : kv_decoders_) {
          if (pattern == key) return decoder(bytes);
          if (!pattern.empty() && pattern.back() == '*') {
            auto prefix = std::string_view(pattern).substr(0, pattern.size() - 1);
            if (key.compare(0, prefix.size(), prefix) == 0 && prefix.size() >= best_length) {
              best = &decoder;
              best_length = prefix.size();
            }
          }
        }
        return best != nullptr ? (*best)(bytes) : std::nullopt;
      }
      return std::nullopt;
    };
    auto decoded = detail::decode_binary_event(event.topic, event.event, *frame.bytes, &hook);
    if (decoded) {
      event.payload = std::move(*decoded);
    } else {
      event.bytes = std::move(*frame.bytes);
      core_.log(LogLevel::Warning,
                "gamend: no decoder for the binary " + event.event + " on " + event.topic);
    }
  } else {
    event.payload = std::move(frame.payload);
  }
  emit(event);
}

void Realtime::emit(const Event& event) {
  // A listener may add or remove listeners; walk a copy.
  auto listeners = event_listeners_;
  for (auto& [id, listener] : listeners) {
    if (listener) listener(event);
  }
}

void Realtime::schedule_rejoin(const std::string& name) {
  auto* topic = find(name);
  if (topic == nullptr) return;
  core_.loop->cancel(topic->rejoin_timer);
  topic->rejoin_timer = core_.loop->after(kRejoin, [this, name, generation = generation_] {
    if (generation != generation_ || state() != RealtimeState::Connected) return;
    if (auto* again = find(name); again != nullptr && !again->joined && !again->joining) {
      send_join(*again);
    }
  });
}

void Realtime::dropped(std::uint64_t generation, const std::string& why) {
  if (generation != generation_) return;
  core_.log(LogLevel::Info, "gamend: realtime connection lost: " + why);
  close_socket();
  schedule_reconnect();
}

void Realtime::schedule_reconnect() {
  if (!wanted_) {
    set_state(RealtimeState::Disconnected);
    return;
  }
  set_state(ever_opened_ ? RealtimeState::Reconnecting : RealtimeState::Connecting);
  const auto& delays = core_.config.reconnect_delays;
  auto delay = delays.empty() ? std::chrono::milliseconds(1000)
                              : delays[(std::min)(attempt_, delays.size() - 1)];
  ++attempt_;
  bool refresh_first = !last_opened_;
  reconnect_timer_ = core_.loop->after(delay, [this, refresh_first] {
    reconnect_timer_ = 0;
    if (!wanted_) return;
    if (!refresh_first) return open();
    // The last attempt never opened: the token may have lapsed while the
    // network was away. Refresh it first; open either way.
    core_.auth.refresh_then([this](bool) { open(); });
  });
}

void Realtime::fail_pending(const std::string& status) {
  auto pending = std::move(pending_);
  pending_.clear();
  std::vector<ReplyCallback> waiting;
  for (auto& [ref, entry] : pending) {
    core_.loop->cancel(entry.timer);
    if (entry.join) {
      if (auto* topic = find(entry.topic)) {
        // A join waiting on this connection waits on the next one.
        topic->joining = false;
      }
    }
    if (entry.done) waiting.push_back(std::move(entry.done));
  }
  for (auto& done : waiting) done(local_reply(status));
}

void Realtime::track(const std::string& ref, std::string topic, bool join, ReplyCallback done) {
  Pending pending;
  pending.topic = std::move(topic);
  pending.join = join;
  pending.done = std::move(done);
  pending.timer = core_.loop->after(core_.config.push_timeout, [this, ref] {
    auto it = pending_.find(ref);
    if (it == pending_.end()) return;
    Pending timed_out = std::move(it->second);
    pending_.erase(it);
    std::vector<ReplyCallback> waiting;
    if (timed_out.join) {
      if (auto* topic = find(timed_out.topic)) {
        topic->joining = false;
        waiting.swap(topic->waiting);
        schedule_rejoin(timed_out.topic);
      }
    }
    for (auto& done : waiting) {
      if (done) done(local_reply("timeout"));
    }
    if (timed_out.done) timed_out.done(local_reply("timeout"));
  });
  pending_.emplace(ref, std::move(pending));
}

void Realtime::join(std::string name, json params, ReplyCallback done) {
  core_.loop->exclusive([&] {
    auto* topic = find(name);
    if (topic != nullptr && topic->joined) {
      if (done) core_.post([done = std::move(done)] { done(reply_of("ok", json::object())); });
      return;
    }
    if (topic == nullptr) {
      Topic fresh;
      fresh.name = name;
      fresh.params = params.is_object() ? std::move(params) : json::object();
      topics_.push_back(std::move(fresh));
      topic = &topics_.back();
    }
    if (done) topic->waiting.push_back(std::move(done));
    if (state() == RealtimeState::Connected && !topic->joining) send_join(*topic);
  });
}

void Realtime::leave(std::string name, ReplyCallback done) {
  core_.loop->exclusive([&] {
    auto* topic = find(name);
    bool joined = topic != nullptr && topic->joined;
    if (topic != nullptr) {
      core_.loop->cancel(topic->rejoin_timer);
      std::vector<ReplyCallback> waiting;
      waiting.swap(topic->waiting);
      topics_.erase(std::remove_if(topics_.begin(), topics_.end(),
                                   [&](const Topic& t) { return t.name == name; }),
                    topics_.end());
      for (auto& waiter : waiting) {
        if (waiter) waiter(local_reply("left"));
      }
    }
    auto frame = joined ? phoenix_->leave(name) : std::nullopt;
    if (!frame) {
      if (done) core_.post([done = std::move(done)] { done(reply_of("ok", json::object())); });
      return;
    }
    track(frame->first, name, false, std::move(done));
    core_.config.websocket->send_text(std::move(frame->second));
  });
}

bool Realtime::joined(const std::string& name) const {
  return core_.loop->exclusive([&] {
    for (const auto& topic : topics_) {
      if (topic.name == name) return topic.joined;
    }
    return false;
  });
}

void Realtime::join_lobby(const std::string& id, ReplyCallback done) {
  join("lobby:" + id, json::object(), std::move(done));
}
void Realtime::join_lobbies(ReplyCallback done) { join("lobbies", json::object(), std::move(done)); }
void Realtime::join_group(const std::string& id, ReplyCallback done) {
  join("group:" + id, json::object(), std::move(done));
}
void Realtime::join_groups(ReplyCallback done) { join("groups", json::object(), std::move(done)); }
void Realtime::join_party(const std::string& id, ReplyCallback done) {
  join("party:" + id, json::object(), std::move(done));
}

void Realtime::push(std::string topic, std::string event, json payload, ReplyCallback done) {
  core_.loop->exclusive([&] {
    auto* tracked = find(topic);
    auto frame = (state() == RealtimeState::Connected && tracked != nullptr && tracked->joined)
                     ? phoenix_->push(topic, event, payload)
                     : std::nullopt;
    if (!frame) {
      if (done) core_.post([done = std::move(done)] { done(local_reply("not_joined")); });
      return;
    }
    track(frame->first, topic, false, std::move(done));
    core_.config.websocket->send_text(std::move(frame->second));
  });
}

void Realtime::call_hook(std::string plugin, std::string fn, json args, HookCallback done) {
  if (!args.is_array()) args = args.is_null() ? json::array() : json::array({std::move(args)});
  json payload = {{"plugin", std::move(plugin)}, {"fn", std::move(fn)}, {"args", std::move(args)}};
  push(user_topic(), "call_hook", std::move(payload), [done = std::move(done)](const Reply& r) {
    if (!done) return;
    HookResult result;
    result.ok = r.ok;
    result.data = r.ok ? field(r.response, "data") : json();
    result.error = r.error;
    done(result);
  });
}

std::uint64_t Realtime::on_event(EventCallback listener) {
  return core_.loop->exclusive([&] {
    auto id = next_listener_++;
    event_listeners_.emplace(id, std::move(listener));
    return id;
  });
}

std::uint64_t Realtime::on_state(StateCallback listener) {
  return core_.loop->exclusive([&] {
    auto id = next_listener_++;
    state_listeners_.emplace(id, std::move(listener));
    return id;
  });
}

void Realtime::off(std::uint64_t id) {
  core_.loop->exclusive([&] {
    event_listeners_.erase(id);
    state_listeners_.erase(id);
  });
}

void Realtime::register_metadata_decoder(std::string entity, BytesDecoder decoder) {
  core_.loop->exclusive([&] { metadata_decoders_[std::move(entity)] = std::move(decoder); });
}

void Realtime::register_kv_decoder(std::string pattern, BytesDecoder decoder) {
  core_.loop->exclusive([&] { kv_decoders_[std::move(pattern)] = std::move(decoder); });
}

std::string Realtime::user_topic() const {
  auto session = core_.auth.session();
  return session ? "user:" + session->user_id : std::string();
}

void Realtime::session_changed(const std::optional<Session>& session) {
  if (!wanted_) return;
  if (!session) {
    // Signed out: nothing to be connected as.
    disconnect();
    return;
  }
  if (session->user_id != user_id_) {
    // Another player signed in: reconnect as them.
    close_socket();
    ever_opened_ = false;
    attempt_ = 0;
    open();
  }
}

void Realtime::set_state(RealtimeState state) {
  if (state_.exchange(state) == state) return;
  auto listeners = state_listeners_;
  for (auto& [id, listener] : listeners) {
    if (listener) listener(state);
  }
}

Realtime::Topic* Realtime::find(const std::string& name) {
  for (auto& topic : topics_) {
    if (topic.name == name) return &topic;
  }
  return nullptr;
}

}  // namespace gamend
