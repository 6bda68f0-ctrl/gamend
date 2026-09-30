#include "gamend/client.hpp"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <thread>
#include <utility>

#include "core.hpp"

namespace gamend {
namespace detail {
namespace {

std::chrono::milliseconds steady_now() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now().time_since_epoch());
}

std::uint64_t mix(std::uint64_t x) {
  // splitmix64: spreads the entropy of the clocks across every bit.
  x += 0x9e3779b97f4a7c15ULL;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
  return x ^ (x >> 31);
}

// A run id: unique enough to tell two runs apart in the server's logs, which
// is all it is for. No `std::random_device`, which may throw where there is
// no entropy source, and the core builds without exceptions.
std::string make_run_id(const void* salt) {
  auto wall = static_cast<std::uint64_t>(
      std::chrono::system_clock::now().time_since_epoch().count());
  auto steady = static_cast<std::uint64_t>(
      std::chrono::steady_clock::now().time_since_epoch().count());
  auto thread = static_cast<std::uint64_t>(std::hash<std::thread::id>{}(std::this_thread::get_id()));
  auto high = mix(wall ^ mix(reinterpret_cast<std::uintptr_t>(salt)));
  auto low = mix(steady ^ mix(thread) ^ high);
  char out[33];
  std::snprintf(out, sizeof out, "%016llx%016llx", static_cast<unsigned long long>(high),
                static_cast<unsigned long long>(low));
  return out;
}

std::string trimmed(std::string url) {
  while (!url.empty() && url.back() == '/') url.pop_back();
  return url;
}

}  // namespace

Core::Core(Config given)
    : config(std::move(given)),
      base_url(trimmed(config.base_url)),
      run_id(config.run_id.empty() ? make_run_id(this) : config.run_id),
      loop(std::make_shared<Loop>(config.dispatch,
                                  config.clock ? config.clock : Loop::Clock(steady_now))),
      post(loop->poster()),
      rest(*this),
      auth(*this),
      realtime(*this),
      api(rest),
      kv(*this),
      presence(*this),
      webrtc(*this) {}

Core::~Core() { shutdown(); }

void Core::shutdown() {
  loop->close();
  config.webrtc.reset();
  config.http.reset();
  config.websocket.reset();
}

std::int64_t Core::unix_now() const {
  if (config.unix_clock) return config.unix_clock();
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void Core::log(LogLevel level, const std::string& line) const {
  if (config.log) config.log(level, line);
}

}  // namespace detail

Client::Client(Config config) : core_(std::make_unique<detail::Core>(std::move(config))) {}

Client::~Client() { core_->shutdown(); }

Api& Client::api() { return core_->api; }
Auth& Client::auth() { return core_->auth; }
Rest& Client::rest() { return core_->rest; }
Realtime& Client::realtime() { return core_->realtime; }
Kv& Client::kv() { return core_->kv; }
Presence& Client::presence() { return core_->presence; }
WebRtc& Client::webrtc() { return core_->webrtc; }
WebSocketTransport* Client::websocket() { return core_->config.websocket.get(); }
void Client::poll() { core_->loop->drain(); }
const std::string& Client::base_url() const { return core_->base_url; }
const std::string& Client::run_id() const { return core_->run_id; }

}  // namespace gamend
