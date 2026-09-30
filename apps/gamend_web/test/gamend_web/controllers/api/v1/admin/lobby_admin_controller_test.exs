defmodule GamendWeb.Api.V1.Admin.LobbyAdminControllerTest do
  use GamendWeb.ConnCase, async: false

  alias Gamend.Accounts
  alias Gamend.AccountsFixtures
  alias Gamend.Lobbies
  alias GamendWeb.Auth.Guardian

  defp bearer_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, admin} = Accounts.update_user(user, %{is_admin: true})

    %{admin_conn: bearer_conn(conn, admin)}
  end

  test "PATCH /admin/lobbies/:id updates a hostless lobby players may not touch", %{
    admin_conn: admin_conn
  } do
    {:ok, lobby} = Lobbies.create_lobby(%{title: "hostless-admin-room", hostless: true})

    conn =
      patch(admin_conn, "/api/v1/admin/lobbies/#{lobby.id}", %{
        "title" => "Admin Renamed",
        "metadata" => %{"seed" => 7}
      })

    assert %{"data" => data} = json_response(conn, 200)
    assert data["title"] == "Admin Renamed"

    reloaded = Lobbies.get_lobby(lobby.id)
    assert reloaded.metadata == %{"seed" => 7}
  end

  test "PATCH /admin/lobbies/:id updates a lobby the admin does not host", %{
    admin_conn: admin_conn
  } do
    host = AccountsFixtures.user_fixture()
    {:ok, lobby} = Lobbies.create_lobby(%{title: "hosted-admin-room", host_id: host.id})

    conn = patch(admin_conn, "/api/v1/admin/lobbies/#{lobby.id}", %{"is_locked" => true})

    assert %{"data" => data} = json_response(conn, 200)
    assert data["is_locked"] == true
  end

  test "GET /admin/lobbies pages every lobby, hidden ones included", %{admin_conn: admin_conn} do
    {:ok, hidden} =
      Lobbies.create_lobby(%{title: "hidden-admin-room", hostless: true, is_hidden: true})

    body = admin_conn |> get("/api/v1/admin/lobbies", %{is_hidden: true}) |> json_response(200)
    assert Enum.any?(body["data"], &(&1["id"] == hidden.id))
    assert body["meta"]["total_count"] >= 1
  end

  test "DELETE /admin/lobbies/:id", %{admin_conn: admin_conn} do
    {:ok, lobby} = Lobbies.create_lobby(%{title: "doomed-admin-room", hostless: true})

    assert admin_conn |> delete("/api/v1/admin/lobbies/#{lobby.id}") |> json_response(200) ==
             %{"ok" => true}

    resp = admin_conn |> delete("/api/v1/admin/lobbies/#{lobby.id}") |> json_response(404)
    assert resp["error"] == "not_found"
  end
end
