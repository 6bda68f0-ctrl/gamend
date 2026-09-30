defmodule Gamend.KVTest do
  use Gamend.DataCase, async: true

  alias Gamend.AccountsFixtures
  alias Gamend.KV

  test "put/get/update and delete" do
    user = AccountsFixtures.user_fixture()

    assert :error == KV.get("my_game:key1")

    assert {:ok, _row} =
             KV.put("my_game:key1", %{"a" => 1}, %{"plugin" => "my_game"})

    assert {:ok, %{value: %{"a" => 1}, metadata: %{"plugin" => "my_game"}}} =
             KV.get("my_game:key1")

    assert {:ok, _row} =
             KV.put("my_game:key1", %{"a" => 2}, %{"plugin" => "my_game"}, user_id: user.id)

    assert {:ok, %{value: %{"a" => 2}, metadata: %{"plugin" => "my_game"}}} =
             KV.get("my_game:key1", user_id: user.id)

    # Deleting the global entry doesn't affect the per-user one.
    assert :ok = KV.delete("my_game:key1")
    assert :error == KV.get("my_game:key1")
    assert {:ok, _} = KV.get("my_game:key1", user_id: user.id)

    assert :ok = KV.delete("my_game:key1", user_id: user.id)
    assert :error == KV.get("my_game:key1", user_id: user.id)
  end

  test "list/count entries supports global_only" do
    user = AccountsFixtures.user_fixture()

    {:ok, _} = KV.put("admin-kv:global-only:global", %{"v" => 1}, %{})
    {:ok, _} = KV.put("admin-kv:global-only:user", %{"v" => 2}, %{}, user_id: user.id)

    global_entries = KV.list_entries(global_only: true, page: 1, page_size: 100)
    global_keys = Enum.map(global_entries, & &1.key)

    assert "admin-kv:global-only:global" in global_keys
    refute "admin-kv:global-only:user" in global_keys
    assert Enum.all?(global_entries, &is_nil(&1.user_id))

    assert KV.count_entries(global_only: true) >= 1
  end
end
