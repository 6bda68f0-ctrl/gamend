// The conformance scenario (docs/specs/client-sdks.md), live:
//
//   gamend_conformance http://127.0.0.1:4000
//
// 1. `POST /login/device` answers a session; `GET /me` works with its token.
// 2. `POST /refresh` answers a new token, and the next call carries it.
// 3. The socket connects (`vsn=2.0.0`) and joins `user:<id>`.
// 4. A lobby is created, `lobby:<id>` joined, and an update arrives as
//    `updated`.
// 5. A server hook answers; a hook that does not exist answers its error.
// 6. A KV subscription hears a write made through the API.
// 7. A dropped socket reconnects, rejoins its topics, and events resume.
// 8. Leaving the lobby and disconnecting end cleanly.
// 9. (built with GAMEND_WITH_WEBRTC) A WebRTC connection opens both default
//    DataChannels, `events` and `state`, and a hook answers over `events`.
//
// The server needs device sign-in (its default) and the example plugins
// (`GAMEND_CONTENT_PLUGINS_DIR=modules/plugins_examples`). Step 6 writes as
// an admin: set GAMEND_ADMIN_EMAIL and GAMEND_ADMIN_PASSWORD, or it is
// skipped. Exits non-zero on the first step that fails.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>
#include <utility>

#include "gamend/gamend.hpp"

namespace {

// The curl transport, noting which token each call carried.
class Recording final : public gamend::HttpTransport {
 public:
  explicit Recording(std::unique_ptr<gamend::HttpTransport> inner) : inner_(std::move(inner)) {}

  void send(gamend::HttpRequest request, std::function<void(gamend::HttpResponse)> done) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      authorization_.clear();
      for (const auto& [name, value] : request.headers) {
        if (name == "authorization") authorization_ = value;
      }
    }
    inner_->send(std::move(request), std::move(done));
  }

  std::string last_authorization() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return authorization_;
  }

 private:
  std::unique_ptr<gamend::HttpTransport> inner_;
  mutable std::mutex mutex_;
  std::string authorization_;
};

#if defined(GAMEND_WITH_IXWEBSOCKET)
// The IXWebSocket transport, with a way to pull the plug the way a network
// does: the client is told the connection died, not that it closed it.
class Droppable final : public gamend::WebSocketTransport {
 public:
  explicit Droppable(std::unique_ptr<gamend::WebSocketTransport> inner)
      : inner_(std::move(inner)) {}

  void open(const std::string& url, gamend::WebSocketHandlers handlers) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      on_close_ = handlers.on_close;
    }
    inner_->open(url, std::move(handlers));
  }
  void send_text(std::string frame) override { inner_->send_text(std::move(frame)); }
  void close() override { inner_->close(); }

  void drop() {
    std::function<void(int, std::string)> on_close;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      on_close = on_close_;
    }
    inner_->close();
    if (on_close) on_close(1006, "dropped by the conformance run");
  }

 private:
  std::unique_ptr<gamend::WebSocketTransport> inner_;
  std::mutex mutex_;
  std::function<void(int, std::string)> on_close_;
};
#endif

// Poll as a game would, once a frame, until `done()` or `seconds`.
bool await(gamend::Client& client, const std::function<bool()>& done, int seconds = 10) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
  while (!done() && std::chrono::steady_clock::now() < deadline) {
    client.poll();
    std::this_thread::sleep_for(std::chrono::milliseconds(16));
  }
  return done();
}

// Run one call and wait for its answer.
template <class Result, class Start>
bool call(gamend::Client& client, Result& out, Start start) {
  bool finished = false;
  start([&](const Result& r) {
    out = r;
    finished = true;
  });
  return await(client, [&] { return finished; });
}

int fail(const char* step, const std::string& why) {
  std::fprintf(stderr, "FAIL %s: %s\n", step, why.c_str());
  return 1;
}

void ok(const std::string& line) { std::printf("ok   %s\n", line.c_str()); }

}  // namespace

