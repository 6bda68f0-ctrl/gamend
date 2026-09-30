#include "gamend/curl_transport.hpp"

#include <curl/curl.h>

#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

namespace gamend {
namespace {

std::once_flag curl_ready;

struct Transfer {
  HttpRequest request;
  std::function<void(HttpResponse)> done;
  CURL* easy = nullptr;
  curl_slist* headers = nullptr;
  std::string received;
  char error[CURL_ERROR_SIZE] = {};

  ~Transfer() {
    if (headers != nullptr) curl_slist_free_all(headers);
    if (easy != nullptr) curl_easy_cleanup(easy);
  }
};

size_t collect(char* data, size_t size, size_t count, void* user) {
  static_cast<Transfer*>(user)->received.append(data, size * count);
  return size * count;
}

class CurlTransport final : public HttpTransport {
 public:
  CurlTransport() {
    std::call_once(curl_ready, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });
    multi_ = curl_multi_init();
    worker_ = std::thread([this] { run(); });
  }

  ~CurlTransport() override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    curl_multi_wakeup(multi_);
    worker_.join();
    curl_multi_cleanup(multi_);
  }

  void send(HttpRequest request, std::function<void(HttpResponse)> done) override {
    auto transfer = std::make_unique<Transfer>();
    transfer->request = std::move(request);
    transfer->done = std::move(done);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      queue_.push_back(std::move(transfer));
    }
    curl_multi_wakeup(multi_);
  }

 private:
  // Only the worker touches the multi handle and the easy handles; `send`
  // hands transfers over through the queue and wakes it.
  void run() {
    std::deque<std::unique_ptr<Transfer>> active;
    for (;;) {
      std::deque<std::unique_ptr<Transfer>> fresh;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) break;
        fresh.swap(queue_);
      }
      for (auto& transfer : fresh) {
        if (begin(*transfer)) {
          active.push_back(std::move(transfer));
        } else {
          HttpResponse reply;
          reply.error = "could not start the request";
          transfer->done(std::move(reply));
        }
      }

      int running = 0;
      curl_multi_perform(multi_, &running);
      int left = 0;
      while (CURLMsg* message = curl_multi_info_read(multi_, &left)) {
        if (message->msg != CURLMSG_DONE) continue;
        CURL* easy = message->easy_handle;
        CURLcode result = message->data.result;
        for (auto it = active.begin(); it != active.end(); ++it) {
          if ((*it)->easy != easy) continue;
          std::unique_ptr<Transfer> transfer = std::move(*it);
          active.erase(it);
          curl_multi_remove_handle(multi_, easy);
          complete(*transfer, result);
          break;
        }
      }
      curl_multi_poll(multi_, nullptr, 0, 1000, nullptr);
    }
    // Stopping: what is still in flight is dropped with its completion, as
    // the interface allows.
    for (auto& transfer : active) curl_multi_remove_handle(multi_, transfer->easy);
  }

  bool begin(Transfer& transfer) {
    transfer.easy = curl_easy_init();
    if (transfer.easy == nullptr) return false;
    const HttpRequest& request = transfer.request;
    CURL* easy = transfer.easy;
    curl_easy_setopt(easy, CURLOPT_URL, request.url.c_str());
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, static_cast<long>(request.timeout.count()));
    curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, collect);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &transfer);
    curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, transfer.error);
    for (const auto& [name, value] : request.headers) {
      transfer.headers = curl_slist_append(transfer.headers, (name + ": " + value).c_str());
    }
    // curl adds `Expect: 100-continue` to large bodies; the server would
    // answer it, but it costs a round trip for nothing.
    transfer.headers = curl_slist_append(transfer.headers, "Expect:");
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, transfer.headers);
    if (request.method == "GET") {
      curl_easy_setopt(easy, CURLOPT_HTTPGET, 1L);
    } else {
      curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, request.method.c_str());
    }
    if (!request.body.empty()) {
      curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE,
                       static_cast<curl_off_t>(request.body.size()));
      curl_easy_setopt(easy, CURLOPT_POSTFIELDS, request.body.data());
    }
    curl_easy_setopt(easy, CURLOPT_PRIVATE, &transfer);
    return curl_multi_add_handle(multi_, easy) == CURLM_OK;
  }

  static void complete(Transfer& transfer, CURLcode result) {
    HttpResponse reply;
    if (result == CURLE_OK) {
      long status = 0;
      curl_easy_getinfo(transfer.easy, CURLINFO_RESPONSE_CODE, &status);
      reply.status = static_cast<int>(status);
      reply.body = std::move(transfer.received);
    } else {
      reply.error = transfer.error[0] != '\0' ? transfer.error : curl_easy_strerror(result);
    }
    transfer.done(std::move(reply));
  }

  CURLM* multi_ = nullptr;
  std::thread worker_;
  std::mutex mutex_;
  std::deque<std::unique_ptr<Transfer>> queue_;
  bool stopping_ = false;
};

}  // namespace

std::unique_ptr<HttpTransport> make_curl_transport() { return std::make_unique<CurlTransport>(); }

}  // namespace gamend
