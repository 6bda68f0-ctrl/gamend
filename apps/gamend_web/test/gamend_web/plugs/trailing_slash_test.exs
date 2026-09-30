defmodule GamendWeb.Plugs.TrailingSlashTest do
  use GamendWeb.ConnCase, async: false

  alias GamendWeb.Plugs.TrailingSlash

  test "a trailing slash is a permanent redirect to the bare path", %{conn: conn} do
    conn = get(conn, "/blog/")

    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["/blog"]
  end

  test "the query string rides along", %{conn: conn} do
    conn = get(conn, "/blog/?page=2")

    assert redirected_to(conn, 301) == "/blog?page=2"
  end

  test "the root and bare paths are left alone", %{conn: conn} do
    assert conn |> get("/") |> Map.fetch!(:status) == 200
    assert conn |> get("/blog") |> Map.fetch!(:status) == 200
  end

  test "a protocol-relative path never redirects off the site" do
    # Bandit hands `GET //evil.com/` over as that request path (RFC 9112
    # origin-form allows it); trimmed, `//evil.com` is a URL on another
    # host. `Plug.Test` normalises the path away, so the conn is shaped by
    # hand the way the adapter shapes it.
    for {path, segments, expected} <- [
          {"//evil.com/", ["evil.com"], "/evil.com"},
          {"///evil.com/x/", ["evil.com", "x"], "/evil.com/x"},
          {"//", [], "/"}
        ] do
      conn =
        build_conn(:get, "/")
        |> Map.merge(%{request_path: path, path_info: segments})
        |> TrailingSlash.call([])

      assert conn.status == 301, "expected #{inspect(path)} redirected"
      assert get_resp_header(conn, "location") == [expected]
    end
  end

  test "switched off in config, a trailing slash is served as it is", %{conn: conn} do
    Application.put_env(:gamend_web, :redirect_trailing_slash, false)
    on_exit(fn -> Application.delete_env(:gamend_web, :redirect_trailing_slash) end)

    assert conn |> get("/blog/") |> Map.fetch!(:status) == 200
  end
end
