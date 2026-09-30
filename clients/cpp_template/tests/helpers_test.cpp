#include <doctest/doctest.h>

#include "harness.hpp"

using gamend::json;
using gamend::KvKey;
using harness::Harness;
using std::chrono::milliseconds;

namespace {

std::string reply(const std::string& join_ref, const std::string& ref, const std::string& topic,
                  const std::string& status, const json& response = json::object()) {
  return gamend::dump(json::array(
      {join_ref, ref, topic, "phx_reply", {{"status", status}, {"response", response}}}));
}

std::string message(const std::string& topic, const std::string& event, const json& payload) {
  return gamend::dump(json::array({nullptr, nullptr, topic, event, payload}));
}

// Signed in as u1; `open()` connects and joins the user channel, answering
// its join and handing back what was sent after it.
struct Live : Harness {
  Live() {
    signed_in();
    client->kv().on_change([this](const KvKey& key, const gamend::KvRow& row) {
      changes.emplace_back(key, row);
    });
  }
  std::vector<json> open() {
    client->realtime().connect();
    socket->accept();
    client->poll();
    auto join = json::parse(socket->take_frames().at(0));
    socket->receive(reply(join[0], join[1], "user:u1", "ok"));
    client->poll();
    std::vector<json> sent;
    for (auto& frame : socket->take_frames()) sent.push_back(json::parse(frame));
    return sent;
  }
  std::vector<std::pair<KvKey, gamend::KvRow>> changes;
};

}  // namespace

TEST_CASE("a subscription is sent once the user channel joins, and its reply fills the cache") {
  Live h;
  gamend::KvResult got;
  h.client->kv().subscribe({"progress", "u1"}, [&](const gamend::KvResult& r) { got = r; });
  auto sent = h.open();
  REQUIRE(sent.size() == 1);
  CHECK(sent[0][3] == "kv:subscribe");
  CHECK(sent[0][4] == json{{"key", "progress"}, {"user_id", "u1"}});

  h.socket->receive(reply(sent[0][0], sent[0][1], "user:u1", "ok",
                          {{"subscribed", true}, {"key", "progress"}, {"data", {{"level", 3}}},
                           {"metadata", json::object()}}));
  h.client->poll();
  CHECK(got.ok);
  CHECK(got.row.exists);
  CHECK(got.row.data["level"] == 3);
  CHECK(h.client->kv().subscribed({"progress", "u1"}));
  auto row = h.client->kv().row({"progress", "u1"});
  REQUIRE(row);
  CHECK(row->data["level"] == 3);
  REQUIRE(h.changes.size() == 1);
  CHECK(h.changes[0].first.key == "progress");
}

TEST_CASE("a subscribe reply for a missing row caches that it is missing") {
  Live h;
  auto sent = h.open();
  h.client->kv().subscribe({"loadout"});
  auto frames = h.socket->take_frames();
  REQUIRE(frames.size() == 1);
  auto frame = json::parse(frames[0]);
  CHECK(frame[4] == json{{"key", "loadout"}});
  h.socket->receive(reply(frame[0], frame[1], "user:u1", "ok",
                          {{"subscribed", true}, {"key", "loadout"}, {"missing", true}}));
  h.client->poll();
  auto row = h.client->kv().row({"loadout"});
  REQUIRE(row);
  CHECK_FALSE(row->exists);
}

TEST_CASE("pushes keep a row current, deletes included") {
  Live h;
  h.open();
  h.socket->receive(message("user:u1", "kv_updated",
                            {{"key", "progress"}, {"user_id", "u1"}, {"lobby_id", ""},
                             {"data", {{"level", 4}}}, {"metadata", json::object()}}));
  h.client->poll();
  CHECK(h.client->kv().row({"progress", "u1"})->data["level"] == 4);

  h.socket->receive(message("user:u1", "kv_deleted",
                            {{"key", "progress"}, {"user_id", "u1"}, {"lobby_id", ""}}));
  h.client->poll();
  CHECK_FALSE(h.client->kv().row({"progress", "u1"})->exists);
  CHECK(h.changes.size() == 2);
}

TEST_CASE("every rejoin sends the subscriptions again; a refused one is dropped") {
  Live h;
  gamend::KvResult refused;
  h.client->kv().subscribe({"progress", "u1"});
  h.client->kv().subscribe({"secret"}, [&](const gamend::KvResult& r) { refused = r; });
  auto sent = h.open();
  REQUIRE(sent.size() == 2);
  h.socket->receive(reply(sent[0][0], sent[0][1], "user:u1", "ok", {{"missing", true}}));
  h.socket->receive(reply(sent[1][0], sent[1][1], "user:u1", "error", {{"error", "forbidden"}}));
  h.client->poll();
  CHECK_FALSE(refused.ok);
  CHECK(refused.error == "forbidden");

  h.socket->drop();
  h.client->poll();
  h.advance(milliseconds(100));
  h.socket->accept();
  h.client->poll();
  auto join = json::parse(h.socket->take_frames().at(0));
  h.socket->receive(reply(join[0], join[1], "user:u1", "ok"));
  h.client->poll();
  auto again = h.socket->take_frames();
  REQUIRE(again.size() == 1);
  CHECK(json::parse(again[0])[4]["key"] == "progress");
}

