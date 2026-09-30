// Transports and a clock a test drives by hand, header-only so a game's own
// tests can use them too.
//
//     auto http = std::make_unique<gamend::testing::FakeHttp>();
//     auto& server = *http;
//     gamend::testing::FakeClock clock;
//     gamend::Config config;
//     config.base_url = "http://test";
//     config.http = std::move(http);
//     config.clock = clock.steady();
//     gamend::Client client(std::move(config));
//
//     client.api().users_get_current_user(done);
//     server.reply(200, R"({"data": {"id": "u1"}})");
//     client.poll();                       // `done` runs here
#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "gamend/transport.hpp"

namespace gamend::testing {

/// An HTTP transport that answers when told to. Every request is kept, in
/// the order it was sent; the unanswered ones wait in `pending()`.
class FakeHttp final : public HttpTransport {
 public:
  void send(HttpRequest request, std::function<void(HttpResponse)> done) override {
    std::lock_guard<std::mutex> lock(mutex_);
    sent_.push_back(request);
    waiting_.push_back({std::move(request), std::move(done)});
  }

  /// Every request sent so far, answered or not.
  std::vector<HttpRequest> sent() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sent_;
  }
  std::size_t pending() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return waiting_.size();
  }
  /// The oldest unanswered request. Check `pending()` first.
  HttpRequest next() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return waiting_.front().request;
  }
  /// Answer the oldest unanswered request.
  void reply(int status, std::string body) {
    HttpResponse response;
    response.status = status;
    response.body = std::move(body);
    complete(std::move(response));
  }
  /// Fail the oldest unanswered request, as a transport does when no reply
  /// arrives.
  void fail(std::string error) {
    HttpResponse response;
    response.error = std::move(error);
    complete(std::move(response));
  }

  /// The value of `name` in `request`'s headers, or empty.
  static std::string header(const HttpRequest& request, std::string_view name) {
    for (const auto& [key, value] : request.headers) {
      if (key == name) return value;
    }
    return {};
  }

 private:
  struct Waiting {
    HttpRequest request;
    std::function<void(HttpResponse)> done;
  };

  void complete(HttpResponse response) {
    std::function<void(HttpResponse)> done;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (waiting_.empty()) return;
      done = std::move(waiting_.front().done);
      waiting_.pop_front();
    }
    done(std::move(response));
  }

  mutable std::mutex mutex_;
  std::vector<HttpRequest> sent_;
  std::deque<Waiting> waiting_;
};

/// A WebSocket transport the test opens, feeds and drops.
class FakeWebSocket final : public WebSocketTransport {
 public:
  void open(const std::string& url, WebSocketHandlers handlers) override {
    std::lock_guard<std::mutex> lock(mutex_);
    url_ = url;
    handlers_ = std::move(handlers);
    opened_ = true;
    ++opens_;
  }
  void send_text(std::string frame) override {
    std::lock_guard<std::mutex> lock(mutex_);
    frames_.push_back(frame);
    unread_.push_back(std::move(frame));
  }
  void close() override {
    std::lock_guard<std::mutex> lock(mutex_);
    opened_ = false;
  }

  std::string url() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return url_;
  }
  bool opened() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return opened_;
  }
  /// Every frame the client sent, oldest first.
  std::vector<std::string> frames() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return frames_;
  }

  /// The server side: accept, send a frame, drop the connection.
  void accept() {
    if (auto handler = handlers().on_open) handler();
  }
  void receive(std::string frame) {
    if (auto handler = handlers().on_text) handler(std::move(frame));
  }
  void receive_binary(std::string bytes) {
    if (auto handler = handlers().on_binary) handler(std::move(bytes));
  }
  /// The connection fails before or after opening, as a transport reports it.
  void fail(std::string error) {
    if (auto handler = handlers().on_error) handler(std::move(error));
  }
  /// How many times the client opened a connection.
  int opens() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return opens_;
  }
  /// The frames sent since the last `take_frames()`, oldest first.
  std::vector<std::string> take_frames() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::string> out;
    out.swap(unread_);
    return out;
  }
  void drop(int code = 1006, std::string reason = {}) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      opened_ = false;
    }
    if (auto handler = handlers().on_close) handler(code, std::move(reason));
  }

 private:
  WebSocketHandlers handlers() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return handlers_;
  }

  mutable std::mutex mutex_;
  std::string url_;
  WebSocketHandlers handlers_;
  std::vector<std::string> frames_;
  std::vector<std::string> unread_;
  bool opened_ = false;
  int opens_ = 0;
};

