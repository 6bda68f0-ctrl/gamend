#include <doctest/doctest.h>

#include "gamend/json.hpp"
#include "query.hpp"

using gamend::json;
using gamend::detail::escape;
using gamend::detail::given;
using gamend::detail::query;

TEST_CASE("escape leaves the unreserved set alone and encodes the rest") {
  CHECK(escape("AZaz09-_.~") == "AZaz09-_.~");
  CHECK(escape("a b&c=d/e?f#g+h") == "a%20b%26c%3Dd%2Fe%3Ff%23g%2Bh");
  CHECK(escape("\xC3\xA9") == "%C3%A9");
  CHECK(escape("") == "");
}

TEST_CASE("given: a key with a value, never null, never on a non-object") {
  json table = {{"a", 1}, {"b", nullptr}, {"c", ""}};
  CHECK(given(table, "a"));
  CHECK_FALSE(given(table, "b"));
  CHECK(given(table, "c"));
  CHECK_FALSE(given(table, "d"));
  CHECK_FALSE(given(json(), "a"));
  CHECK_FALSE(given(json::array({1}), "a"));
}

TEST_CASE("query keeps the declared order and skips what is not given") {
  json options = {{"page", 2}, {"title", "a b"}, {"is_hidden", false}, {"min_users", nullptr},
                  {"unknown", "x"}};
  CHECK(query(options, {"title", "is_hidden", "min_users", "page", "page_size"}) ==
        "?title=a%20b&is_hidden=false&page=2");
  CHECK(query(json::object(), {"page"}) == "");
  CHECK(query(json(), {"page"}) == "");
  CHECK(query(json{{"ratio", 1.5}}, {"ratio"}) == "?ratio=1.5");
}
