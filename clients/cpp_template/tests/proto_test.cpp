#include <doctest/doctest.h>

#include "harness.hpp"
#include "proto.hpp"

using gamend::json;
namespace proto = gamend::detail::proto;

namespace {

const proto::Message& message(const char* name) {
  const auto* found = proto::find(name);
  REQUIRE(found != nullptr);
  return *found;
}

std::string bytes(std::initializer_list<int> values) {
  std::string out;
  for (int v : values) out += static_cast<char>(v);
  return out;
}

}  // namespace

TEST_CASE("the wire format decodes: strings, varints, zigzag, nested and repeated") {
  // WalletChange{currency: "coins", balance: 150, delta: -5}, by hand.
  auto wire = bytes({0x0A, 5, 'c', 'o', 'i', 'n', 's', 0x10, 0x96, 0x01, 0x18, 0x09});
  auto decoded = proto::decode(message("WalletChange"), wire, true);
  REQUIRE(decoded);
  CHECK(*decoded == json{{"currency", "coins"}, {"balance", 150}, {"delta", -5}});

  CHECK_FALSE(proto::decode(message("WalletChange"), bytes({0x0A, 9, 'c'}), true));
}

TEST_CASE("encode and decode agree, maps and nested messages included") {
  json lobby = {{"id", "l1"},
                {"title", "Duel"},
                {"max_users", 4},
                {"hostless", false},
                {"members", {{{"id", "u1"}, {"username", "ann"}}, {{"id", "u2"}}}},
                {"metadata_json", R"({"map":"dunes"})"}};
  auto wire = proto::encode(message("Lobby"), lobby);
  auto back = proto::decode(message("Lobby"), wire, false);
  REQUIRE(back);
  CHECK((*back)["id"] == "l1");
  CHECK((*back)["max_users"] == 4);
  CHECK((*back)["hostless"] == false);  // optional: present because it was sent
  CHECK((*back)["members"].size() == 2);
  CHECK((*back)["members"][0]["username"] == "ann");
  CHECK((*back)["metadata"] == json{{"map", "dunes"}});
  CHECK_FALSE(back->contains("metadata_json"));
  CHECK_FALSE(back->contains("host_id"));

  json found = {{"lobby_id", "l9"}, {"match_params", {{"mode", "duel"}, {"region", "eu"}}}};
  auto params = proto::decode(message("MatchmakingFound"),
                              proto::encode(message("MatchmakingFound"), found), true);
  REQUIRE(params);
  CHECK(*params == found);
}

TEST_CASE("defaults fill what proto3 leaves out, and never an optional field") {
  auto chat = proto::decode(message("ChatMessage"), "", true);
  REQUIRE(chat);
  CHECK((*chat)["id"] == "");
  CHECK((*chat)["inserted_at_ms"] == 0);
  CHECK((*chat)["metadata"] == json::object());
  CHECK_FALSE(chat->contains("updated_at_ms"));
  CHECK_FALSE(chat->contains("sender_email"));

  auto user = proto::decode(message("User"), "", false);
  REQUIRE(user);
  CHECK(user->empty());
}

TEST_CASE("binary events decode by topic and event, as the server maps them") {
  json kv = {{"key", "progress"}, {"user_id", "u1"}, {"data_json", R"({"level":3})"},
             {"metadata_json", "{}"}};
  auto decoded = gamend::detail::decode_binary_event("user:u1", "kv_updated",
                                                     proto::encode(message("KvEntry"), kv));
  REQUIRE(decoded);
  CHECK(*decoded == json{{"key", "progress"}, {"user_id", "u1"}, {"data", {{"level", 3}}},
                         {"metadata", json::object()}});

  // `updated` is a User on user:, a Lobby on lobby:.
  auto lobby = gamend::detail::decode_binary_event(
      "lobby:l1", "updated", proto::encode(message("Lobby"), {{"id", "l1"}, {"title", "T"}}));
  REQUIRE(lobby);
  CHECK((*lobby)["title"] == "T");
  CHECK_FALSE(gamend::detail::decode_binary_event("lobby:l1", "unmapped", ""));

  auto pb = gamend::detail::decode_binary_event(
      "user:u1", "kv_updated",
      proto::encode(message("KvEntry"), {{"key", "k"}, {"data_pb", std::string("\x01\x02", 2)}}));
  REQUIRE(pb);
  CHECK((*pb)["data_pb"] == "AQI=");
}

