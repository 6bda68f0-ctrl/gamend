// The inbox and the timers: how work reaches the game thread.
#pragma once

#include <chrono>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

#include "gamend/client.hpp"

namespace gamend::detail {

class Loop : public std::enable_shared_from_this<Loop> {
 public:
  using Task = std::function<void()>;
  using Clock = std::function<std::chrono::milliseconds()>;

  Loop(Dispatch dispatch, Clock clock);

  /// From any thread: run `task` in the next `drain()`, or now, one task at
  /// a time, under `Dispatch::Immediate`. Dropped once the loop is closed.
  void post(Task task);
  /// What an I/O thread holds instead of the loop: posting through it after
  /// the client is gone does nothing.
  std::function<void(Task)> poster();
  /// Run what was posted, in order, then the timers that are due.
  void drain();
  /// Run `task` in the first `drain()` at least `delay` from now. Answers an
  /// id for `cancel`, never 0.
  std::uint64_t after(std::chrono::milliseconds delay, Task task);
  void cancel(std::uint64_t id);
  std::chrono::milliseconds now() const;
  /// Stop running anything. Waits for an immediate task in flight.
  void close();
  /// Run `task` now, on the calling thread, but never beside a task or a
  /// timer of this loop: what a public method wraps its body in, so it is
  /// safe from any thread under both dispatch modes.
  template <class F>
  auto exclusive(F&& task) {
    std::lock_guard<std::recursive_mutex> running(running_);
    return task();
  }

 private:
  struct Timer {
    std::chrono::milliseconds due;
    std::uint64_t id;
    Task task;
  };

  Dispatch dispatch_;
  Clock clock_;
  std::mutex mutex_;
  std::deque<Task> inbox_;
  std::vector<Timer> timers_;
  std::uint64_t next_timer_ = 1;
  bool closed_ = false;
  /// Serializes immediate tasks with each other and with `close`.
  std::recursive_mutex running_;
};

}  // namespace gamend::detail
