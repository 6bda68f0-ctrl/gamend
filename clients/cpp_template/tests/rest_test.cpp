#include <doctest/doctest.h>

#include "harness.hpp"

using gamend::Body;
using gamend::json;
using harness::FakeHttp;
using harness::Harness;
using harness::Seen;

TEST_CASE("a callback runs in poll, never inside the call or the reply") {
  Harness h;
  Seen seen;
  h.client->api().lobbies_lobby_stats(seen.callback());
  REQUIRE(h.server->pending() == 1);
  h.server->reply(200, R"({"data": {"total": 3}})");
  CHECK(seen.calls == 0);
  h.client->poll();
  CHECK(seen.calls == 1);
  CHECK(seen.last.ok());
  CHECK(seen.last.data()["total"] == 3);
}

TEST_CASE("replies run in the order they arrived") {
  Harness h;
  std::vector<std::string> order;
  h.client->rest().send("GET", "/api/v1/a", Body::none(),
                        [&](const gamend::Response&) { order.push_back("a"); });
  h.client->rest().send("GET", "/api/v1/b", Body::none(),
                        [&](const gamend::Response&) { order.push_back("b"); });
  h.server->reply(200, "{}");
  h.server->reply(200, "{}");
  h.client->poll();
  CHECK(order == std::vector<std::string>{"a", "b"});
}

TEST_CASE("every call names the run; only a signed-in one carries a token") {
  Harness h;
  h.client->api().lobbies_lobby_stats(nullptr);
  auto anonymous = h.server->next();
  CHECK(anonymous.url == "http://game.test/api/v1/lobbies/stats");
  CHECK(anonymous.method == "GET");
  CHECK(FakeHttp::header(anonymous, "x-gamend-session") == "run-1");
  CHECK(FakeHttp::header(anonymous, "accept") == "application/json");
  CHECK(FakeHttp::header(anonymous, "user-agent").rfind("gamend-cpp/", 0) == 0);
  CHECK(FakeHttp::header(anonymous, "authorization").empty());
  CHECK(anonymous.body.empty());
  CHECK(FakeHttp::header(anonymous, "content-type").empty());
  h.server->reply(200, "{}");

  h.signed_in();
  h.client->api().users_get_current_user(nullptr);
  CHECK(FakeHttp::header(h.server->next(), "authorization") == "Bearer a1");
}

TEST_CASE("a body goes as JSON; a POST without one sends an empty object") {
  Harness h;
  h.client->api().lobbies_quick_join({{"title", "duel"}, {"max_users", 2}}, nullptr);
  auto join = h.server->next();
  h.server->reply(200, "{}");
  CHECK(join.method == "POST");
  CHECK(FakeHttp::header(join, "content-type") == "application/json");
  CHECK(json::parse(join.body) == json{{"title", "duel"}, {"max_users", 2}});

  h.client->api().lobbies_leave_lobby(nullptr);
  auto leave = h.server->next();
  CHECK(leave.body == "{}");
  CHECK(FakeHttp::header(leave, "content-type") == "application/json");
}

TEST_CASE("an error reply carries its code; one with no code, its status") {
  Harness h;
  Seen seen;
  h.client->api().lobbies_get_lobby("x", seen.callback());
  h.server->reply(404, R"({"error": "not_found", "message": "No such lobby"})");
  h.client->poll();
  CHECK_FALSE(seen.last.ok());
  CHECK(seen.last.status == 404);
  CHECK(seen.last.error == "not_found");
  CHECK(seen.last.code() == "not_found");
  CHECK(seen.last.message() == "No such lobby");

  h.client->api().lobbies_get_lobby("x", seen.callback());
  h.server->reply(502, "<html>bad gateway</html>");
  h.client->poll();
  CHECK(seen.last.error == "http_502");
  CHECK(seen.last.body.is_null());
  CHECK(seen.last.text == "<html>bad gateway</html>");
}

TEST_CASE("no reply at all is status 0 with the transport's reason") {
  Harness h;
  Seen seen;
  h.client->api().lobbies_lobby_stats(seen.callback());
  h.server->fail("connection refused");
  h.client->poll();
  CHECK(seen.last.status == 0);
  CHECK(seen.last.error == "connection refused");
  CHECK_FALSE(seen.last.ok());
}