int main(int argc, char** argv) {
  std::string url = "http://127.0.0.1:4000";
  bool protobuf = false;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--protobuf") {
      protobuf = true;
    } else {
      url = arg;
    }
  }
  auto recording = std::make_unique<Recording>(gamend::make_curl_transport());
  Recording* wire = recording.get();

  gamend::Config config;
  config.base_url = url;
  config.http = std::move(recording);
  if (protobuf) {
    config.realtime_format = gamend::RealtimeFormat::Protobuf;
    config.webrtc_format = gamend::RealtimeFormat::Protobuf;
  }
#if defined(GAMEND_WITH_WEBRTC)
  config.webrtc = gamend::make_libdatachannel_transport();
  // Both channels the JS and Godot clients open by default, so step 9 proves
  // the server takes more than one.
  config.data_channels = {{"events", true, -1}, {"state", false, 0}};
#endif
#if defined(GAMEND_WITH_IXWEBSOCKET)
  auto droppable = std::make_unique<Droppable>(gamend::make_ix_websocket_transport());
  Droppable* socket = droppable.get();
  config.websocket = std::move(droppable);
#endif
  gamend::Client client(std::move(config));

  // 1. Device sign-in, then /me with the token it answered.
  gamend::AuthResult login;
  if (!call<gamend::AuthResult>(client, login, [&](auto done) {
        client.auth().login_device("cpp-conformance-" + client.run_id(), done);
      })) {
    return fail("1 login_device", "no answer");
  }
  if (!login.ok) return fail("1 login_device", login.error);
  ok("1 login_device: user " + login.session.user_id);

  gamend::Response me;
  if (!call<gamend::Response>(client, me,
                              [&](auto done) { client.api().users_get_current_user(done); })) {
    return fail("1 GET /me", "no answer");
  }
  if (!me.ok()) return fail("1 GET /me", me.error);
  if (gamend::text(me.data(), "id") != login.session.user_id) {
    return fail("1 GET /me", "answered another user: " + gamend::dump(me.data()));
  }
  if (wire->last_authorization() != "Bearer " + login.session.access_token) {
    return fail("1 GET /me", "did not carry the sign-in token");
  }
  auto typed_me = me.as<gamend::models::CurrentUser>();
  if (!typed_me || typed_me->id != login.session.user_id) {
    return fail("1 GET /me", "did not read as models::CurrentUser");
  }
  ok("1 GET /me as " + typed_me->username);

  // 2. Refresh, and the next call carries the new token.
  gamend::AuthResult refreshed;
  if (!call<gamend::AuthResult>(client, refreshed,
                                [&](auto done) { client.auth().refresh(done); })) {
    return fail("2 refresh", "no answer");
  }
  if (!refreshed.ok) return fail("2 refresh", refreshed.error);
  if (refreshed.session.access_token == login.session.access_token) {
    return fail("2 refresh", "answered the same access token");
  }
  ok("2 refresh: new access token, expires in " +
     std::to_string(refreshed.session.expires_in) + "s");
  if (!call<gamend::Response>(client, me,
                              [&](auto done) { client.api().users_get_current_user(done); })) {
    return fail("2 GET /me", "no answer");
  }
  if (!me.ok()) return fail("2 GET /me", me.error);
  if (wire->last_authorization() != "Bearer " + refreshed.session.access_token) {
    return fail("2 GET /me", "did not carry the refreshed token");
  }
  ok("2 GET /me with the refreshed token");

#if !defined(GAMEND_WITH_IXWEBSOCKET)
  std::printf("skip 3-8: built without a WebSocket transport\n");
  return 0;
