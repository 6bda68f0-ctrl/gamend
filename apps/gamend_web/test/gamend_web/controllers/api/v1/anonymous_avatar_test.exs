defmodule GamendWeb.Api.V1.AnonymousAvatarTest do
  @moduledoc """
  Avatar uploads for device-only accounts.

  An anonymous account is one unauthenticated request away, so letting it write
  to object storage is the cheapest bulk-data vector the server has. Gated off
  by default; these pin both halves of the gate and the escape hatch.
  """
  use GamendWeb.ConnCase, async: false

  alias Gamend.Accounts
  alias Gamend.Storage
  alias GamendWeb.Auth.Guardian

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "rest-of-the-file">>

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "gs_anon_avatar_#{System.unique_integer([:positive])}")
    old_storage = Application.get_env(:gamend_core, Gamend.Storage.Local)
    old_accounts = Application.get_env(:gamend_core, Accounts, [])
    Application.put_env(:gamend_core, Gamend.Storage.Local, dir: dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.put_env(:gamend_core, Accounts, old_accounts)

      if old_storage,
        do: Application.put_env(:gamend_core, Gamend.Storage.Local, old_storage)
    end)

    {:ok, anon} =
      Accounts.find_or_create_from_device("anon-device-#{System.unique_integer([:positive])}")

    %{conn: conn, anon: authed(conn, anon), anon_user: anon}
  end

  defp authed(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp allow_anonymous(value) do
    existing = Application.get_env(:gamend_core, Accounts, [])

    Application.put_env(
      :gamend_core,
      Accounts,
      Keyword.put(existing, :anonymous_can_upload_avatar, value)
    )
  end

  test "an anonymous account cannot get an upload ticket", %{anon: anon} do
    resp = post(anon, "/api/v1/me/avatar/upload_url", %{content_type: "image/png"})

    assert json_response(resp, 403)["error"] == "anonymous_avatar_disabled"
  end

  # Refused at confirm too, not just at the ticket: otherwise a ticket issued
  # while the setting was on, or an upload straight to S3, would still land.
  test "an anonymous account cannot confirm an object it planted", %{
    anon: anon,
    anon_user: user
  } do
    key = Storage.build_key("avatars", user.id, "x.png")
    {:ok, _} = Storage.put(key, @png)

    resp = post(anon, "/api/v1/me/avatar", %{key: key})

    assert json_response(resp, 403)["error"] == "anonymous_avatar_disabled"
  end

  test "the setting re-enables both halves", %{anon: anon, anon_user: user} do
    allow_anonymous(true)

    %{"key" => key, "token" => token} =
      anon
      |> post("/api/v1/me/avatar/upload_url", %{content_type: "image/png"})
      |> json_response(200)
      |> Map.fetch!("data")

    up =
      anon
      |> put_req_header("content-type", "image/png")
      |> put(
        "/api/v1/storage/upload?key=#{URI.encode_www_form(key)}&token=#{URI.encode_www_form(token)}",
        @png
      )

    assert json_response(up, 200) == %{"ok" => true}

    assert json_response(post(anon, "/api/v1/me/avatar", %{key: key}), 200)["data"]["profile_url"] =~
             key

    assert Accounts.get_user(user.id).profile_url =~ key
  end

  test "an account with an identity is unaffected", %{conn: conn} do
    user = Gamend.AccountsFixtures.user_fixture()

    resp =
      conn
      |> authed(user)
      |> post("/api/v1/me/avatar/upload_url", %{content_type: "image/png"})

    assert json_response(resp, 200)["data"]["key"] =~ "avatars/#{user.id}/"
  end
end
