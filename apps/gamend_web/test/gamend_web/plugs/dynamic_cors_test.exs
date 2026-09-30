defmodule GamendWeb.Plugs.DynamicCorsTest do
  use GamendWeb.ConnCase, async: true

  test "a browser game's preflight may send the run's session header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://game.example")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header(
        "access-control-request-headers",
        "content-type,authorization,x-gamend-session"
      )
      |> options("/api/v1/login/device")

    allowed = conn |> get_resp_header("access-control-allow-headers") |> Enum.join(",")

    assert allowed =~ "x-gamend-session"
    assert allowed =~ "authorization"
  end
end