#else
  auto& realtime = client.realtime();
  std::vector<gamend::Event> events;
  realtime.on_event([&](const gamend::Event& e) { events.push_back(e); });
  // With --protobuf, an event only counts when it came as a decoded binary
  // frame: proof the server honoured the format, not that it was asked.
  auto saw = [&](std::string_view kind, const std::string& topic) {
    for (const auto& e : events) {
      if (e.kind == kind && e.topic == topic && e.binary == protobuf && !e.payload.is_null()) {
        return true;
      }
    }
    return false;
  };

  // 3. Connect; the user channel joins.
  auto user_topic = realtime.user_topic();
  realtime.connect();
  if (!await(client, [&] { return realtime.joined(user_topic); })) {
    return fail("3 connect", "user channel not joined");
  }
  ok("3 connected, joined " + user_topic);

  // 4. A lobby: create it, join its topic, hear its update.
  gamend::Response lobby;
  if (!call<gamend::Response>(client, lobby, [&](auto done) {
        client.api().lobbies_create_lobby({{"title", "cpp conformance"}, {"max_users", 2}}, done);
      })) {
    return fail("4 create lobby", "no answer");
  }
  if (!lobby.ok()) return fail("4 create lobby", lobby.error);
  auto typed_lobby = lobby.as<gamend::models::Lobby>();
  if (!typed_lobby || typed_lobby->id.empty() || typed_lobby->max_users != 2 ||
      typed_lobby->host_id != login.session.user_id) {
    return fail("4 create lobby", "did not read as models::Lobby: " + gamend::dump(lobby.data()));
  }
  auto lobby_id = typed_lobby->id;
  auto lobby_topic = "lobby:" + lobby_id;
  gamend::Reply joined;
  if (!call<gamend::Reply>(client, joined,
                           [&](auto done) { realtime.join_lobby(lobby_id, done); })) {
    return fail("4 join lobby", "no answer");
  }
  if (!joined.ok) return fail("4 join lobby", joined.error);
  gamend::Response renamed;
  if (!call<gamend::Response>(client, renamed, [&](auto done) {
        client.api().lobbies_update_lobby({{"title", "cpp conformance (renamed)"}}, done);
      })) {
    return fail("4 update lobby", "no answer");
  }
  if (!renamed.ok()) return fail("4 update lobby", renamed.error);
  if (!await(client, [&] { return saw(gamend::events::LOBBY_UPDATED, lobby_topic); })) {
    return fail("4 lobby updated", "no updated event on " + lobby_topic);
  }
  ok("4 joined " + lobby_topic + ", heard its update" + (protobuf ? " (protobuf)" : ""));

  // 5. A hook that answers, and one that does not exist.
  gamend::HookResult hook;
  if (!call<gamend::HookResult>(client, hook, [&](auto done) {
        realtime.call_hook("example_hook", "hello", gamend::json::array({"cpp"}), done);
      })) {
    return fail("5 call_hook", "no answer");
  }
  if (!hook.ok) return fail("5 call_hook", hook.error);
  ok("5 call_hook example_hook.hello: " + gamend::dump(hook.data));
  if (!call<gamend::HookResult>(client, hook, [&](auto done) {
        realtime.call_hook("example_hook", "no_such_function", gamend::json::array(), done);
      })) {
    return fail("5 failing hook", "no answer");
  }
  if (hook.ok) return fail("5 failing hook", "a function that does not exist answered ok");
  ok("5 a missing hook answers its error: " + hook.error);

  // 6. KV: subscribe, write through the API, hear it.
  const char* admin_email = std::getenv("GAMEND_ADMIN_EMAIL");
  const char* admin_password = std::getenv("GAMEND_ADMIN_PASSWORD");
  if (admin_email == nullptr || admin_password == nullptr) {
    std::printf("skip 6 kv: set GAMEND_ADMIN_EMAIL and GAMEND_ADMIN_PASSWORD to write as admin\n");
  } else {
    auto key = "cpp_conformance_" + client.run_id();
    gamend::KvResult subscribed;
    if (!call<gamend::KvResult>(client, subscribed,
                                [&](auto done) { client.kv().subscribe({key}, done); })) {
      return fail("6 kv subscribe", "no answer");
    }
    if (!subscribed.ok) return fail("6 kv subscribe", subscribed.error);

    gamend::Config admin_config;
    admin_config.base_url = url;
    admin_config.http = gamend::make_curl_transport();
    gamend::Client admin(std::move(admin_config));
    gamend::AuthResult admin_login;
    if (!call<gamend::AuthResult>(admin, admin_login, [&](auto done) {
          admin.auth().login_email(admin_email, admin_password, done);
        })) {
      return fail("6 admin login", "no answer");
    }
    if (!admin_login.ok) return fail("6 admin login", admin_login.error);
    gamend::Response written;
    if (!call<gamend::Response>(admin, written, [&](auto done) {
          admin.api().admin_kv_admin_upsert_kv({{"key", key}, {"data", {{"score", 42}}}}, done);
        })) {
      return fail("6 kv write", "no answer");
    }
    if (!written.ok()) return fail("6 kv write", written.error);
    if (!await(client, [&] {
          auto row = client.kv().row({key});
          return row && row->exists && gamend::number(row->data, "score") == 42;
        })) {
      return fail("6 kv_updated", "the write never arrived");
    }
    ok("6 kv subscribe heard the admin write to " + key);
    admin.api().admin_kv_admin_delete_kv({{"key", key}}, nullptr);
    await(admin, [] { return false; }, 1);
  }

  // 7. Pull the plug: it reconnects, rejoins, and events flow again.
  std::vector<gamend::RealtimeState> states;
  realtime.on_state([&](gamend::RealtimeState s) { states.push_back(s); });
  socket->drop();
  // The drop is news on the next poll, like everything else.
  if (!await(client, [&] { return realtime.state() == gamend::RealtimeState::Reconnecting; })) {
    return fail("7 reconnect", "the drop was not noticed");
  }
  if (!await(client, [&] {
        return realtime.state() == gamend::RealtimeState::Connected &&
               realtime.joined(user_topic) && realtime.joined(lobby_topic);
      })) {
    return fail("7 reconnect", "did not rejoin " + user_topic + " and " + lobby_topic);
  }
  if (states.empty() || states.front() != gamend::RealtimeState::Reconnecting) {
    return fail("7 reconnect", "no Reconnecting state was announced");
  }
  events.clear();
  if (!call<gamend::Response>(client, renamed, [&](auto done) {
        client.api().lobbies_update_lobby({{"title", "cpp conformance (after the drop)"}}, done);
      })) {
    return fail("7 update lobby", "no answer");
  }
  if (!await(client, [&] { return saw(gamend::events::LOBBY_UPDATED, lobby_topic); })) {
    return fail("7 events resume", "no updated event after the reconnect");
  }
  ok("7 dropped, reconnected, rejoined both topics, events resumed");