TEST_CASE("a binary frame on a protobuf connection reaches listeners decoded") {
  harness::Harness h;
  h.signed_in();
  std::vector<gamend::Event> events;
  h.client->realtime().on_event([&](const gamend::Event& e) { events.push_back(e); });
  h.client->realtime().connect();
  h.socket->accept();
  h.client->poll();
  auto body = proto::encode(message("WalletChange"),
                            {{"currency", "coins"}, {"balance", 10}, {"delta", 2}});
  std::string frame;
  frame += static_cast<char>(0);  // push
  frame += static_cast<char>(1);
  frame += static_cast<char>(7);
  frame += static_cast<char>(14);
  frame += "1";
  frame += "user:u1";
  frame += "wallet_updated";
  frame += body;
  h.socket->receive_binary(frame);
  h.client->poll();
  REQUIRE(events.size() == 1);
  CHECK(events[0].kind == gamend::events::WALLET_UPDATED);
  CHECK(events[0].payload == json{{"currency", "coins"}, {"balance", 10}, {"delta", 2}});
  CHECK(events[0].bytes.empty());
}

TEST_CASE("base64") {
  CHECK(proto::base64("") == "");
  CHECK(proto::base64("f") == "Zg==");
  CHECK(proto::base64("fo") == "Zm8=");
  CHECK(proto::base64("foo") == "Zm9v");
}

namespace {

// A connected client in protobuf mode that hands back what listeners saw.
struct Pb : harness::Harness {
  Pb() {
    signed_in();
    client->realtime().on_event([this](const gamend::Event& e) { events.push_back(e); });
    client->realtime().connect();
    socket->accept();
    client->poll();
  }
  json receive(const std::string& topic, const std::string& event, const char* message_name,
               const json& value) {
    auto body = proto::encode(message(message_name), value);
    std::string frame;
    frame += static_cast<char>(2);  // broadcast
    frame += static_cast<char>(topic.size());
    frame += static_cast<char>(event.size());
    frame += topic;
    frame += event;
    frame += body;
    socket->receive_binary(frame);
    client->poll();
    return events.back().payload;
  }
  std::vector<gamend::Event> events;
};

}  // namespace

TEST_CASE("a game's KV bytes read through its decoder: exact key first, then longest prefix") {
  Pb h;
  h.client->realtime().register_kv_decoder("match:*", [](std::string_view b) {
    return std::optional<json>(json{{"by", "match"}, {"size", b.size()}});
  });
  h.client->realtime().register_kv_decoder("match:final:*", [](std::string_view) {
    return std::optional<json>(json{{"by", "final"}});
  });
  h.client->realtime().register_kv_decoder("match:final:7", [](std::string_view) {
    return std::optional<json>(json{{"by", "exact"}});
  });
  auto bytes = std::string("\x08\x2A", 2);
  auto kv = [&](const char* key) {
    return h.receive("user:u1", "kv_updated", "KvEntry", {{"key", key}, {"data_pb", bytes}});
  };
  CHECK(kv("match:1")["data"] == json{{"by", "match"}, {"size", 2}});
  CHECK(kv("match:final:1")["data"]["by"] == "final");
  CHECK(kv("match:final:7")["data"]["by"] == "exact");
  auto unread = kv("loadout");
  CHECK(unread["data_pb"] == "CCo=");
  CHECK_FALSE(unread.contains("data"));
}

TEST_CASE("a game's metadata bytes read through its entity's decoder") {
  Pb h;
  h.client->realtime().register_metadata_decoder("lobby", [](std::string_view b) {
    return std::optional<json>(json{{"hat_bytes", b.size()}});
  });
  auto meta = std::string("\x0A\x03red", 5);
  auto lobby = h.receive("lobby:l1", "updated", "Lobby", {{"id", "l1"}, {"metadata_pb", meta}});
  CHECK(lobby["metadata"] == json{{"hat_bytes", 5}});
  CHECK_FALSE(lobby.contains("metadata_pb"));

  // No decoder for users: the bytes stay, base64.
  auto user = h.receive("user:u1", "updated", "User", {{"id", "u1"}, {"metadata_pb", meta}});
  CHECK(user["metadata_pb"] == proto::base64(meta));
}

TEST_CASE("unbase64 undoes base64") {
  for (const std::string& text : std::vector<std::string>{"", "f", "fo", "foo", std::string("\x00\xFF\x10", 3)}) {
    CHECK(proto::unbase64(proto::base64(text)) == text);
  }
  CHECK_FALSE(proto::unbase64("not base64!"));
}
