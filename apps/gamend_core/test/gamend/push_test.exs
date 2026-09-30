defmodule Gamend.PushTest do
  use Gamend.DataCase, async: true

  alias Gamend.AccountsFixtures
  alias Gamend.Push

  defp register!(user, attrs) do
    {:ok, token} =
      Push.register_token(
        user.id,
        Map.merge(%{"token" => "tok-#{System.unique_integer([:positive])}"}, attrs)
      )

    token
  end

  describe "register_token/2" do
    test "registers a device and defaults the provider from the platform" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, ios} =
               Push.register_token(user.id, %{"token" => "apns-1", "platform" => "ios"})

      assert ios.provider == "apns"

      assert {:ok, android} =
               Push.register_token(user.id, %{"token" => "fcm-1", "platform" => "android"})

      assert android.provider == "fcm"

      assert {:ok, relay} =
               Push.register_token(user.id, %{
                 "token" => "fcm-2",
                 "platform" => "ios",
                 "provider" => "fcm"
               })

      assert relay.provider == "fcm"
    end

    test "rejects unknown platform and provider" do
      user = AccountsFixtures.user_fixture()

      assert {:error, %Ecto.Changeset{} = cs} =
               Push.register_token(user.id, %{"token" => "t", "platform" => "windows"})

      assert %{platform: _} = errors_on(cs)

      assert {:error, %Ecto.Changeset{} = cs} =
               Push.register_token(user.id, %{
                 "token" => "t",
                 "platform" => "ios",
                 "provider" => "carrier-pigeon"
               })

      assert %{provider: _} = errors_on(cs)
    end

    test "re-registering a device_id rotates its token in place" do
      user = AccountsFixtures.user_fixture()

      first = register!(user, %{"platform" => "android", "device_id" => "dev-1"})
      second = register!(user, %{"platform" => "android", "device_id" => "dev-1"})

      assert second.id == first.id
      refute second.token == first.token
      assert Push.count_tokens(user.id) == 1
    end

    # Account switching on one device: the claimer sends the same `device_id`
    # the row already carries, which is the evidence they are on that device.
    test "re-registering an existing token claims it for the new user" do
      old_owner = AccountsFixtures.user_fixture()
      new_owner = AccountsFixtures.user_fixture()
      device_id = "device-#{System.unique_integer([:positive])}"

      token = register!(old_owner, %{"platform" => "android", "device_id" => device_id})

      assert {:ok, claimed} =
               Push.register_token(new_owner.id, %{
                 "token" => token.token,
                 "platform" => "android",
                 "device_id" => device_id
               })

      assert claimed.id == token.id
      assert claimed.user_id == new_owner.id
      assert Push.list_tokens(old_owner.id) == []
      refute Push.user_has_live_tokens?(old_owner.id)
    end

    # A token string on its own is not proof of anything: it turns up in crash
    # reports, shared devices and pasted logs. Honouring a bare claim let an
    # attacker silently take over the victim's notifications — the victim stops
    # receiving their own, and pushes meant for the attacker are delivered to
    # the victim's physical device.
    test "refuses to claim another user's token without device proof" do
      old_owner = AccountsFixtures.user_fixture()
      attacker = AccountsFixtures.user_fixture()

      token = register!(old_owner, %{"platform" => "android", "device_id" => "the-real-device"})

      assert {:error, :token_owned_by_another_user} =
               Push.register_token(attacker.id, %{
                 "token" => token.token,
                 "platform" => "android"
               })

      assert {:error, :token_owned_by_another_user} =
               Push.register_token(attacker.id, %{
                 "token" => token.token,
                 "platform" => "android",
                 "device_id" => "a-different-device"
               })

      assert [kept] = Push.live_tokens(old_owner.id)
      assert kept.id == token.id
    end

    test "re-registering re-enables a disabled token" do
      user = AccountsFixtures.user_fixture()
      token = register!(user, %{"platform" => "android", "device_id" => "dev-1"})

      :ok = Push.disable_token(token.token)
      refute Push.user_has_live_tokens?(user.id)

      reregistered = register!(user, %{"platform" => "android", "device_id" => "dev-1"})
      assert reregistered.disabled_at == nil
      assert Push.user_has_live_tokens?(user.id)
    end

    test "claiming another user's token respects the claimer's capacity" do
      victim = AccountsFixtures.user_fixture()
      claimer = AccountsFixtures.user_fixture()
      max = Gamend.Limits.get(:max_push_tokens_per_user)

      device_id = "shared-device-#{System.unique_integer([:positive])}"
      stolen = register!(victim, %{"platform" => "android", "device_id" => device_id})
      for _ <- 1..max, do: register!(claimer, %{"platform" => "android"})

      assert {:error, :too_many_tokens} =
               Push.register_token(claimer.id, %{
                 "token" => stolen.token,
                 "platform" => "android",
                 "device_id" => device_id
               })

      # The victim keeps the row when the claim is rejected.
      assert [_] = Push.live_tokens(victim.id)
    end

    test "a blank provider falls back to the platform default" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, token} =
               Push.register_token(user.id, %{
                 "token" => "blank-provider",
                 "platform" => "ios",
                 "provider" => ""
               })

      assert token.provider == "apns"
    end

    test "enforces max_push_tokens_per_user counting live tokens only" do
      user = AccountsFixtures.user_fixture()
      max = Gamend.Limits.get(:max_push_tokens_per_user)

      tokens = for _ <- 1..max, do: register!(user, %{"platform" => "android"})

      assert {:error, :too_many_tokens} =
               Push.register_token(user.id, %{"token" => "one-too-many", "platform" => "android"})

      # A disabled slot frees capacity.
      :ok = Push.disable_token(hd(tokens).token)

      assert {:ok, _} =
               Push.register_token(user.id, %{"token" => "fits-now", "platform" => "android"})
    end
  end

  describe "removal and disabling" do
    test "delete_token/2 removes only the owner's row" do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      token = register!(user, %{"platform" => "ios"})

      assert {:error, :not_found} = Push.delete_token(other.id, token.id)
      assert {:ok, _} = Push.delete_token(user.id, token.id)
      assert {:error, :not_found} = Push.delete_token(user.id, token.id)
      assert Push.count_tokens(user.id) == 0
    end

    test "unregister_token/2 removes by raw token value" do
      user = AccountsFixtures.user_fixture()
      token = register!(user, %{"platform" => "web"})

      assert {:ok, _} = Push.unregister_token(user.id, token.token)
      assert {:error, :not_found} = Push.unregister_token(user.id, token.token)
    end

    test "disable_token/1 keeps the row but removes it from the live set" do
      user = AccountsFixtures.user_fixture()
      token = register!(user, %{"platform" => "android"})

      :ok = Push.disable_token(token.token)

      assert Push.count_tokens(user.id) == 1
      assert Push.live_tokens(user.id) == []
      refute Push.user_has_live_tokens?(user.id)
    end

    test "mark_token_used/1 bumps last_used_at" do
      user = AccountsFixtures.user_fixture()
      token = register!(user, %{"platform" => "android"})
      assert token.last_used_at == nil

      :ok = Push.mark_token_used(token.token)

      assert [%{last_used_at: %DateTime{}}] = Push.live_tokens(user.id)
    end
  end

  describe "queries" do
    test "list_tokens/2 paginates newest-first with count_tokens/1" do
      user = AccountsFixtures.user_fixture()
      for i <- 1..3, do: register!(user, %{"platform" => "android", "device_id" => "d#{i}"})

      assert Push.count_tokens(user.id) == 3
      assert [_, _] = Push.list_tokens(user.id, page: 1, page_size: 2)
      assert [_] = Push.list_tokens(user.id, page: 2, page_size: 2)
    end

    test "list_all_tokens/2 filters by platform, provider, status and user" do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()

      ios = register!(user, %{"platform" => "ios"})
      _android = register!(user, %{"platform" => "android"})
      _other_web = register!(other, %{"platform" => "web"})
      :ok = Push.disable_token(ios.token)

      assert Push.count_all_tokens(%{user_id: user.id}) == 2
      assert [%{platform: "ios"}] = Push.list_all_tokens(%{platform: "ios"})
      assert Push.count_all_tokens(%{user_id: user.id, status: "disabled"}) == 1
      assert Push.count_all_tokens(%{user_id: user.id, status: "live"}) == 1
      assert [%{provider: "apns"}] = Push.list_all_tokens(%{provider: "apns"})

      # Admin listing preloads user names.
      assert [%{user: %{id: _}} | _] = Push.list_all_tokens()

      # The filter box is the same user search as the other admin pages: an id,
      # or part of a name. Text that is neither finds nothing and never crashes.
      assert Push.count_all_tokens(%{user_id: user.username}) == 2
      assert Push.count_all_tokens(%{user_id: "not-a-uuid"}) == 0
      assert Push.count_all_tokens(%{user_id: ""}) == Push.count_all_tokens(%{})
    end

    test "token_stats/0 aggregates totals and live splits" do
      user = AccountsFixtures.user_fixture()

      ios = register!(user, %{"platform" => "ios"})
      _android = register!(user, %{"platform" => "android"})
      :ok = Push.disable_token(ios.token)

      stats = Push.token_stats()

      assert stats.total >= 2
      assert stats.disabled >= 1
      assert stats.live == stats.total - stats.disabled
      assert Map.has_key?(stats.by_platform, "android")
      # Disabled tokens are excluded from the live splits.
      assert is_map(stats.by_provider)
    end
  end
end