/// A WebRTC peer the test drives: it records what the client asks of it, and
/// plays the connection's side of the story on command.
class FakePeer final : public PeerTransport {
 public:
  void open(const std::vector<std::string>& ice_servers,
            const std::vector<DataChannelSpec>& channels, const std::string& protocol,
            PeerHandlers handlers) override {
    std::lock_guard<std::mutex> lock(mutex_);
    ice_servers_ = ice_servers;
    channels_ = channels;
    protocol_ = protocol;
    handlers_ = std::move(handlers);
    opened_ = true;
  }
  void set_remote_description(const std::string& sdp, const std::string& type) override {
    std::lock_guard<std::mutex> lock(mutex_);
    remote_ = {sdp, type};
  }
  void add_remote_candidate(const std::string& candidate, const std::string& mid) override {
    std::lock_guard<std::mutex> lock(mutex_);
    candidates_.emplace_back(candidate, mid);
  }
  bool send(const std::string& label, const std::string& data, bool binary) override {
    std::lock_guard<std::mutex> lock(mutex_);
    sent_.push_back({label, data, binary});
    return true;
  }
  void close() override {
    std::lock_guard<std::mutex> lock(mutex_);
    opened_ = false;
    ++closes_;
  }

  struct Sent {
    std::string label;
    std::string data;
    bool binary;
  };

  bool opened() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return opened_;
  }
  int closes() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closes_;
  }
  std::string protocol() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return protocol_;
  }
  std::vector<std::string> ice_servers() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return ice_servers_;
  }
  std::vector<DataChannelSpec> channels() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return channels_;
  }
  /// The remote description set: SDP and type.
  std::pair<std::string, std::string> remote() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return remote_;
  }
  std::vector<std::pair<std::string, std::string>> candidates() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return candidates_;
  }
  std::vector<Sent> sent() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sent_;
  }

  // The connection's side.
  void offer(std::string sdp) {
    if (auto h = handlers().on_local_description) h(std::move(sdp), "offer");
  }
  void candidate(std::string candidate, std::string mid) {
    if (auto h = handlers().on_local_candidate) h(std::move(candidate), std::move(mid));
  }
  void state(std::string state) {
    if (auto h = handlers().on_state) h(std::move(state));
  }
  void open_channel(std::string label) {
    if (auto h = handlers().on_channel_open) h(std::move(label));
  }
  void close_channel(std::string label) {
    if (auto h = handlers().on_channel_close) h(std::move(label));
  }
  void receive(std::string label, std::string data, bool binary) {
    if (auto h = handlers().on_message) h(std::move(label), std::move(data), binary);
  }

 private:
  PeerHandlers handlers() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return handlers_;
  }

  mutable std::mutex mutex_;
  PeerHandlers handlers_;
  std::vector<std::string> ice_servers_;
  std::vector<DataChannelSpec> channels_;
  std::string protocol_;
  std::pair<std::string, std::string> remote_;
  std::vector<std::pair<std::string, std::string>> candidates_;
  std::vector<Sent> sent_;
  bool opened_ = false;
  int closes_ = 0;
};

/// Both clocks a `Config` takes, moved by hand. Hand `steady()` and `wall()`
/// to the config; keep the clock alive as long as the client.
class FakeClock {
 public:
  explicit FakeClock(std::int64_t unix_seconds = 1'800'000'000) : unix_ms_(unix_seconds * 1000) {}

  void advance(std::chrono::milliseconds by) {
    std::lock_guard<std::mutex> lock(mutex_);
    steady_ += by;
    unix_ms_ += by.count();
  }

  std::function<std::chrono::milliseconds()> steady() {
    return [this] {
      std::lock_guard<std::mutex> lock(mutex_);
      return steady_;
    };
  }
  std::function<std::int64_t()> wall() {
    return [this] {
      std::lock_guard<std::mutex> lock(mutex_);
      return unix_ms_ / 1000;
    };
  }

 private:
  std::mutex mutex_;
  std::chrono::milliseconds steady_{0};
  std::int64_t unix_ms_;
};

}  // namespace gamend::testing
