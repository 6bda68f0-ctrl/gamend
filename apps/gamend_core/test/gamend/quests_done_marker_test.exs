defmodule Gamend.QuestsDoneMarkerTest do
  @moduledoc """
  The done marker is what makes a finished quest cost one cache read instead of
  an advisory lock per event — and it is keyed by `period_key`, which is the
  constant `"static"` for a `repeat` quest. A repeat quest re-arms the instant
  its reward is paid, so a marker on it outlives the state it describes and
  suppresses every later event until its TTL runs out: complete once, then wait
  an hour.

  The app cache runs in bypass mode during tests, so the rest of the quest suite
  cannot see a marker at all. This module points the calling process at a real
  cache instance, which is the only way the marker is observable.
  """
  use Gamend.DataCase

  alias Gamend.AccountsFixtures
  alias Gamend.Cache
  alias Gamend.Quests

  setup do
    name = :"quests_done_marker_#{System.unique_integer([:positive])}"
    l1 = :"#{name}_l1"

    start_supervised!(
      {Cache,
       name: name,
       bypass_mode: false,
       inclusion_policy: :inclusive,
       levels: [{Cache.L1, [name: l1]}]}
    )

    # Process-scoped: every Quests call in this test reads and writes the real
    # instance, while async side effects keep the bypassed default.
    _ = Cache.put_dynamic_cache(name)

    :ok
  end

  # The marker's key shape, rebuilt from outside: whether one was written is the
  # whole difference between a quest that re-arms and one that goes quiet for an
  # hour, and nothing public reports it.
  defp marker(user_id, quest_key, reset) do
    version = Cache.get!({:quests, :version}) || 1
    period_key = Quests.period_key(reset, DateTime.utc_now(:second))

    Cache.get!({:quests, :done, version, user_id, quest_key, period_key})
  end

  test "a repeat quest completes again in the same period after a claim" do
    {:ok, _quest} =
      Quests.create_quest(%{
        key: "endless_marker",
        title: "Endless",
        reset: "repeat",
        objectives: [%{event: "found", target: 1}],
        rewards: [%{type: "currency", code: "gold", amount: 50}]
      })

    user = AccountsFixtures.user_fixture()

    assert {:ok, [first]} = Quests.report_event(user.id, "found")
    assert first.status == "completed"
    assert marker(user.id, "endless_marker", "repeat") == nil

    assert {:ok, %{progress: claimed}} = Quests.claim(user.id, "endless_marker")
    assert claimed.status == "active"

    # Pre-fix this is `{:ok, []}`: the marker from the first completion is still
    # cached under the same "static" period key, so the quest never even gets
    # looked at, and it stays unclaimable until the TTL expires an hour later.
    assert {:ok, [second]} = Quests.report_event(user.id, "found")
    assert second.status == "completed"
    assert {:ok, %{progress: reclaimed}} = Quests.claim(user.id, "endless_marker")
    assert reclaimed.claim_count == 2
  end

  test "a non-repeat quest still stops advancing once it is done" do
    # The marker exists to keep finished quests off the advisory lock; dropping
    # it for repeat quests must not drop it for everything else.
    {:ok, _quest} =
      Quests.create_quest(%{
        key: "once_marker",
        title: "Once",
        reset: "never",
        objectives: [%{event: "found", target: 1}]
      })

    user = AccountsFixtures.user_fixture()

    assert {:ok, [progress]} = Quests.report_event(user.id, "found")
    assert progress.status == "completed"
    assert marker(user.id, "once_marker", "never") == true

    assert {:ok, []} = Quests.report_event(user.id, "found")
  end
end
