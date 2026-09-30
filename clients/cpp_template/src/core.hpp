// What `Client` owns, shared by `Rest`, `Auth` and `Api`.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "gamend/api.hpp"
#include "gamend/auth.hpp"
#include "gamend/client.hpp"
#include "gamend/kv.hpp"
#include "gamend/presence.hpp"
#include "gamend/realtime.hpp"
#include "gamend/rest.hpp"
#include "gamend/webrtc.hpp"
#include "loop.hpp"

namespace gamend::detail {

struct Core {
  explicit Core(Config config);
  ~Core();

  /// Close the loop, then drop the transports, which joins their threads:
  /// a completion still on its way finds nothing to run.
  void shutdown();

  std::int64_t unix_now() const;
  void log(LogLevel level, const std::string& line) const;

  Config config;
  std::string base_url;
  std::string run_id;
  std::shared_ptr<Loop> loop;
  /// `loop->poster()`, which is what an I/O thread may hold.
  std::function<void(Loop::Task)> post;
  Rest rest;
  Auth auth;
  Realtime realtime;
  Api api;
  Kv kv;
  Presence presence;
  WebRtc webrtc;
};

}  // namespace gamend::detail
