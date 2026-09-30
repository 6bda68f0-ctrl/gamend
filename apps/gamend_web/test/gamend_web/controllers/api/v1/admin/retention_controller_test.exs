defmodule GamendWeb.Api.V1.Admin.RetentionControllerTest do
  use GamendWeb.ConnCase, async: false

  alias Gamend.Accounts.User
  alias Gamend.Repo
  alias GamendWeb.Auth.Guardian

  setup %{conn: conn} do
    admin = Gamend.AccountsFixtures.user_fixture()
    {:ok, admin} = admin |> User.admin_changeset(%{"is_admin" => true}) |> Repo.update()
    {:ok, token, _} = Guardian.encode_and_sign(admin)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token)}
  end

  test "requires admin" do
    user = Gamend.AccountsFixtures.user_fixture()
    {:ok, token, _} = Guardian.encode_and_sign(user)
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    assert json_response(get(conn, "/api/v1/admin/retention"), 403)
    assert json_response(post(conn, "/api/v1/admin/retention/run"), 403)
  end

  test "reports the last sweep", %{conn: conn} do
    body = json_response(get(conn, "/api/v1/admin/retention"), 200)["data"]

    assert Map.has_key?(body, "last_run_at")
    assert Map.has_key?(body, "duration_ms")
    assert is_map(body["results"])
  end

  # The sweeper is not supervised under test, so a manual run has nothing to
  # call - which is exactly the degraded case the endpoint has to report.
  test "reports unavailable when the sweeper is not running", %{conn: conn} do
    assert %{"error" => error} = json_response(post(conn, "/api/v1/admin/retention/run"), 503)
    assert error == "sweeper_not_running"
  end

  test "runs a sweep and reports it", %{conn: conn} do
    start_supervised!(Gamend.Retention)

    body = json_response(post(conn, "/api/v1/admin/retention/run"), 200)["data"]
    assert body["last_run_at"]
    assert is_integer(body["duration_ms"])
    assert is_map(body["results"])
  end
end
