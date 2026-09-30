#include <doctest/doctest.h>

#include "harness.hpp"
#include "proto.hpp"

using gamend::json;
using gamend::WebRtcState;
using harness::Harness;
using std::chrono::seconds;

namespace {

std::string reply(const json& frame, const std::string& status, const json& response = json::object()) {
  return gamend::dump(json::array(
      {frame[0], frame[1], frame[2], "phx_reply", {{"status", status}, {"response", response}}}));
}

std::string message(const std::string& topic, const std::string& event, const json& payload) {
  return gamend::dump(json::array({nullptr, nullptr, topic, event, payload}));
}

// Signed in, connected, the user channel joined.
struct Joined : Harness {
  explicit Joined(gamend::RealtimeFormat format = gamend::RealtimeFormat::Json)
      : Harness(gamend::Dispatch::Poll, true, format) {
    signed_in();
    client->realtime().connect();
    socket->accept();
    client->poll();
    auto join = json::parse(socket->take_frames().at(0));
    socket->receive(reply(join, "ok"));
    client->poll();
  }
  std::vector<json> frames() {
    std::vector<json> out;
    for (auto& f : socket->take_frames()) out.push_back(json::parse(f));
    return out;
  }
  // Offer, answer, one channel open: connected.
  void connect_all(std::string* error = nullptr) {
    client->webrtc().connect([error](const std::string& e) {
      if (error) *error = e;
    });
    peer->offer("v=0 offer");
    client->poll();
    auto offer = frames().at(0);
    socket->receive(reply(offer, "ok"));
    peer->open_channel("events");
    client->poll();
  }
};

}  // namespace

TEST_CASE("WebRTC needs the user channel and a peer transport") {
  Harness h;
  std::string error;
  h.client->webrtc().connect([&](const std::string& e) { error = e; });
  h.client->poll();
  CHECK(error == "not_joined");
  CHECK_FALSE(h.peer->opened());
}

TEST_CASE("the offer goes over the user channel, and the answer and candidates come back") {
  Joined h;
  std::string error = "unset";
  h.client->webrtc().connect([&](const std::string& e) { error = e; });
  CHECK(h.peer->opened());
  CHECK(h.peer->protocol().empty());
  CHECK(h.peer->ice_servers() == std::vector<std::string>{"stun:stun.l.google.com:19302"});
  REQUIRE(h.peer->channels().size() == 1);
  CHECK(h.peer->channels()[0].label == "events");
  CHECK(h.peer->channels()[0].ordered);
  CHECK(h.peer->channels()[0].max_retransmits == -1);
  CHECK(h.client->webrtc().state() == WebRtcState::Connecting);

  h.peer->offer("v=0 offer");
  h.peer->candidate("candidate:1 1 UDP 1 10.0.0.1 5000 typ host", "0");
  h.client->poll();
  auto sent = h.frames();
  REQUIRE(sent.size() == 2);
  CHECK(sent[0][3] == "webrtc:offer");
  CHECK(sent[0][4] == json{{"sdp", "v=0 offer"}, {"type", "offer"}});
  CHECK(sent[1][3] == "webrtc:ice");
  CHECK(sent[1][4]["sdpMid"] == "0");
  h.socket->receive(reply(sent[0], "ok"));

  h.socket->receive(message("user:u1", "webrtc:answer", {{"sdp", "v=0 answer"}, {"type", "answer"}}));
  h.socket->receive(message("user:u1", "webrtc:ice",
                            {{"candidate", "candidate:2 1 UDP 1 10.0.0.2 6000 typ host"},
                             {"sdpMid", "0"}, {"sdpMLineIndex", 0}}));
  h.client->poll();
  CHECK(h.peer->remote() == std::pair<std::string, std::string>{"v=0 answer", "answer"});
  REQUIRE(h.peer->candidates().size() == 1);
  CHECK(h.peer->candidates()[0].second == "0");
  CHECK(error == "unset");

  h.peer->open_channel("events");
  h.client->poll();
  CHECK(error.empty());
  CHECK(h.client->webrtc().state() == WebRtcState::Connected);
  CHECK(h.client->webrtc().channel_open("events"));
  CHECK_FALSE(h.client->webrtc().channel_open("state"));
}

TEST_CASE("hooks over the events channel, JSON: matched by plugin and function") {
  Joined h;
  h.connect_all();
  std::vector<std::pair<std::string, std::string>> data;
  h.client->webrtc().on_data([&](const std::string& label, const std::string& d, bool) {
    data.emplace_back(label, d);
  });
  gamend::HookResult got;
  h.client->webrtc().call_hook("arena", "move", json{{"x", 1}},
                               [&](const gamend::HookResult& r) { got = r; });
  auto sent = h.peer->sent();
  REQUIRE(sent.size() == 1);
  CHECK(sent[0].label == "events");
  CHECK_FALSE(sent[0].binary);
  CHECK(json::parse(sent[0].data) ==
        json{{"type", "call_hook"}, {"plugin", "arena"}, {"fn", "move"}, {"args", {{{"x", 1}}}}});

  h.peer->receive("events", R"({"type":"game_event","n":1})", false);
  h.peer->receive("events", R"({"type":"hook_reply","plugin":"arena","fn":"move","data":42})", false);
  h.client->poll();
  CHECK(got.ok);
  CHECK(got.data == 42);
  REQUIRE(data.size() == 1);
  CHECK(data[0].second == R"({"type":"game_event","n":1})");

  h.client->webrtc().call_hook("arena", "nope", json::array(),
                               [&](const gamend::HookResult& r) { got = r; });
  h.peer->receive("events", R"({"type":"hook_error","plugin":"arena","fn":"nope","error":"boom"})",
                  false);
  h.client->poll();
  CHECK_FALSE(got.ok);
  CHECK(got.error == "boom");
}

