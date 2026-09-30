#include "gamend/presence.hpp"

#include <utility>
#include <vector>

#include "core.hpp"
#include "gamend/events.hpp"

namespace gamend {

namespace {

std::string id_of(const json& payload) {
  auto id = text(payload, "user_id");
  return id.empty() ? text(payload, "id") : id;
}

}  // namespace

Presence::Presence(detail::Core& core) : core_(core) {
  core_.realtime.on_event([this](const Event& e) { event(e.kind, e.payload); });
}

Presence::~Presence() = default;

void Presence::event(const std::string& kind, const json& payload) {
  if (kind == events::USER_UPDATED) {
    apply_user_update(payload);
  } else if (kind == events::LOBBY_UPDATED) {
    auto id = text(payload, "id");
    if (id.empty()) return;
    lobbies_[id] = payload;
    lobby_changed(payload);
  } else if (kind == events::LOBBY_STATE_CHANGED) {
    // The flip comes out of band; an `updated` in flight may still carry the
    // old state, so it is patched in and announced.
    auto id = text(payload, "lobby_id");
    if (id.empty()) return;
    auto& lobby = lobbies_[id];
    if (!lobby.is_object()) lobby = {{"id", id}};
    lobby["state"] = text(payload, "to");
    lobby_changed(lobby);
  } else if (kind == events::LOBBY_MEMBER_JOINED || kind == events::LOBBY_MEMBER_UPDATED ||
             kind == events::PARTY_MEMBER_UPDATED || kind == events::GROUP_MEMBER_UPDATED) {
    auto id = id_of(payload);
    if (!id.empty()) {
      merge_into(id, payload, false);
      user_changed(id);
    }
  } else if (kind == events::LOBBY_MEMBER_ONLINE || kind == events::PARTY_MEMBER_ONLINE ||
             kind == events::GROUP_MEMBER_ONLINE) {
    auto id = id_of(payload);
    if (!id.empty()) {
      online_[id] = true;
      user_changed(id);
    }
  } else if (kind == events::LOBBY_MEMBER_OFFLINE || kind == events::PARTY_MEMBER_OFFLINE ||
             kind == events::GROUP_MEMBER_OFFLINE) {
    auto id = id_of(payload);
    if (!id.empty()) {
      online_[id] = false;
      last_seen_[id] = core_.unix_now();
      user_changed(id);
    }
  }
}

void Presence::apply_user_update(const json& user) {
  auto session = core_.auth.session();
  auto self = session ? session->user_id : std::string();
  auto id = text(user, "id", self);
  if (id.empty()) return;
  // The `user:<id>` push is the one payload with the WHOLE metadata map; a
  // `u`-wrapped body is partial and merges.
  bool wrapped = field(user, "u").is_object();
  merge_into(id, wrapped ? field(user, "u") : user, !wrapped);
  if (id == self) {
    // The player's own lobby_id is the truth: any other lobby is stale.
    auto current = text(users_[id], "lobby_id");
    for (auto it = lobbies_.begin(); it != lobbies_.end();) {
      it = it->first == current ? std::next(it) : lobbies_.erase(it);
    }
  }
  user_changed(id);
}

void Presence::merge_into(const std::string& id, const json& patch, bool metadata_is_whole) {
  auto& existing = users_[id];
  if (!existing.is_object()) existing = {{"id", id}};
  if (!patch.is_object()) return;
  for (auto it = patch.begin(); it != patch.end(); ++it) {
    if (it.key() == "metadata" && it->is_object()) {
      existing["metadata"] =
          metadata_is_whole ? *it : merge_metadata(field(existing, "metadata"), *it);
    } else {
      existing[it.key()] = *it;
    }
  }
}

json Presence::merge_metadata(const json& existing, const json& patch) {
  json merged = existing.is_object() ? existing : json::object();
  if (!patch.is_object()) return merged;
  for (auto it = patch.begin(); it != patch.end(); ++it) {
    auto current = merged.find(it.key());
    if (it->is_object() && current != merged.end() && current->is_object()) {
      for (auto section = it->begin(); section != it->end(); ++section) {
        (*current)[section.key()] = *section;
      }
    } else {
      merged[it.key()] = *it;
    }
  }
  return merged;
}

json Presence::user(const std::string& id) const {
  return core_.loop->exclusive([&] {
    auto it = users_.find(id);
    return it == users_.end() ? json::object() : it->second;
  });
}

json Presence::lobby(const std::string& id) const {
  return core_.loop->exclusive([&] {
    auto it = lobbies_.find(id);
    return it == lobbies_.end() ? json::object() : it->second;
  });
}

bool Presence::online(const std::string& id) const {
  auto session = core_.auth.session();
  if (session && session->user_id == id) return true;
  return core_.loop->exclusive([&] {
    auto it = online_.find(id);
    return it != online_.end() && it->second;
  });
}

std::int64_t Presence::last_seen(const std::string& id) const {
  return core_.loop->exclusive([&]() -> std::int64_t {
    auto it = last_seen_.find(id);
    return it == last_seen_.end() ? 0 : it->second;
  });
}

void Presence::set_online(const std::string& id, bool is_online, std::int64_t seen) {
  core_.loop->exclusive([&] {
    online_[id] = is_online;
    if (!is_online && seen > 0) last_seen_[id] = seen;
  });
}

void Presence::cache_user(const std::string& id, const json& data) {
  if (id.empty()) return;
  core_.loop->exclusive([&] {
    merge_into(id, data, false);
    user_changed(id);
  });
}

void Presence::clear() {
  core_.loop->exclusive([&] {
    users_.clear();
    lobbies_.clear();
    online_.clear();
    last_seen_.clear();
  });
}

void Presence::user_changed(const std::string& id) {
  auto listeners = user_listeners_;
  for (auto& [key, listener] : listeners) {
    if (listener) listener(id);
  }
}

void Presence::lobby_changed(const json& lobby) {
  auto listeners = lobby_listeners_;
  for (auto& [key, listener] : listeners) {
    if (listener) listener(lobby);
  }
}

std::uint64_t Presence::on_user_changed(std::function<void(const std::string&)> listener) {
  return core_.loop->exclusive([&] {
    auto id = next_listener_++;
    user_listeners_.emplace(id, std::move(listener));
    return id;
  });
}

std::uint64_t Presence::on_lobby_changed(std::function<void(const json&)> listener) {
  return core_.loop->exclusive([&] {
    auto id = next_listener_++;
    lobby_listeners_.emplace(id, std::move(listener));
    return id;
  });
}

void Presence::off(std::uint64_t id) {
  core_.loop->exclusive([&] {
    user_listeners_.erase(id);
    lobby_listeners_.erase(id);
  });
}

}  // namespace gamend