TEST_CASE("unsubscribing tells the server and stops resubscribing") {
  Live h;
  h.client->kv().subscribe({"progress", "u1"});
  auto sent = h.open();
  h.socket->receive(reply(sent[0][0], sent[0][1], "user:u1", "ok", {{"missing", true}}));
  h.client->poll();
  h.client->kv().unsubscribe({"progress", "u1"});
  auto frames = h.socket->take_frames();
  REQUIRE(frames.size() == 1);
  CHECK(json::parse(frames[0])[3] == "kv:unsubscribe");
  CHECK_FALSE(h.client->kv().subscribed({"progress", "u1"}));
}

TEST_CASE("fetch reads the cache first, the API otherwise; a 404 caches the absence") {
  Live h;
  gamend::KvResult got;
  h.client->kv().fetch({"progress", "u1"}, false, [&](const gamend::KvResult& r) { got = r; });
  REQUIRE(h.server->pending() == 1);
  CHECK(h.server->next().url == "http://game.test/api/v1/kv/progress?user_id=u1");
  h.server->reply(200, R"({"data": {"key": "progress", "user_id": "u1", "lobby_id": "",
      "data": {"level": 7}, "metadata": {}}})");
  h.client->poll();
  CHECK(got.ok);
  CHECK(got.row.data["level"] == 7);

  h.client->kv().fetch({"progress", "u1"}, false, [&](const gamend::KvResult& r) { got = r; });
  CHECK(h.server->pending() == 0);
  h.client->poll();
  CHECK(got.row.data["level"] == 7);

  h.client->kv().fetch({"nothing"}, false, [&](const gamend::KvResult& r) { got = r; });
  h.server->reply(404, R"({"error": "not_found"})");
  h.client->poll();
  CHECK(got.ok);
  CHECK_FALSE(got.row.exists);
  CHECK(h.client->kv().row({"nothing"}));
}

TEST_CASE("signing out forgets rows and subscriptions") {
  Live h;
  h.open();
  h.socket->receive(message("user:u1", "kv_updated",
                            {{"key", "progress"}, {"user_id", "u1"}, {"data", {{"a", 1}}}}));
  h.client->poll();
  REQUIRE(h.client->kv().row({"progress", "u1"}));
  h.client->auth().forget();
  h.client->poll();
  CHECK_FALSE(h.client->kv().row({"progress", "u1"}));
}

TEST_CASE("presence merges profiles, keeps metadata sections, and tracks who is online") {
  Live h;
  h.open();
  std::vector<std::string> changed;
  h.client->presence().on_user_changed([&](const std::string& id) { changed.push_back(id); });

  h.socket->receive(message("lobby:l1", "user_joined",
                            {{"user_id", "u2"}, {"display_name", "Bea"},
                             {"metadata", {{"player", {{"hat", "red"}, {"boots", "blue"}}}}}}));
  h.socket->receive(message("lobby:l1", "user_updated",
                            {{"user_id", "u2"}, {"metadata", {{"player", {{"hat", "green"}}}}}}));
  h.client->poll();
  auto bea = h.client->presence().user("u2");
  CHECK(bea["display_name"] == "Bea");
  CHECK(bea["metadata"]["player"]["hat"] == "green");
  CHECK(bea["metadata"]["player"]["boots"] == "blue");

  h.socket->receive(message("lobby:l1", "user_online", {{"user_id", "u2"}}));
  h.client->poll();
  CHECK(h.client->presence().online("u2"));
  h.socket->receive(message("lobby:l1", "user_offline", {{"user_id", "u2"}}));
  h.client->poll();
  CHECK_FALSE(h.client->presence().online("u2"));
  CHECK(h.client->presence().last_seen("u2") == h.clock.wall()());
  CHECK(h.client->presence().online("u1"));
  CHECK(changed.size() == 4);
}

TEST_CASE("the player's own push replaces their metadata and keeps only their lobby") {
  Live h;
  h.open();
  h.socket->receive(message("lobby:l1", "updated", {{"id", "l1"}, {"title", "One"}}));
  h.socket->receive(message("lobby:l2", "updated", {{"id", "l2"}, {"title", "Two"}}));
  h.client->presence().cache_user("u1", {{"metadata", {{"old", 1}, {"keep", 1}}}});
  h.socket->receive(message("user:u1", "updated",
                            {{"id", "u1"}, {"lobby_id", "l2"}, {"metadata", {{"keep", 2}}}}));
  h.client->poll();
  auto me = h.client->presence().user("u1");
  CHECK(me["metadata"] == json{{"keep", 2}});
  CHECK(h.client->presence().lobby("l1").empty());
  CHECK(h.client->presence().lobby("l2")["title"] == "Two");
}

TEST_CASE("merge_metadata merges one section deep") {
  auto merged = gamend::Presence::merge_metadata(
      {{"player", {{"hat", "red"}, {"boots", "blue"}}}, {"level", 1}},
      {{"player", {{"hat", "green"}}}, {"level", 2}, {"new", true}});
  CHECK(merged == json{{"player", {{"hat", "green"}, {"boots", "blue"}}}, {"level", 2},
                       {"new", true}});
}
