// Compiled with exceptions: libdatachannel reports errors by throwing. None
// crosses into the rest of the SDK, which is built without them: every call
// into the library is caught here and reported through the handlers.
#include "gamend/libdatachannel_transport.hpp"

#include <rtc/rtc.hpp>

#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace gamend {
namespace {

const char* state_name(rtc::PeerConnection::State state) {
  switch (state) {
    case rtc::PeerConnection::State::New:
      return "new";
    case rtc::PeerConnection::State::Connecting:
      return "connecting";
    case rtc::PeerConnection::State::Connected:
      return "connected";
    case rtc::PeerConnection::State::Disconnected:
      return "disconnected";
    case rtc::PeerConnection::State::Failed:
      return "failed";
    case rtc::PeerConnection::State::Closed:
      return "closed";
  }
  return "failed";
}

class LibDataChannelTransport final : public PeerTransport {
 public:
  ~LibDataChannelTransport() override { close(); }

  void open(const std::vector<std::string>& ice_servers,
            const std::vector<DataChannelSpec>& channels, const std::string& protocol,
            PeerHandlers handlers) override {
    close();
    try {
      rtc::Configuration config;
      for (const auto& server : ice_servers) config.iceServers.emplace_back(server);
      auto pc = std::make_shared<rtc::PeerConnection>(config);
      auto shared = std::make_shared<PeerHandlers>(std::move(handlers));
      pc->onLocalDescription([shared](rtc::Description description) {
        if (shared->on_local_description) {
          shared->on_local_description(std::string(description), description.typeString());
        }
      });
      pc->onLocalCandidate([shared](rtc::Candidate candidate) {
        if (shared->on_local_candidate) {
          shared->on_local_candidate(candidate.candidate(), candidate.mid());
        }
      });
      pc->onStateChange([shared](rtc::PeerConnection::State state) {
        if (shared->on_state) shared->on_state(state_name(state));
      });
      std::map<std::string, std::shared_ptr<rtc::DataChannel>> opened;
      for (const auto& spec : channels) {
        rtc::DataChannelInit init;
        init.reliability.unordered = !spec.ordered;
        if (spec.max_retransmits >= 0) {
          init.reliability.maxRetransmits = static_cast<unsigned int>(spec.max_retransmits);
        }
        init.protocol = protocol;
        auto channel = pc->createDataChannel(spec.label, init);
        auto label = spec.label;
        channel->onOpen([shared, label] {
          if (shared->on_channel_open) shared->on_channel_open(label);
        });
        channel->onClosed([shared, label] {
          if (shared->on_channel_close) shared->on_channel_close(label);
        });
        channel->onMessage([shared, label](rtc::message_variant message) {
          if (!shared->on_message) return;
          if (auto* text = std::get_if<rtc::string>(&message)) {
            shared->on_message(label, *text, false);
          } else if (auto* bytes = std::get_if<rtc::binary>(&message)) {
            shared->on_message(
                label, std::string(reinterpret_cast<const char*>(bytes->data()), bytes->size()),
                true);
          }
        });
        opened.emplace(spec.label, std::move(channel));
      }
      std::lock_guard<std::mutex> lock(mutex_);
      pc_ = std::move(pc);
      channels_ = std::move(opened);
      handlers_ = std::move(shared);
    } catch (const std::exception& error) {
      if (handlers.on_state) handlers.on_state("failed");
    }
  }

  void set_remote_description(const std::string& sdp, const std::string& type) override {
    auto pc = peer();
    if (!pc) return;
    try {
      pc->setRemoteDescription(rtc::Description(sdp, type));
    } catch (const std::exception&) {
      fail();
    }
  }

  void add_remote_candidate(const std::string& candidate, const std::string& mid) override {
    auto pc = peer();
    if (!pc) return;
    try {
      pc->addRemoteCandidate(rtc::Candidate(candidate, mid));
    } catch (const std::exception&) {
      // One unusable candidate is not the connection failing: others follow.
    }
  }

  bool send(const std::string& label, const std::string& data, bool binary) override {
    std::shared_ptr<rtc::DataChannel> channel;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = channels_.find(label);
      if (it == channels_.end()) return false;
      channel = it->second;
    }
    try {
      if (!channel->isOpen()) return false;
      if (binary) {
        rtc::binary bytes(data.size());
        std::memcpy(bytes.data(), data.data(), data.size());
        return channel->send(std::move(bytes));
      }
      return channel->send(data);
    } catch (const std::exception&) {
      return false;
    }
  }

  void close() override {
    std::shared_ptr<rtc::PeerConnection> pc;
    std::map<std::string, std::shared_ptr<rtc::DataChannel>> channels;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pc = std::move(pc_);
      channels = std::move(channels_);
      pc_.reset();
      channels_.clear();
      handlers_.reset();
    }
    try {
      for (auto& [label, channel] : channels) {
        channel->resetCallbacks();
        channel->close();
      }
      if (pc) {
        pc->resetCallbacks();
        pc->close();
      }
    } catch (const std::exception&) {
    }
  }

 private:
  std::shared_ptr<rtc::PeerConnection> peer() {
    std::lock_guard<std::mutex> lock(mutex_);
    return pc_;
  }

  void fail() {
    std::shared_ptr<PeerHandlers> handlers;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      handlers = handlers_;
    }
    if (handlers && handlers->on_state) handlers->on_state("failed");
  }

  std::mutex mutex_;
  std::shared_ptr<rtc::PeerConnection> pc_;
  std::map<std::string, std::shared_ptr<rtc::DataChannel>> channels_;
  std::shared_ptr<PeerHandlers> handlers_;
};

}  // namespace

std::unique_ptr<PeerTransport> make_libdatachannel_transport() {
  return std::make_unique<LibDataChannelTransport>();
}

}  // namespace gamend
