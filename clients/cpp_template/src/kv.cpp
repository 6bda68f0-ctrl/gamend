#include "gamend/kv.hpp"

#include <utility>
#include <vector>

#include "core.hpp"
#include "gamend/events.hpp"
#include "query.hpp"

namespace gamend {

namespace {

json scope_payload(const KvKey& key) {
  json payload = {{"key", key.key}};
  if (!key.user_id.empty()) payload["user_id"] = key.user_id;
  if (!key.lobby_id.empty()) payload["lobby_id"] = key.lobby_id;
  return payload;
}

KvKey key_of(const json& payload) {
  return {text(payload, "key"), text(payload, "user_id"), text(payload, "lobby_id")};
}

}  // namespace

Kv::Kv(detail::Core& core) : core_(core) {
  core_.realtime.on_event([this](const Event& e) { event(e.kind, e.payload); });
}

Kv::~Kv() = default;

void Kv::subscribe(KvKey key, KvCallback done) {
  core_.loop->exclusive([&] {
    bool fresh = subscriptions_.find(key) == subscriptions_.end();
    auto& waiting = subscriptions_[key];
    if (done) waiting.push_back(std::move(done));
    if (fresh && core_.realtime.joined(core_.realtime.user_topic())) send_subscribe(key);
  });
}

void Kv::unsubscribe(const KvKey& key) {
  core_.loop->exclusive([&] {
    if (subscriptions_.erase(key) == 0) return;
    confirmed_.erase(key);
    auto topic = core_.realtime.user_topic();
    if (core_.realtime.joined(topic)) {
      core_.realtime.push(topic, "kv:unsubscribe", scope_payload(key));
    }
  });
}

bool Kv::subscribed(const KvKey& key) const {
  return core_.loop->exclusive([&] {
    auto it = confirmed_.find(key);
    return it != confirmed_.end() && it->second;
  });
}

void Kv::send_subscribe(const KvKey& key) {
  core_.realtime.push(
      core_.realtime.user_topic(), "kv:subscribe", scope_payload(key),
      [this, key](const Reply& reply) {
        auto it = subscriptions_.find(key);
        if (it == subscriptions_.end()) return;  // unsubscribed meanwhile
        std::vector<KvCallback> waiting;
        waiting.swap(it->second);
        KvResult result;
        if (reply.ok) {
          confirmed_[key] = true;
          result.ok = true;
          result.row.exists = !field(reply.response, "missing").is_boolean() ||
                              !field(reply.response, "missing").get<bool>();
          result.row.data = field(reply.response, "data");
          result.row.metadata = field(reply.response, "metadata");
          store(key, result.row);
        } else {
          result.error = reply.error;
          if (reply.status == "error") {
            // Forbidden or invalid: asking again will not change the answer.
            subscriptions_.erase(key);
            core_.log(LogLevel::Warning,
                      "gamend: kv subscribe to " + key.key + " refused: " + reply.error);
          }
        }
        for (auto& done : waiting) {
          if (done) done(result);
        }
      });
}

void Kv::user_channel_joined() {
  // A fresh join means the server forgot every subscription.
  confirmed_.clear();
  for (auto& [key, waiting] : subscriptions_) send_subscribe(key);
}

std::optional<KvRow> Kv::row(const KvKey& key) const {
  return core_.loop->exclusive([&]() -> std::optional<KvRow> {
    auto it = rows_.find(key);
    if (it == rows_.end()) return std::nullopt;
    return it->second;
  });
}

void Kv::fetch(KvKey key, bool force, KvCallback done) {
  core_.loop->exclusive([&] {
    auto it = rows_.find(key);
    if (!force && it != rows_.end()) {
      KvResult cached;
      cached.ok = true;
      cached.row = it->second;
      if (done) core_.post([done = std::move(done), cached] { done(cached); });
      return;
    }
    json options = json::object();
    if (!key.user_id.empty()) options["user_id"] = key.user_id;
    if (!key.lobby_id.empty()) options["lobby_id"] = key.lobby_id;
    core_.api.kv_get_kv(key.key, options,
                        [this, key, done = std::move(done)](const Response& r) {
                          KvResult result;
                          if (r.ok()) {
                            result.ok = true;
                            result.row.exists = true;
                            result.row.data = field(r.data(), "data");
                            result.row.metadata = field(r.data(), "metadata");
                            store(key, result.row);
                          } else if (r.status == 404) {
                            // The server's word that there is no row.
                            result.ok = true;
                            store(key, result.row);
                          } else {
                            result.error = r.error;
                          }
                          if (done) done(result);
                        });
  });
}

void Kv::store(const KvKey& key, KvRow row) {
  rows_[key] = row;
  auto listeners = listeners_;
  for (auto& [id, listener] : listeners) {
    if (listener) listener(key, row);
  }
}

void Kv::event(const std::string& kind, const json& payload) {
  if (kind == events::KV_UPDATED) {
    KvRow row;
    row.exists = true;
    row.data = field(payload, "data");
    row.metadata = field(payload, "metadata");
    store(key_of(payload), std::move(row));
  } else if (kind == events::KV_DELETED) {
    store(key_of(payload), KvRow{});
  }
}

std::uint64_t Kv::on_change(KvListener listener) {
  return core_.loop->exclusive([&] {
    auto id = next_listener_++;
    listeners_.emplace(id, std::move(listener));
    return id;
  });
}

void Kv::off(std::uint64_t id) {
  core_.loop->exclusive([&] { listeners_.erase(id); });
}

void Kv::clear() {
  core_.loop->exclusive([&] {
    rows_.clear();
    subscriptions_.clear();
    confirmed_.clear();
  });
}

}  // namespace gamend
