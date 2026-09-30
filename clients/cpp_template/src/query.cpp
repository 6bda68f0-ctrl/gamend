#include "query.hpp"

namespace gamend::detail {

std::string escape(std::string_view text) {
  static constexpr char hex[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(text.size());
  for (char c : text) {
    auto byte = static_cast<unsigned char>(c);
    bool unreserved = (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
                      (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' ||
                      byte == '.' || byte == '~';
    if (unreserved) {
      out += c;
    } else {
      out += '%';
      out += hex[byte >> 4];
      out += hex[byte & 0x0F];
    }
  }
  return out;
}

bool given(const json& table, std::string_view key) {
  if (!table.is_object()) return false;
  auto it = table.find(key);
  return it != table.end() && !it->is_null();
}

namespace {

std::string text_of(const json& value) {
  if (value.is_string()) return value.get<std::string>();
  if (value.is_boolean()) return value.get<bool>() ? "true" : "false";
  return dump(value);
}

}  // namespace

std::string query(const json& options, std::initializer_list<std::string_view> allowed) {
  std::string out;
  for (auto key : allowed) {
    if (!given(options, key)) continue;
    out += out.empty() ? '?' : '&';
    out += escape(key);
    out += '=';
    out += escape(text_of(*options.find(key)));
  }
  return out;
}

}  // namespace gamend::detail
