// A client over a fake server and a fake clock, for every test.
#pragma once

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "gamend/gamend.hpp"
#include "gamend/testing/fake_transport.hpp"

namespace harness {

using gamend::testing::FakeHttp;
using gamend::testing::FakePeer;
using gamend::testing::FakeWebSocket;

/// A sign-in reply with the tokens `a<n>` / `r<n>`.
inline std::string session_reply(int n = 1, int expires_in = 900) {
  gamend::json data = {
      {"access_token", "a" + std::to_string(n)},
      {"refresh_token", "r" + std::to_string(n)},
      {"user_id", "u1"},
      {"username", "ann"},
      {"display_name", "Ann"},
      {"expires_in", expires_in},
  };
  return gamend::dump(gamend::json{{"data", data}});
}

struct Harness {
  explicit Harness(gamend::Dispatch dispatch = gamend::Dispatch::Poll,
                   bool with_open_url = true,
                   gamend::RealtimeFormat webrtc_format = gamend::RealtimeFormat::Json) {
    auto http = std::make_unique<FakeHttp>();
    server = http.get();
    auto websocket = std::make_unique<FakeWebSocket>();
    socket = websocket.get();
    gamend::Config config;
    config.base_url = "http://game.test/";
    config.http = std::move(http);
    config.websocket = std::move(websocket);
    auto fake_peer = std::make_unique<FakePeer>();
    peer = fake_peer.get();
    config.webrtc = std::move(fake_peer);
    config.webrtc_format = webrtc_format;
    config.dispatch = dispatch;
    config.run_id = "run-1";
    config.clock = clock.steady();
    config.unix_clock = clock.wall();
    config.sign_in_timeout = std::chrono::seconds(5);
    if (with_open_url) config.open_url = [this](const std::string& url) { opened.push_back(url); };
    client = std::make_unique<gamend::Client>(std::move(config));
    client->auth().on_session_changed(
        [this](const std::optional<gamend::Session>& session) { changes.push_back(session); });
  }

  /// Signed in as `a1`/`r1` without a round trip.
  void signed_in(std::int64_t lasts = 900) {
    gamend::Session session;
    session.access_token = "a1";
    session.refresh_token = "r1";
    session.user_id = "u1";
    session.username = "ann";
    session.expires_in = 900;
    session.expires_at = clock.wall()() + lasts;
    client->auth().restore(session);
  }

  void advance(std::chrono::milliseconds by) {
    clock.advance(by);
    client->poll();
  }

  gamend::testing::FakeClock clock;
  std::vector<std::string> opened;
  std::vector<std::optional<gamend::Session>> changes;
  FakeHttp* server = nullptr;
  FakeWebSocket* socket = nullptr;
  FakePeer* peer = nullptr;
  std::unique_ptr<gamend::Client> client;
};

/// What a callback saw, and how often.
struct Seen {
  int calls = 0;
  gamend::Response last;
  gamend::Callback callback() {
    return [this](const gamend::Response& r) {
      ++calls;
      last = r;
    };
  }
};

struct SeenAuth {
  int calls = 0;
  gamend::AuthResult last;
  gamend::AuthCallback callback() {
    return [this](const gamend::AuthResult& r) {
      ++calls;
      last = r;
    };
  }
};

}  // namespace harness
