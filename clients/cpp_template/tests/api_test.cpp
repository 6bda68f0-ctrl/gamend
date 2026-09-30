#include <doctest/doctest.h>

#include "harness.hpp"

using gamend::json;
using harness::FakeHttp;
using harness::Harness;
using harness::Seen;

TEST_CASE("a missing required body field refuses the call, naming the field") {
  Harness h;
  Seen seen;
  h.client->api().authenticate_device_login(json::object(), seen.callback());
  CHECK(h.server->pending() == 0);
  CHECK(seen.calls == 0);
  h.client->poll();
  CHECK(seen.calls == 1);
  CHECK(seen.last.status == 0);
  CHECK(seen.last.error == "authenticate_device_login needs `device_id`");

  // Null is as good as missing.
  h.client->api().authenticate_device_login(json{{"device_id", nullptr}}, seen.callback());
  CHECK(h.server->pending() == 0);
}

TEST_CASE("a missing required query key refuses the call too") {
  Harness h;
  Seen seen;
  h.client->api().admin_storage_admin_delete_storage_object(json::object(), seen.callback());
  h.client->poll();
  CHECK(seen.last.error == "admin_storage_admin_delete_storage_object needs `key`");
  CHECK(h.server->pending() == 0);
}

TEST_CASE("path parameters are escaped") {
  Harness h;
  h.client->api().lobbies_get_lobby("a b/c", nullptr);
  CHECK(h.server->next().url == "http://game.test/api/v1/lobbies/a%20b%2Fc");
}

TEST_CASE("a query goes in the order the operation declares, or not at all") {
  Harness h;
  h.client->api().lobbies_list_lobbies(json{{"page_size", 5}, {"title", "duel"}}, nullptr);
  CHECK(h.server->next().url == "http://game.test/api/v1/lobbies?title=duel&page_size=5");
  h.server->reply(200, "{}");
  h.client->api().lobbies_list_lobbies(nullptr);
  CHECK(h.server->next().url == "http://game.test/api/v1/lobbies");
}

TEST_CASE("an upload sends its bytes as they are") {
  Harness h;
  h.client->api().admin_storage_admin_upload_storage_object(std::string("\x01\x02", 2),
                                                           json{{"key", "maps/a.bin"}}, nullptr);
  auto request = h.server->next();
  CHECK(request.method == "PUT");
  CHECK(request.url == "http://game.test/api/v1/admin/storage/object?key=maps%2Fa.bin");
  CHECK(request.body == std::string("\x01\x02", 2));
  CHECK(FakeHttp::header(request, "content-type") == "application/octet-stream");
}

TEST_CASE("a paged list reads through data() and meta()") {
  Harness h;
  Seen seen;
  h.client->api().lobbies_list_lobbies(seen.callback());
  h.server->reply(200, R"({"data": [{"id": "l1"}], "meta": {"page": 1, "total_count": 1}})");
  h.client->poll();
  REQUIRE(seen.last.data().is_array());
  CHECK(seen.last.data().size() == 1);
  CHECK(gamend::number(seen.last.meta(), "total_count") == 1);
  CHECK(gamend::field(seen.last.body, "missing").is_null());
}