TEST_CASE("a 401 refreshes once and sends the call again with the new token") {
  Harness h;
  h.signed_in();
  Seen seen;
  h.client->api().users_get_current_user(seen.callback());
  h.server->reply(401, R"({"error": "unauthorized"})");
  h.client->poll();

  REQUIRE(h.server->pending() == 1);
  auto refresh = h.server->next();
  CHECK(refresh.url == "http://game.test/api/v1/refresh");
  CHECK(json::parse(refresh.body) == json{{"refresh_token", "r1"}});
  CHECK(FakeHttp::header(refresh, "authorization").empty());
  h.server->reply(200, harness::session_reply(2));
  h.client->poll();

  REQUIRE(h.server->pending() == 1);
  auto retry = h.server->next();
  CHECK(retry.url == "http://game.test/api/v1/me");
  CHECK(FakeHttp::header(retry, "authorization") == "Bearer a2");
  h.server->reply(200, R"({"data": {"id": "u1"}})");
  h.client->poll();

  CHECK(seen.calls == 1);
  CHECK(seen.last.ok());
  CHECK(h.client->auth().session()->access_token == "a2");
}

TEST_CASE("two calls that meet a 401 share one refresh") {
  Harness h;
  h.signed_in();
  Seen first;
  Seen second;
  h.client->api().users_get_current_user(first.callback());
  h.client->api().lobbies_lobby_stats(second.callback());
  h.server->reply(401, "{}");
  h.server->reply(401, "{}");
  h.client->poll();

  REQUIRE(h.server->pending() == 1);
  h.server->reply(200, harness::session_reply(2));
  h.client->poll();
  REQUIRE(h.server->pending() == 2);
  h.server->reply(200, "{}");
  h.server->reply(200, "{}");
  h.client->poll();
  CHECK(first.calls == 1);
  CHECK(second.calls == 1);
  CHECK(first.last.ok());
  CHECK(second.last.ok());

  int refreshes = 0;
  for (const auto& request : h.server->sent()) {
    if (request.url == "http://game.test/api/v1/refresh") ++refreshes;
  }
  CHECK(refreshes == 1);
}

TEST_CASE("a refused refresh signs out and hands the call its 401") {
  Harness h;
  h.signed_in();
  Seen seen;
  h.client->api().users_get_current_user(seen.callback());
  h.server->reply(401, R"({"error": "unauthorized"})");
  h.client->poll();
  h.server->reply(401, R"({"error": "invalid_token"})");
  h.client->poll();

  CHECK(seen.calls == 1);
  CHECK(seen.last.status == 401);
  CHECK(seen.last.error == "unauthorized");
  CHECK_FALSE(h.client->auth().signed_in());
  CHECK(h.server->pending() == 0);
  h.client->poll();
  REQUIRE(h.changes.size() == 1);
  CHECK_FALSE(h.changes.back().has_value());
}

TEST_CASE("a 401 with no session to refresh goes straight to the caller") {
  Harness h;
  Seen seen;
  h.client->api().users_get_current_user(seen.callback());
  h.server->reply(401, R"({"error": "unauthorized"})");
  h.client->poll();
  CHECK(seen.calls == 1);
  CHECK(seen.last.error == "unauthorized");
  CHECK(h.server->pending() == 0);
}

TEST_CASE("Dispatch::Immediate runs the callback as the reply lands") {
  Harness h(gamend::Dispatch::Immediate);
  Seen seen;
  h.client->api().lobbies_lobby_stats(seen.callback());
  h.server->reply(200, "{}");
  CHECK(seen.calls == 1);
}

TEST_CASE("a client with no transport answers every call with an error") {
  gamend::Config config;
  config.base_url = "http://game.test";
  gamend::Client client(std::move(config));
  Seen seen;
  client.api().lobbies_lobby_stats(seen.callback());
  client.poll();
  CHECK(seen.calls == 1);
  CHECK(seen.last.error == "no HTTP transport configured");
}

namespace {

// A transport the test keeps after the client that owned it is gone.
class Shared final : public gamend::HttpTransport {
 public:
  explicit Shared(std::shared_ptr<FakeHttp> server) : server_(std::move(server)) {}
  void send(gamend::HttpRequest request, std::function<void(gamend::HttpResponse)> done) override {
    server_->send(std::move(request), std::move(done));
  }

 private:
  std::shared_ptr<FakeHttp> server_;
};

}  // namespace

TEST_CASE("a reply that lands after the client is gone is dropped") {
  auto server = std::make_shared<FakeHttp>();
  Seen seen;
  {
    gamend::Config config;
    config.base_url = "http://game.test";
    config.http = std::make_unique<Shared>(server);
    gamend::Client client(std::move(config));
    client.api().lobbies_lobby_stats(seen.callback());
    REQUIRE(server->pending() == 1);
  }
  server->reply(200, "{}");
  CHECK(seen.calls == 0);
}
