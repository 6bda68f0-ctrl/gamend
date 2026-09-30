#include "loop.hpp"

#include <algorithm>
#include <utility>

namespace gamend::detail {

Loop::Loop(Dispatch dispatch, Clock clock) : dispatch_(dispatch), clock_(std::move(clock)) {}

void Loop::post(Task task) {
  if (dispatch_ == Dispatch::Immediate) {
    std::lock_guard<std::recursive_mutex> running(running_);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_) return;
    }
    task();
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (closed_) return;
  inbox_.push_back(std::move(task));
}

std::function<void(Loop::Task)> Loop::poster() {
  std::weak_ptr<Loop> weak = shared_from_this();
  return [weak](Task task) {
    if (auto loop = weak.lock()) loop->post(std::move(task));
  };
}

void Loop::drain() {
  // Under `Dispatch::Immediate` the timers below would otherwise run beside
  // a completion on an I/O thread.
  std::lock_guard<std::recursive_mutex> running(running_);
  std::deque<Task> ready;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return;
    ready.swap(inbox_);
  }
  // A task posted while these run waits for the next drain, so a callback
  // that starts another call never runs that call's callback inside itself.
  for (auto& task : ready) task();

  std::vector<Timer> due;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto now = clock_();
    auto split = std::stable_partition(timers_.begin(), timers_.end(),
                                       [now](const Timer& timer) { return timer.due > now; });
    due.assign(std::make_move_iterator(split), std::make_move_iterator(timers_.end()));
    timers_.erase(split, timers_.end());
  }
  std::stable_sort(due.begin(), due.end(), [](const Timer& a, const Timer& b) {
    return a.due < b.due || (a.due == b.due && a.id < b.id);
  });
  for (auto& timer : due) timer.task();
}

std::uint64_t Loop::after(std::chrono::milliseconds delay, Task task) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto id = next_timer_++;
  timers_.push_back({clock_() + delay, id, std::move(task)});
  return id;
}

void Loop::cancel(std::uint64_t id) {
  if (id == 0) return;
  std::lock_guard<std::mutex> lock(mutex_);
  timers_.erase(std::remove_if(timers_.begin(), timers_.end(),
                               [id](const Timer& timer) { return timer.id == id; }),
                timers_.end());
}

std::chrono::milliseconds Loop::now() const { return clock_(); }

void Loop::close() {
  std::lock_guard<std::recursive_mutex> running(running_);
  std::lock_guard<std::mutex> lock(mutex_);
  closed_ = true;
  inbox_.clear();
  timers_.clear();
}

}  // namespace gamend::detail
