defmodule Gamend.AccountsAvatarCleanupTest do
  @moduledoc """
  Object storage neither cascades nor joins the deletion transaction, so
  deleting an account has to drop its `avatars/<user_id>/` prefix explicitly —
  every object under it, not just the one `profile_url` happens to point at.
  Anything left behind is unreachable personal data that nothing else lists.
  """
  use Gamend.DataCase, async: false

  import Gamend.AccountsFixtures

  alias Gamend.Accounts
  alias Gamend.Storage

  setup do
    dir = Path.join(System.tmp_dir!(), "avatar_cleanup_#{System.unique_integer([:positive])}")
    old = Application.get_env(:gamend_core, Gamend.Storage.Local)
    Application.put_env(:gamend_core, Gamend.Storage.Local, dir: dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if old,
        do: Application.put_env(:gamend_core, Gamend.Storage.Local, old),
        else: Application.delete_env(:gamend_core, Gamend.Storage.Local)
    end)

    :ok
  end

  defp put_avatar(user) do
    key = Storage.build_key("avatars", user.id, "avatar.jpg")
    {:ok, ^key} = Storage.put(key, "BYTES", content_type: "image/jpeg")
    key
  end

  test "deleting an account removes every avatar object it owns" do
    user = user_fixture()
    # A previous upload or mirror copy, plus the current one: pruning keeps only
    # the live key, so both shapes exist in the wild.
    stale_key = put_avatar(user)
    current_key = put_avatar(user)
    {:ok, user} = Accounts.update_user_avatar(user, Storage.url(current_key))

    other = user_fixture()
    other_key = put_avatar(other)

    assert {:ok, _} = Accounts.delete_user(user)

    refute Storage.exists?(current_key), "avatar object outlived the account: #{current_key}"
    refute Storage.exists?(stale_key), "stale avatar object outlived the account: #{stale_key}"
    assert Storage.list_objects(prefix: "avatars/#{user.id}/") == []
    assert Storage.exists?(other_key), "another user's avatar must be untouched"
  end
end
