defmodule GamendWeb.Api.V1.TimeControllerTest do
  use GamendWeb.ConnCase, async: true

  test "GET /api/v1/time answers the server clock in ms", %{conn: conn} do
    before = System.system_time(:millisecond)
    now = conn |> get("/api/v1/time") |> json_response(200) |> get_in(["data", "server_now"])

    assert is_integer(now)
    assert now >= before - 1_000
  end
end
