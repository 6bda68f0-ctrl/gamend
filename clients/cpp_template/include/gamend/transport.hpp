// The only place a network library appears. The core speaks to these
// interfaces (HTTP, WebSocket, and a WebRTC peer); the SDK ships libcurl and IXWebSocket implementations behind
// CMake options, an engine plugs in its own (Unreal's `FHttpModule` and
// `IWebSocket`), and the unit tests use `gamend/testing/fake_transport.hpp`.
//
// A transport may complete on any thread. The client hands every completion
// to the game thread through its inbox, so an implementation never needs to.
#pragma once

#include <chrono>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace gamend {

using Headers = std::vector<std::pair<std::string, std::string>>;

struct HttpRequest {
  std::string method;  // GET, POST, PUT, PATCH, DELETE
  std::string url;
  std::string body;    // empty for none
  Headers headers;
  std::chrono::milliseconds timeout{10000};
};

struct HttpResponse {
  int status = 0;       // 0 when no reply arrived
  std::string body;
  std::string error;    // why no reply arrived; empty when one did
};

class HttpTransport {
 public:
  virtual ~HttpTransport() = default;
  /// Send `request`; call `done` exactly once, from any thread. A 4xx or 5xx
  /// is a reply like any other, not an `error`. A transport being destroyed
  /// may drop the completions it still owes.
  virtual void send(HttpRequest request, std::function<void(HttpResponse)> done) = 0;
};

struct WebSocketHandlers {
  std::function<void()> on_open;
  std::function<void(std::string frame)> on_text;
  /// A binary frame: the server's protobuf events, when asked for.
  std::function<void(std::string bytes)> on_binary;
  /// The connection ended, whoever ended it. It may or may not come for a
  /// `close()` the client asked for.
  std::function<void(int code, std::string reason)> on_close;
  /// The connection failed, opening or open. `on_close` may follow.
  std::function<void(std::string error)> on_error;
};

class WebSocketTransport {
 public:
  virtual ~WebSocketTransport() = default;
  /// Connect to `url` (`ws://` or `wss://`). The handlers may run on any
  /// thread. Reconnecting is the caller's business, not the transport's.
  virtual void open(const std::string& url, WebSocketHandlers handlers) = 0;
  virtual void send_text(std::string frame) = 0;
  virtual void close() = 0;
};

/// A WebRTC DataChannel to open: `events` and `state` by default.
struct DataChannelSpec {
  std::string label;
  bool ordered = true;
  /// -1: reliable. 0 or more: give up on a message after that many retries.
  int max_retransmits = -1;
};

/// What a peer connection reports, from any thread.
struct PeerHandlers {
  /// The offer to send: its SDP and type (`offer`).
  std::function<void(std::string sdp, std::string type)> on_local_description;
  /// An ICE candidate (`candidate:...`) and its media id.
  std::function<void(std::string candidate, std::string mid)> on_local_candidate;
  /// `connecting`, `connected`, `disconnected`, `failed` or `closed`.
  std::function<void(std::string state)> on_state;
  std::function<void(std::string label)> on_channel_open;
  std::function<void(std::string label)> on_channel_close;
  std::function<void(std::string label, std::string data, bool binary)> on_message;
};

class PeerTransport {
 public:
  virtual ~PeerTransport() = default;
  /// Create the connection with `channels` (each negotiated with
  /// `protocol`, empty or `protobuf`) and make the offer.
  virtual void open(const std::vector<std::string>& ice_servers,
                    const std::vector<DataChannelSpec>& channels, const std::string& protocol,
                    PeerHandlers handlers) = 0;
  virtual void set_remote_description(const std::string& sdp, const std::string& type) = 0;
  virtual void add_remote_candidate(const std::string& candidate, const std::string& mid) = 0;
  /// False when the channel is not open.
  virtual bool send(const std::string& label, const std::string& data, bool binary) = 0;
  virtual void close() = 0;
};

}  // namespace gamend
