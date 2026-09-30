defmodule GamendWeb.Plugs.TrailingSlash do
  @moduledoc """
  `GET /docs/intro/` → `301 /docs/intro`.

  Phoenix matches both spellings to the same route, so without this a page
  is reachable at two URLs and a search engine sees a duplicate. Inbound
  links from a site that ended every URL in a slash — a Docusaurus export,
  GitHub Pages — keep working, at the cost of one redirect, and the canonical
  spelling is the one the router prints.

  The root is left alone, so is anything that is not a GET or HEAD, so is
  `/api/…` (not pages, and a client may not follow a redirect), and so is
  any path a static plug earlier in the endpoint already answered. The
  query string rides along.

      config :gamend_web, :redirect_trailing_slash, false

  switches it off.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: method, request_path: path} = conn, _opts)
      when method in ["GET", "HEAD"] and path != "/" do
    if String.ends_with?(path, "/") and page_path?(path) and enabled?() do
      # Rebuilt from the segments rather than trimmed from the raw path.
      # `GET //evil.com/` is a valid origin-form target that Bandit hands
      # over as that request path, and trimmed it is `//evil.com` — a
      # protocol-relative URL a browser follows to another host, which a
      # 301 with a day's cache would have made an open redirect. The
      # segments hold no empty entries, so the target always names a path
      # on this site.
      target = "/" <> Enum.join(conn.path_info, "/")

      location =
        case conn.query_string do
          "" -> target
          query -> target <> "?" <> query
        end

      conn
      |> put_resp_header("location", location)
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  # An API path is not a page with a canonical spelling: a client that put
  # a slash on the end gets the router's answer — a 404 — rather than a
  # redirect it may not follow.
  defp page_path?(path), do: not String.starts_with?(path, "/api/")

  defp enabled?, do: Application.get_env(:gamend_web, :redirect_trailing_slash, true)
end
