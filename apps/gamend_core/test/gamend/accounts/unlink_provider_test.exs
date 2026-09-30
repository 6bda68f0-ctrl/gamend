defmodule Gamend.Accounts.UnlinkProviderTest do
  use Gamend.DataCase, async: true

  alias Gamend.Accounts
  import Gamend.AccountsFixtures

  describe "unlink_provider/2" do
    test "successfully unlinks when multiple providers present" do
      user = user_fixture(%{email: unique_user_email()})

      # attach two provider ids
      user =
        Gamend.Repo.update!(
          Ecto.Changeset.change(user, %{
            discord_id: "d1",
            google_id: "g1",
            profile_url: "https://cdn.discordapp.com/avatars/d1/a_abc.gif"
          })
        )

      assert {:ok, user} = Accounts.unlink_provider(user, :discord)
      assert user.discord_id == nil
      assert user.google_id == "g1"
    end

    test "prevents unlinking last remaining social provider" do
      user = user_fixture(%{email: unique_user_email()})

      # only discord linked
      user = Gamend.Repo.update!(Ecto.Changeset.change(user, %{discord_id: "d1"}))

      assert {:error, :last_provider} = Accounts.unlink_provider(user, :discord)
    end
  end
end
