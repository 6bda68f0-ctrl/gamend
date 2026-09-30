defmodule GamendWeb.Api.V1.Admin.KvAdminControllerTest do
  use GamendWeb.ConnCase, async: false

  alias Gamend.Accounts
  alias Gamend.KV
  alias GamendWeb.Auth.Guardian

  defp bearer_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  setup do
    user = Gamend.AccountsFixtures.user_fixture()
    {:ok, admin} = Accounts.update_user(user, %{is_admin: true})

    {:ok, admin: admin}
  end

  test "PUT /api/v1/admin/kv upserts and returns entry", %{conn: conn, admin: admin} do
    conn = conn |> bearer_conn(admin)

    conn = put(conn, "/api/v1/admin/kv", %{"key" => "test:key", "value" => %{"a" => 1}})
    assert %{"data" => %{"key" => "test:key", "data" => %{"a" => 1}}} = json_response(conn, 200)

    # ensure it exists
    assert {:ok, %{value: %{"a" => 1}}} = KV.get("test:key")
  end

  test "DELETE /api/v1/admin/kv removes by key", %{conn: conn, admin: admin} do
    {:ok, _} = KV.put("test:gone", %{"a" => 1}, %{})

    assert conn
           |> bearer_conn(admin)
           |> delete("/api/v1/admin/kv", %{key: "test:gone"})
           |> json_response(200) == %{"ok" => true}

    assert KV.get("test:gone") == :error
  end

  test "entries: create, list, update and delete by id", %{conn: conn, admin: admin} do
    conn = bearer_conn(conn, admin)

    body =
      conn
      |> post("/api/v1/admin/kv/entries", %{key: "test:entry", data: %{"v" => 1}})
      |> json_response(201)

    assert %{"id" => id, "user_id" => "", "lobby_id" => "", "data" => %{"v" => 1}} = body["data"]

    body = conn |> get("/api/v1/admin/kv/entries", %{key: "test:entry"}) |> json_response(200)
    assert [%{"id" => ^id}] = body["data"]

    body =
      conn
      |> patch("/api/v1/admin/kv/entries/#{id}", %{data: %{"v" => 2}})
      |> json_response(200)

    assert body["data"]["data"] == %{"v" => 2}

    assert conn |> delete("/api/v1/admin/kv/entries/#{id}") |> json_response(200) ==
             %{"ok" => true}
  end

  test "PUT /api/v1/admin/kv without data is a validation failure", %{conn: conn, admin: admin} do
    resp =
      conn
      |> bearer_conn(admin)
      |> put("/api/v1/admin/kv", %{"key" => "test:empty"})
      |> json_response(422)

    assert resp == %{"error" => "validation_failed", "errors" => %{"data" => ["can't be blank"]}}
  end
end
