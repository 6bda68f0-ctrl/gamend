defmodule GamendWeb.Api.V1.KvControllerTest do
  use GamendWeb.ConnCase

  alias Gamend.AccountsFixtures
  alias Gamend.KV
  alias GamendWeb.Auth.Guardian

  setup do
    orig = Application.get_env(:gamend_core, :hooks_module)
    Application.put_env(:gamend_core, :hooks_module, Gamend.Hooks.Default)
    on_exit(fn -> Application.put_env(:gamend_core, :hooks_module, orig) end)
    :ok
  end

  test "GET /api/v1/kv/:key requires auth and returns public global value", %{conn: conn} do
    KV.put("global_foo", %{"a" => 1}, %{})

    resp_unauth = get(conn, "/api/v1/kv/global_foo")
    assert resp_unauth.status == 401

    user = non_admin_fixture()
    resp = conn |> auth_conn(user) |> get("/api/v1/kv/global_foo") |> json_response(200)
    assert resp["data"]["data"] == %{"a" => 1}
    assert %{"key" => "global_foo", "user_id" => "", "lobby_id" => ""} = resp["data"]
  end

  test "GET /api/v1/kv/:key answers not_found for a missing key", %{conn: conn} do
    resp =
      conn
      |> auth_conn(non_admin_fixture())
      |> get("/api/v1/kv/no_such_key")
      |> json_response(404)

    assert resp["error"] == "not_found"
  end

  test "owner_only allows only requested user owner", %{conn: conn} do
    install_kv_access(:owner_only)

    owner = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()
    admin = admin_fixture()
    {:ok, _entry} = KV.put("user_key", %{"v" => 2}, %{}, user_id: owner.id)

    resp =
      conn
      |> auth_conn(owner)
      |> get("/api/v1/kv/user_key?user_id=#{owner.id}")
      |> json_response(200)

    assert resp["data"]["data"] == %{"v" => 2}

    assert conn
           |> auth_conn(other)
           |> get("/api/v1/kv/user_key?user_id=#{owner.id}")
           |> response(403)

    assert conn
           |> auth_conn(admin)
           |> get("/api/v1/kv/user_key?user_id=#{owner.id}")
           |> response(403)
  end

  test "lobby_members_only allows only requested lobby members", %{conn: conn} do
    install_kv_access(:lobby_members_only)

    host = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()
    outsider = AccountsFixtures.user_fixture()
    {:ok, lobby} = Gamend.Lobbies.create_lobby(%{title: "members-kv-room", host_id: host.id})
    {:ok, member} = Gamend.Lobbies.join_lobby(member, lobby)
    {:ok, _entry} = KV.put("lobby_key", %{"v" => 3}, %{}, lobby_id: lobby.id)

    resp =
      conn
      |> auth_conn(member)
      |> get("/api/v1/kv/lobby_key?lobby_id=#{lobby.id}")
      |> json_response(200)

    assert resp["data"]["data"] == %{"v" => 3}

    assert conn
           |> auth_conn(outsider)
           |> get("/api/v1/kv/lobby_key?lobby_id=#{lobby.id}")
           |> response(403)
  end

  test "owner_or_lobby_member allows owner or requested lobby member", %{conn: conn} do
    install_kv_access(:owner_or_lobby_member)

    owner = AccountsFixtures.user_fixture()
    host = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()
    outsider = AccountsFixtures.user_fixture()
    {:ok, lobby} = Gamend.Lobbies.create_lobby(%{title: "mixed-kv-room", host_id: host.id})
    {:ok, member} = Gamend.Lobbies.join_lobby(member, lobby)

    {:ok, _entry} = KV.put("shared_key", %{"scope" => "user"}, %{}, user_id: owner.id)
    {:ok, _entry} = KV.put("shared_key", %{"scope" => "lobby"}, %{}, lobby_id: lobby.id)

    owner_resp =
      conn
      |> auth_conn(owner)
      |> get("/api/v1/kv/shared_key?user_id=#{owner.id}")
      |> json_response(200)

    member_resp =
      conn
      |> auth_conn(member)
      |> get("/api/v1/kv/shared_key?lobby_id=#{lobby.id}")
      |> json_response(200)

    assert owner_resp["data"]["data"] == %{"scope" => "user"}
    assert member_resp["data"]["data"] == %{"scope" => "lobby"}

    assert conn
           |> auth_conn(outsider)
           |> get("/api/v1/kv/shared_key?user_id=#{owner.id}")
           |> response(403)

    assert conn
           |> auth_conn(outsider)
           |> get("/api/v1/kv/shared_key?lobby_id=#{lobby.id}")
           |> response(403)
  end

  test "admin_only allows only admins", %{conn: conn} do
    install_kv_access(:admin_only)

    user = non_admin_fixture()
    admin = admin_fixture()
    KV.put("admin_key", %{"v" => 4}, %{})

    assert conn |> auth_conn(user) |> get("/api/v1/kv/admin_key") |> response(403)

    resp = conn |> auth_conn(admin) |> get("/api/v1/kv/admin_key") |> json_response(200)
    assert resp["data"]["data"] == %{"v" => 4}
  end

  test "server_only blocks all client KV reads", %{conn: conn} do
    install_kv_access(:server_only)

    user = AccountsFixtures.user_fixture()
    admin = admin_fixture()
    KV.put("server_key", %{"v" => 5}, %{})

    assert conn |> auth_conn(user) |> get("/api/v1/kv/server_key") |> response(403)
    assert conn |> auth_conn(admin) |> get("/api/v1/kv/server_key") |> response(403)
  end

  defp install_kv_access(access) do
    mod_name = String.to_atom("TestHooksKvAccess_#{System.unique_integer([:positive])}")
    access = Macro.escape(access)

    Module.create(
      mod_name,
      quote do
        def before_kv_get(_key, _opts), do: unquote(access)
      end,
      Macro.Env.location(__ENV__)
    )

    Application.put_env(:gamend_core, :hooks_module, mod_name)
  end

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp admin_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin} = Gamend.Accounts.update_user(user, %{is_admin: true})
    admin
  end

  defp non_admin_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, user} = Gamend.Accounts.update_user(user, %{is_admin: false})
    user
  end
end
