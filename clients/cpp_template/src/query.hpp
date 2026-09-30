// What every generated call needs: an escaped path segment, a query string,
// and the required-field check.
#pragma once

#include <initializer_list>
#include <string>
#include <string_view>

#include "gamend/json.hpp"

namespace gamend::detail {

/// Percent-encoding of everything but RFC 3986's unreserved characters, so a
/// value is safe in a path segment and in a query alike.
std::string escape(std::string_view text);

/// Whether `table` carries `key` with a value. A key set to null is absent:
/// the server would refuse it, and refusing here names the field instead.
bool given(const json& table, std::string_view key);

/// `?a=1&b=2` for the keys an operation declares, in the order it declares
/// them, skipping the ones `options` leaves out. Empty when none are given.
/// A bool is `true`/`false`, as the server reads it.
std::string query(const json& options, std::initializer_list<std::string_view> allowed);

}  // namespace gamend::detail
