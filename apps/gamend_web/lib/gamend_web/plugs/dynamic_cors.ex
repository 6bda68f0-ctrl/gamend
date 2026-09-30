defmodule GamendWeb.Plugs.DynamicCors do
  @moduledoc """
  Runtime CORS plug that delegates to Corsica using values read from
  application environment at startup. This allows `PHX_ALLOWED_ORIGINS`
  to be configured at runtime (via `config/runtime.exs`).

  The Corsica options are compiled once on first request and cached in a
  persistent_term for near-zero overhead on subsequent requests.
  """

  # `x-gamend-session` names the client's run on every call (see
  # `GamendWeb.Plugs.ClientSession`); a browser game's preflight asks for it.
  @default_allow_headers ["content-type", "authorization", "x-gamend-session"]
  @default_allow_methods ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

  @pt_key {__MODULE__, :corsica_opts}

  def init(opts), do: opts

  def call(conn, _opts) do
    Corsica.call(conn, cached_corsica_opts())
  end

  defp cached_corsica_opts do
    case :persistent_term.get(@pt_key, nil) do
      nil ->
        compiled = compile_corsica_opts()
        :persistent_term.put(@pt_key, compiled)
        compiled

      cached ->
        cached
    end
  end

  defp compile_corsica_opts do
    origins = Application.get_env(:gamend_web, :cors_allowed_origins, "*")

    Corsica.init(
      origins: origins,
      allow_headers: @default_allow_headers,
      allow_methods: @default_allow_methods,
      expose_headers: ["x-request-time"],
      # Credentials only when the operator named the origins they trust.
      #
      # `Access-Control-Allow-Origin: *` and credentials are mutually exclusive
      # in the CORS specification, and claiming both produced a response no
      # browser accepts: the preflight advertised `allow-credentials: true` with
      # the origin echoed, then the actual response carried a bare `*` and no
      # credentials header, and the request was blocked with nothing in it
      # explaining why. (Corsica sends the bare `*` from a dedicated clause when
      # it runs as a plug with `origins: "*"`, so the credentials-aware path
      # documented for that combination never runs here.)
      #
      # Wildcard-without-credentials is also the safer default: a token in an
      # `Authorization` header still works from any origin, which is how game
      # clients authenticate, while cookies stay unusable cross-origin. Naming
      # origins in `GAMEND_HTTP_ALLOWED_ORIGINS` is what opts into cookies.
      allow_credentials: origins != "*"
    )
  end

  @doc """
  Invalidate the cached Corsica options. Call this if CORS origins
  are changed at runtime (e.g. via admin config).
  """
  def invalidate_cache do
    :persistent_term.erase(@pt_key)
    :ok
  end
end
