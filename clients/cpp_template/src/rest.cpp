#include "gamend/rest.hpp"

#include <utility>

#include "core.hpp"
#include "gamend/version.hpp"

namespace gamend {

struct Rest::Call {
  std::string method;
  std::string path;
  Body body;
  Callback done;
  bool authenticated = true;
  bool retried = false;
};

Rest::Rest(detail::Core& core) : core_(core) {}
Rest::~Rest() = default;

void Rest::send(std::string_view method, std::string path, Body body, Callback done) {
  auto call = std::make_shared<Call>();
  call->method = std::string(method);
  call->path = std::move(path);
  call->body = std::move(body);
  call->done = std::move(done);
  start(std::move(call));
}

void Rest::send_anonymous(std::string_view method, std::string path, Body body, Callback done) {
  auto call = std::make_shared<Call>();
  call->method = std::string(method);
  call->path = std::move(path);
  call->body = std::move(body);
  call->done = std::move(done);
  call->authenticated = false;
  start(std::move(call));
}

void Rest::refuse(std::string_view call, std::string_view field, Callback done) {
  std::string message = std::string(call) + " needs `" + std::string(field) + "`";
  core_.log(LogLevel::Error, "gamend: " + message);
  core_.post([done = std::move(done), message = std::move(message)] {
    if (!done) return;
    Response response;
    response.error = message;
    done(response);
  });
}

namespace {

bool carries_body(const std::string& method) {
  return method == "POST" || method == "PUT" || method == "PATCH";
}

}  // namespace

void Rest::start(std::shared_ptr<Call> call) {
  HttpRequest request;
  request.method = call->method;
  request.url = core_.base_url + call->path;
  request.timeout = core_.config.http_timeout;
  request.headers = {
      {"accept", "application/json"},
      {"user-agent", "gamend-cpp/" GAMEND_VERSION},
      {"x-gamend-session", core_.run_id},
  };
  if (call->authenticated) {
    auto bearer = core_.auth.bearer();
    if (!bearer.empty()) request.headers.emplace_back("authorization", std::move(bearer));
  }
  switch (call->body.kind) {
    case Body::Kind::Json:
      // A null body is an empty object: `api().x({}, ...)` builds a null.
      request.body = call->body.value.is_null() ? "{}" : dump(call->body.value);
      request.headers.emplace_back("content-type", "application/json");
      break;
    case Body::Kind::Bytes:
      request.body = call->body.bytes;
      request.headers.emplace_back("content-type", call->body.content_type);
      break;
    case Body::Kind::None:
      if (carries_body(call->method)) {
        request.body = "{}";
        request.headers.emplace_back("content-type", "application/json");
      }
      break;
  }

  auto* http = core_.config.http.get();
  if (http == nullptr) {
    HttpResponse reply;
    reply.error = "no HTTP transport configured";
    core_.post([this, call, reply = std::move(reply)]() mutable { finish(call, std::move(reply)); });
    return;
  }
  // The transport completes on its own thread; the reply crosses to the game
  // thread through the inbox, and is dropped there if the client is gone.
  http->send(std::move(request), [this, call, post = core_.post](HttpResponse reply) {
    post([this, call, reply = std::move(reply)]() mutable { finish(call, std::move(reply)); });
  });
}

void Rest::finish(const std::shared_ptr<Call>& call, HttpResponse reply) {
  Response response;
  response.status = reply.status;
  response.text = std::move(reply.body);
  if (!response.text.empty()) {
    auto parsed = parse(response.text);
    if (!parsed.is_discarded()) response.body = std::move(parsed);
  }
  if (response.status == 0) {
    response.error = reply.error.empty() ? "no reply" : std::move(reply.error);
  } else if (response.status < 200 || response.status >= 300) {
    auto code = response.code();
    response.error = code.empty() ? "http_" + std::to_string(response.status) : code;
  }

  if (response.status == 401 && call->authenticated && !call->retried) {
    call->retried = true;
    core_.auth.refresh_then([this, call, response](bool refreshed) {
      if (refreshed) {
        start(call);
      } else if (call->done) {
        call->done(response);
      }
    });
    return;
  }
  if (call->done) call->done(response);
}

}  // namespace gamend