#if defined(GAMEND_WITH_WEBRTC)
  // 9. WebRTC: the server is the other peer; a hook answers over `events`.
  std::string webrtc_error = "unset";
  client.webrtc().connect([&](const std::string& e) { webrtc_error = e; });
  if (!await(client, [&] { return webrtc_error != "unset"; }, 20)) {
    return fail("9 webrtc", "no answer");
  }
  if (!webrtc_error.empty()) return fail("9 webrtc", webrtc_error);
  if (!await(client, [&] {
        return client.webrtc().channel_open("events") && client.webrtc().channel_open("state");
      })) {
    return fail("9 webrtc", "the events and state channels did not both open");
  }
  gamend::HookResult over_rtc;
  if (!call<gamend::HookResult>(client, over_rtc, [&](auto done) {
        client.webrtc().call_hook("example_hook", "hello", gamend::json::array({"rtc"}), done);
      })) {
    return fail("9 webrtc call_hook", "no answer");
  }
  if (!over_rtc.ok) return fail("9 webrtc call_hook", over_rtc.error);
  ok("9 webrtc connected, both channels open, example_hook.hello over events: " +
     gamend::dump(over_rtc.data));
  client.webrtc().close();
#endif

  // 8. Leave the lobby and disconnect.
  gamend::Response left;
  if (!call<gamend::Response>(client, left,
                              [&](auto done) { client.api().lobbies_leave_lobby(done); })) {
    return fail("8 leave lobby", "no answer");
  }
  if (!left.ok()) return fail("8 leave lobby", left.error);
  gamend::Reply unjoined;
  if (!call<gamend::Reply>(client, unjoined,
                           [&](auto done) { realtime.leave(lobby_topic, done); })) {
    return fail("8 leave topic", "no answer");
  }
  realtime.disconnect();
  if (realtime.state() != gamend::RealtimeState::Disconnected) {
    return fail("8 disconnect", "still connected");
  }
  ok("8 left the lobby and disconnected");
  return 0;
#endif
}
