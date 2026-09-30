#include "gamend/ix_websocket_transport.hpp"

#include <ixwebsocket/IXNetSystem.h>
#include <ixwebsocket/IXWebSocket.h>

#include <memory>
#include <mutex>
#include <utility>

namespace gamend {
namespace {

std::once_flag net_ready;

class IxWebSocketTransport final : public WebSocketTransport {
 public:
  IxWebSocketTransport() {
    // Winsock on Windows; nothing elsewhere.
    std::call_once(net_ready, [] { ix::initNetSystem(); });
    socket_.disableAutomaticReconnection();
  }

  ~IxWebSocketTransport() override { socket_.stop(); }

  void open(const std::string& url, WebSocketHandlers handlers) override {
    socket_.stop();
    socket_.setUrl(url);
    socket_.setOnMessageCallback(
        [handlers = std::move(handlers)](const ix::WebSocketMessagePtr& message) {
          switch (message->type) {
            case ix::WebSocketMessageType::Open:
              if (handlers.on_open) handlers.on_open();
              break;
            case ix::WebSocketMessageType::Message:
              if (message->binary) {
                if (handlers.on_binary) handlers.on_binary(message->str);
              } else if (handlers.on_text) {
                handlers.on_text(message->str);
              }
              break;
            case ix::WebSocketMessageType::Close:
              if (handlers.on_close) {
                handlers.on_close(message->closeInfo.code, message->closeInfo.reason);
              }
              break;
            case ix::WebSocketMessageType::Error:
              if (handlers.on_error) handlers.on_error(message->errorInfo.reason);
              break;
            default:
              break;
          }
        });
    socket_.start();
  }

  void send_text(std::string frame) override { socket_.sendText(frame); }

  void close() override { socket_.stop(); }

 private:
  ix::WebSocket socket_;
};

}  // namespace

std::unique_ptr<WebSocketTransport> make_ix_websocket_transport() {
  return std::make_unique<IxWebSocketTransport>();
}

}  // namespace gamend
