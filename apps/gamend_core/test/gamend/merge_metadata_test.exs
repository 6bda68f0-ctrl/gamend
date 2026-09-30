defmodule Gamend.MergeMetadataTest do
  @moduledoc """
  Merging metadata instead of replacing it.

  `metadata` is one shared map, so the replace-style update wipes keys belonging
  to code the caller has never heard of — a game writing its match state would
  delete a plugin's configuration. These pin the merge, and that concurrent
  merges do not lose each other.
  """
  use Gamend.DataCase, async: false

  alias Gamend.Accounts
  alias Gamend.AccountsFixtures
  alias Gamend.Lobbies

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, lobby} = Lobbies.create_lobby(%{"title" => "Merge", "host_id" => user.id})
    %{user: user, lobby: lobby}
  end

  describe "Lobbies.merge_metadata/2" do
    test "keeps keys it does not mention", %{lobby: lobby} do
      {:ok, lobby} = Lobbies.merge_metadata(lobby, %{"plugin" => %{"enabled" => true}})
      {:ok, lobby} = Lobbies.merge_metadata(lobby, %{"match" => %{"round" => 1}})

      assert lobby.metadata["plugin"] == %{"enabled" => true}
      assert lobby.metadata["match"] == %{"round" => 1}
    end

    test "the replace-style update still replaces", %{lobby: lobby} do
      {:ok, lobby} = Lobbies.merge_metadata(lobby, %{"plugin" => %{"enabled" => true}})
      {:ok, lobby} = Lobbies.update_lobby(lobby, %{metadata: %{"match" => %{"round" => 1}}})

      refute Map.has_key?(lobby.metadata, "plugin")
    end

    test "overwrites a key it does mention", %{lobby: lobby} do
      {:ok, lobby} = Lobbies.merge_metadata(lobby, %{"a" => 1, "b" => 2})
      {:ok, lobby} = Lobbies.merge_metadata(lobby, %{"a" => 99})

      assert lobby.metadata == %{"a" => 99, "b" => 2}
    end

    test "atom keys land as strings", %{lobby: lobby} do
      {:ok, lobby} = Lobbies.merge_metadata(lobby, %{atom_key: "v"})

      assert lobby.metadata["atom_key"] == "v"
    end

    test "concurrent merges do not lose each other", %{lobby: lobby} do
      tasks =
        for i <- 1..10 do
          Task.async(fn -> Lobbies.merge_metadata(lobby, %{"key_#{i}" => i}) end)
        end

      Enum.each(tasks, &Task.await(&1, 30_000))

      metadata = Lobbies.get_lobby(lobby.id).metadata

      for i <- 1..10 do
        assert metadata["key_#{i}"] == i, "key_#{i} was lost"
      end
    end

    test "a deleted lobby is not found", %{lobby: lobby} do
      {:ok, _} = Lobbies.delete_lobby(lobby)

      assert {:error, :not_found} = Lobbies.merge_metadata(lobby, %{"a" => 1})
    end
  end

  describe "Accounts.merge_metadata/2" do
    test "keeps keys it does not mention", %{user: user} do
      {:ok, user} = Accounts.merge_metadata(user, %{"prefs" => %{"theme" => "dark"}})
      {:ok, user} = Accounts.merge_metadata(user, %{"plugin" => %{"level" => 3}})

      assert user.metadata["prefs"] == %{"theme" => "dark"}
      assert user.metadata["plugin"] == %{"level" => 3}
    end

    test "concurrent merges do not lose each other", %{user: user} do
      tasks =
        for i <- 1..10 do
          Task.async(fn -> Accounts.merge_metadata(user, %{"key_#{i}" => i}) end)
        end

      Enum.each(tasks, &Task.await(&1, 30_000))

      metadata = Accounts.get_user(user.id).metadata

      for i <- 1..10 do
        assert metadata["key_#{i}"] == i, "key_#{i} was lost"
      end
    end
  end
end
