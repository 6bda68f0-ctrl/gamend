#include <doctest/doctest.h>

#include "gamend/events.hpp"

namespace events = gamend::events;

static_assert(events::channel_of("lobby:12") == "lobby");
static_assert(events::channel_of("lobbies") == "lobbies");
static_assert(events::signal_of("lobby:12", "updated") == events::LOBBY_UPDATED);

TEST_CASE("a socket message is named by its channel and event") {
  CHECK(events::signal_of("user:u1", "updated") == events::USER_UPDATED);
  CHECK(events::signal_of("lobby:l1", "user_joined") == events::LOBBY_MEMBER_JOINED);
  CHECK(events::signal_of("lobby:l1", "no_such_event") == events::MESSAGE);
  CHECK(events::signal_of("nowhere:1", "updated") == events::MESSAGE);
}

TEST_CASE("every row names a signal that has a constant") {
  for (const auto& row : events::TABLE) {
    CHECK_FALSE(row.channel.empty());
    CHECK_FALSE(row.event.empty());
    CHECK_FALSE(row.signal.empty());
  }
}
