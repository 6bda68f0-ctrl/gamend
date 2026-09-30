defmodule GamendWeb.Api.V1.Admin.UserAdminControllerTest do
  # Admin users and sessions. Every answer here also passes
  # `GamendWeb.ResponseContract`.
  use GamendWeb.ConnCase, async: false

  import Ecto.Query

  alias Gamend.Accounts
  alias Gamend.AccountsFixtures
  alias GamendWeb.Auth.Guardian

  setup %{conn: conn} do
    {:ok, admin} = Accounts.update_user(AccountsFixtures.user_fixture(), %{is_admin: true})
    {:ok, token, _} = Guardian.encode_and_sign(admin)
    %{admin: admin, admin_conn: put_req_header(conn, "authorization", "Bearer " <> token)}
  end

  describe "users" do
    test "update answers the whole admin view of the user", ctx do
      user = AccountsFixtures.user_fixture()

      body =
        ctx.admin_conn
        |> patch("/api/v1/admin/users/#{user.id}", %{display_name: "Renamed", is_activated: true})
        |> json_response(200)

      assert %{"display_name" => "Renamed", "lobby_id" => "", "party_id" => ""} = body["data"]
    end

    test "the last admin cannot be demoted", ctx do
      # Leave this test's admin as the only one.
      Gamend.Repo.update_all(
        from(u in Gamend.Accounts.User, where: u.is_admin and u.id != ^ctx.admin.id),
        set: [is_admin: false]
      )

      resp =
        ctx.admin_conn
        |> patch("/api/v1/admin/users/#{ctx.admin.id}", %{is_admin: false})
        |> json_response(403)

      assert resp["error"] == "last_admin"
    end

    test "delete", ctx do
      user = AccountsFixtures.user_fixture()

      assert ctx.admin_conn |> delete("/api/v1/admin/users/#{user.id}") |> json_response(200) ==
               %{"ok" => true}

      resp = ctx.admin_conn |> delete("/api/v1/admin/users/#{user.id}") |> json_response(404)
      assert resp["error"] == "not_found"
    end
  end

  describe "sessions" do
    test "list, delete one, and revoke a user's", ctx do
      user = AccountsFixtures.user_fixture()
      _ = Accounts.generate_user_session_token(user)
      _ = Accounts.generate_user_session_token(user)

      body =
        ctx.admin_conn |> get("/api/v1/admin/sessions", %{page_size: 1}) |> json_response(200)

      assert [%{"id" => id, "context" => "session", "user_email" => _}] = body["data"]
      assert body["meta"]["total_count"] >= 2

      assert ctx.admin_conn |> delete("/api/v1/admin/sessions/#{id}") |> json_response(200) ==
               %{"ok" => true}

      assert ctx.admin_conn
             |> delete("/api/v1/admin/users/#{user.id}/sessions")
             |> json_response(200) == %{"ok" => true}
    end
  end
end
