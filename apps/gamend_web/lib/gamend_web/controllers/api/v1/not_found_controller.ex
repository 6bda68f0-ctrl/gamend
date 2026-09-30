defmodule GamendWeb.Api.V1.NotFoundController do
  @moduledoc """
  Terminates unmatched `/api/v1/*` requests with a JSON 404.

  Without this, an unknown API path falls through to the configured-page
  catch-all, which pipes through `:browser` and calls `fetch_session` — but the
  endpoint deliberately skips `Plug.Session` for `/api/v1/*`, so the request
  raises instead of 404ing. Scanners probe those paths constantly, so the
  difference is a stream of 500s in the logs.

  Mounted by `gamend_configured_page_fallback_routes/0`, ahead of the page
  catch-all and after every real API route.
  """
  use GamendWeb, :controller

  def not_found(conn, _params) do
    reply_error(conn, :not_found, "not_found", "Not Found")
  end
end
