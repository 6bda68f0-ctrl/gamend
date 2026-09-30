defmodule GamendWeb.TestSupport.Runtime do
  @moduledoc false

  alias Gamend.TestSupport.Runtime, as: CoreRuntime
  alias GamendWeb.Plugs.GeoCountry
  alias GamendWeb.Plugs.IpBan

  @doc "The core test runtime, plus the web app's processes."
  def start_suite do
    CoreRuntime.start_suite(
      setup: &setup/0,
      services: [
        GamendWeb.ConnectionTracker,
        {GamendWeb.RateLimit, clean_period: :timer.minutes(5)},
        GamendWeb.AdminLogBuffer
      ],
      endpoints: maybe_endpoint_child()
    )
  end

  defp setup do
    ensure_host_code_path()
    maybe_configure_host_router()
    maybe_register_content_paths()
    IpBan.init_table()
    GeoCountry.init_table()
  end

  defp maybe_endpoint_child do
    endpoint = Module.concat([GamendWeb, Endpoint])

    if Code.ensure_loaded?(endpoint) do
      [endpoint]
    else
      []
    end
  end

  defp maybe_configure_host_router do
    router = Module.concat([GamendHost, Router])

    if Code.ensure_loaded?(router) do
      Application.put_env(:gamend_web, :router, router, persistent: true)
    end
  end

  defp maybe_register_content_paths do
    content_paths = Module.concat([GamendHost, ContentPaths])

    if Code.ensure_loaded?(content_paths) and
         function_exported?(content_paths, :register_defaults, 0) do
      content_paths.register_defaults()
    end
  end

  defp ensure_host_code_path do
    host_ebin =
      Mix.Project.build_path()
      |> Path.join("lib/gamend_host/ebin")
      |> Path.expand(File.cwd!())

    if File.dir?(host_ebin) do
      Code.prepend_path(String.to_charlist(host_ebin))
    end
  end
end