TEST_CASE("hooks over the events channel, protobuf: envelopes with request ids") {
  Joined h(gamend::RealtimeFormat::Protobuf);
  h.connect_all();
  CHECK(h.peer->protocol() == "protobuf");
  gamend::HookResult first;
  gamend::HookResult second;
  h.client->webrtc().call_hook("arena", "move", json::array({1}),
                               [&](const gamend::HookResult& r) { first = r; });
  h.client->webrtc().call_hook("arena", "move", json::array({2}),
                               [&](const gamend::HookResult& r) { second = r; });
  auto sent = h.peer->sent();
  REQUIRE(sent.size() == 2);
  CHECK(sent[0].binary);
  const auto& envelope = *gamend::detail::proto::find("RtcEnvelope");
  auto call = gamend::detail::proto::decode(envelope, sent[1].data, false);
  REQUIRE(call);
  CHECK((*call)["call_hook"]["id"] == 2);
  CHECK((*call)["call_hook"]["args"] == json::array({2}));

  // Out of order, told apart by id.
  h.peer->receive("events",
                  gamend::detail::proto::encode(envelope,
                                                {{"hook_reply", {{"id", 2}, {"data_json", "\"two\""}}}}),
                  true);
  h.peer->receive("events",
                  gamend::detail::proto::encode(envelope,
                                                {{"hook_error", {{"id", 1}, {"error", "nope"}}}}),
                  true);
  h.client->poll();
  CHECK(second.ok);
  CHECK(second.data == "two");
  CHECK_FALSE(first.ok);
  CHECK(first.error == "nope");
}

TEST_CASE("an offer the server refuses fails the connect") {
  Joined h;
  std::string error;
  h.client->webrtc().connect([&](const std::string& e) { error = e; });
  h.peer->offer("v=0");
  h.client->poll();
  auto offer = h.frames().at(0);
  h.socket->receive(reply(offer, "error", {{"error", "webrtc_disabled"}}));
  h.client->poll();
  CHECK(error == "webrtc_disabled");
  CHECK(h.client->webrtc().state() == WebRtcState::Failed);
}

TEST_CASE("a connection that never opens a channel times out") {
  Joined h;
  std::string error;
  h.client->webrtc().connect([&](const std::string& e) { error = e; });
  h.advance(seconds(15));
  CHECK(error == "timeout");
  CHECK(h.client->webrtc().state() == WebRtcState::Failed);
  CHECK(h.peer->closes() >= 1);
}

TEST_CASE("close tells the server; losing the socket closes too") {
  Joined h;
  h.connect_all();
  h.frames();
  h.client->webrtc().close();
  auto sent = h.frames();
  REQUIRE(sent.size() == 1);
  CHECK(sent[0][3] == "webrtc:close");
  CHECK(h.client->webrtc().state() == WebRtcState::Closed);
  CHECK_FALSE(h.peer->opened());

  h.connect_all();
  CHECK(h.client->webrtc().state() == WebRtcState::Connected);
  gamend::HookResult pending;
  h.client->webrtc().call_hook("a", "b", json::array(),
                               [&](const gamend::HookResult& r) { pending = r; });
  h.socket->drop();
  h.client->poll();
  CHECK(h.client->webrtc().state() == WebRtcState::Closed);
  CHECK(pending.error == "closed");
}

TEST_CASE("a typed hook sends raw bytes and answers raw bytes, in protobuf mode only") {
  Joined h(gamend::RealtimeFormat::Protobuf);
  h.connect_all();
  gamend::HookResult got;
  h.client->webrtc().call_hook_raw("arena", "move", std::string("\x08\x01", 2),
                                   [&](const gamend::HookResult& r) { got = r; });
  const auto& envelope = *gamend::detail::proto::find("RtcEnvelope");
  auto sent = gamend::detail::proto::decode(envelope, h.peer->sent().back().data, false);
  REQUIRE(sent);
  CHECK((*sent)["call_hook"]["args_raw"] == gamend::detail::proto::base64(std::string("\x08\x01", 2)));
  h.peer->receive("events",
                  gamend::detail::proto::encode(
                      envelope, {{"hook_reply", {{"id", 1}, {"data_raw", std::string("\x10\x02", 2)}}}}),
                  true);
  h.client->poll();
  CHECK(got.ok);
  CHECK(got.bytes == std::string("\x10\x02", 2));

  Joined json_mode;
  json_mode.connect_all();
  json_mode.client->webrtc().call_hook_raw("arena", "move", "x",
                                           [&](const gamend::HookResult& r) { got = r; });
  json_mode.client->poll();
  CHECK(got.error == "needs_protobuf");
}
