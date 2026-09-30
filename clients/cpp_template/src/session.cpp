#include "gamend/session.hpp"

namespace gamend {

json Session::to_json() const {
  return json{
      {"access_token", access_token},
      {"refresh_token", refresh_token},
      {"user_id", user_id},
      {"username", username},
      {"display_name", display_name},
      {"expires_in", expires_in},
      {"expires_at", expires_at},
  };
}

std::optional<Session> Session::from_json(const json& value, std::int64_t now) {
  Session session;
  session.access_token = text(value, "access_token");
  if (session.access_token.empty()) return std::nullopt;
  session.refresh_token = text(value, "refresh_token");
  session.user_id = text(value, "user_id");
  session.username = text(value, "username");
  session.display_name = text(value, "display_name");
  session.expires_in = number(value, "expires_in");
  session.expires_at = number(value, "expires_at");
  if (session.expires_at == 0 && session.expires_in > 0 && now > 0) {
    session.expires_at = now + session.expires_in;
  }
  return session;
}

}  // namespace gamend
