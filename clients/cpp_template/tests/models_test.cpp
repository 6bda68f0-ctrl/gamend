#include <doctest/doctest.h>

#include "harness.hpp"

using gamend::json;
using gamend::models::Lobby;
using harness::Harness;
using harness::Seen;

TEST_CASE("a reply reads as its model") {
  Harness h;
  Seen seen;
  h.client->api().lobbies_get_lobby("l1", seen.callback());
  h.server->reply(200, R"({"data": {
      "id": "l1", "title": "Duel", "max_users": 2, "hostless": false, "state": "playing",
      "state_changed_at": null, "metadata": {"map": "dunes"},
      "members": [{"id": "u1", "username": "ann"}, {"id": "u2", "username": "bea"}]}})");
  h.client->poll();
  auto lobby = seen.last.as<Lobby>();
  REQUIRE(lobby);
  CHECK(lobby->id == "l1");
  CHECK(lobby->max_users == 2);
  CHECK(lobby->state == "playing");
  CHECK_FALSE(lobby->state_changed_at.has_value());
  CHECK(lobby->metadata["map"] == "dunes");
  REQUIRE(lobby->members.size() == 2);
  CHECK(lobby->members[1].username == "bea");
  // Left out: the default.
  CHECK(lobby->host_id.empty());
  CHECK(lobby->spectator_count == 0);
}

TEST_CASE("a page reads its items and meta; a list of strings reads too") {
  Harness h;
  Seen seen;
  h.client->api().lobbies_list_lobbies(seen.callback());
  h.server->reply(200, R"({"data": [{"id": "a"}, {"id": "b"}],
      "meta": {"page": 1, "page_size": 25, "total_count": 2, "total_pages": 1,
               "has_more": false, "count": 2}})");
  h.client->poll();
  auto page = seen.last.page<Lobby>();
  REQUIRE(page);
  CHECK(page->data.size() == 2);
  CHECK(page->meta.total_count == 2);
  CHECK_FALSE(page->meta.has_more);

  h.client->api().authenticate_list_auth_providers(seen.callback());
  h.server->reply(200, R"({"data": ["google", "steam"]})");
  h.client->poll();
  auto providers = seen.last.as<std::vector<std::string>>();
  REQUIRE(providers);
  CHECK(*providers == std::vector<std::string>{"google", "steam"});
}

TEST_CASE("reads never abort: wrong kinds keep defaults, a non-object is no model") {
  Lobby lobby;
  CHECK(gamend::Codec<Lobby>::read(
      json{{"id", 7}, {"max_users", "two"}, {"members", "nobody"}, {"title", "ok"}}, lobby));
  CHECK(lobby.id.empty());
  CHECK(lobby.max_users == 0);
  CHECK(lobby.members.empty());
  CHECK(lobby.title == "ok");
  CHECK_FALSE(gamend::Codec<Lobby>::read(json::array(), lobby));

  gamend::Response nothing;
  CHECK_FALSE(nothing.as<Lobby>());
}

TEST_CASE("a model writes back to the JSON it read") {
  auto source = json{{"id", "l1"}, {"title", "Duel"}, {"max_users", 2},
                     {"state_changed_at", "2026-09-19T10:00:00Z"}};
  Lobby lobby;
  REQUIRE(gamend::Codec<Lobby>::read(source, lobby));
  auto written = gamend::Codec<Lobby>::write(lobby);
  CHECK(written["id"] == "l1");
  CHECK(written["max_users"] == 2);
  CHECK(written["state_changed_at"] == "2026-09-19T10:00:00Z");
  CHECK(written["host_id"] == "");
  Lobby again;
  REQUIRE(gamend::Codec<Lobby>::read(written, again));
  CHECK(gamend::Codec<Lobby>::write(again) == written);
}

TEST_CASE("a map-shaped answer reads as a map") {
  gamend::Response r;
  r.status = 200;
  r.body = json{{"data", {{"coins", 120}, {"gems", 3}}}};
  auto wallet = r.as<gamend::models::WalletBalances>();
  REQUIRE(wallet);
  CHECK(wallet->at("coins") == 120);
  CHECK(wallet->at("gems") == 3);

  gamend::models::LobbyStats stats;
  REQUIRE(gamend::Codec<gamend::models::LobbyStats>::read(
      json{{"by_state", {{"playing", 2}, {"created", 1}}}, {"lobbies_total", 3}}, stats));
  CHECK(stats.by_state["playing"] == 2);
  CHECK(stats.lobbies_total == 3);
}
