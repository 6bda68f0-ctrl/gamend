defmodule Gamend.AppleCacheTest do
  use ExUnit.Case, async: true

  @key_id "KEY123"
  @team_id "TEAM123"

  setup do
    # Ensure a clean ETS table for each test
    case :ets.info(:apple_oauth_cache) do
      :undefined -> :ok
      _ -> :ets.delete(:apple_oauth_cache)
    end

    for {k, v} <- [apple_key_id: @key_id, apple_team_id: @team_id] do
      old = Gamend.SettingsHelpers.get(:gamend_core, Gamend.OAuth.Providers, k)
      Gamend.SettingsHelpers.put(:gamend_core, Gamend.OAuth.Providers, k, v)

      on_exit(fn ->
        if old,
          do: Gamend.SettingsHelpers.put(:gamend_core, Gamend.OAuth.Providers, k, old),
          else: Gamend.SettingsHelpers.delete(:gamend_core, Gamend.OAuth.Providers, k)
      end)
    end

    :ok
  end

  defp cache(client_id, key_id, team_id, secret, expires_in) do
    case :ets.info(:apple_oauth_cache) do
      :undefined -> :ets.new(:apple_oauth_cache, [:named_table, :public, :set])
      _ -> :ok
    end

    expires_at = System.system_time(:second) + expires_in

    :ets.insert(
      :apple_oauth_cache,
      {{:client_secret, client_id, key_id, team_id}, secret, expires_at}
    )
  end

  test "client_secret returns cached value when present and not expired" do
    secret = "cached-secret-#{System.unique_integer([:positive])}"
    client_id = "com.example.web"
    cache(client_id, @key_id, @team_id, secret, 10_000)

    assert secret == Gamend.Apple.client_secret(client_id: client_id)
  end

  # A rotated .p8 key must not keep serving the secret signed by the old one —
  # Apple answers those with a bare `invalid_client` for the rest of the TTL.
  test "a secret cached under different credentials is not reused" do
    client_id = "com.example.web"
    cache(client_id, "OLDKEY", "OLDTEAM", "stale-secret", 10_000)

    Gamend.SettingsHelpers.delete(:gamend_core, Gamend.OAuth.Providers, :apple_private_key)

    assert_raise RuntimeError, ~r/PRIVATE_KEY/, fn ->
      Gamend.Apple.client_secret(client_id: client_id)
    end
  end

  test "client_secret raises when private key missing and cache empty" do
    # ensure no cache and no APPLE_PRIVATE_KEY env var
    case :ets.info(:apple_oauth_cache) do
      :undefined -> :ok
      _ -> :ets.delete(:apple_oauth_cache)
    end

    old_client_id =
      Gamend.SettingsHelpers.get(
        :gamend_core,
        Gamend.OAuth.Providers,
        :apple_client_id
      )

    Gamend.SettingsHelpers.put(
      :gamend_core,
      Gamend.OAuth.Providers,
      :apple_client_id,
      "com.example.web"
    )

    old =
      Gamend.SettingsHelpers.get(
        :gamend_core,
        Gamend.OAuth.Providers,
        :apple_private_key
      )

    Gamend.SettingsHelpers.delete(
      :gamend_core,
      Gamend.OAuth.Providers,
      :apple_private_key
    )

    # Restore rather than delete: test_helper.exs sets a baseline
    # apple_client_id that later tests rely on.
    on_exit(fn ->
      if old_client_id do
        Gamend.SettingsHelpers.put(
          :gamend_core,
          Gamend.OAuth.Providers,
          :apple_client_id,
          old_client_id
        )
      else
        Gamend.SettingsHelpers.delete(
          :gamend_core,
          Gamend.OAuth.Providers,
          :apple_client_id
        )
      end

      if old,
        do:
          Gamend.SettingsHelpers.put(
            :gamend_core,
            Gamend.OAuth.Providers,
            :apple_private_key,
            old
          )
    end)

    assert_raise RuntimeError, fn -> Gamend.Apple.client_secret() end
  end

  test "get_client_secret_from_cache returns error when cache is expired" do
    # Create an expired cache entry
    cache("com.example.web", @key_id, @team_id, "expired-secret", -100)

    # Calling client_secret should attempt to regenerate (and fail without env vars)
    old =
      Gamend.SettingsHelpers.get(
        :gamend_core,
        Gamend.OAuth.Providers,
        :apple_private_key
      )

    Gamend.SettingsHelpers.delete(
      :gamend_core,
      Gamend.OAuth.Providers,
      :apple_private_key
    )

    on_exit(fn ->
      if old,
        do:
          Gamend.SettingsHelpers.put(
            :gamend_core,
            Gamend.OAuth.Providers,
            :apple_private_key,
            old
          )
    end)

    # Should raise because cache is expired and env var is missing
    assert_raise RuntimeError, fn ->
      Gamend.Apple.client_secret(client_id: "com.example.web")
    end
  end
end
