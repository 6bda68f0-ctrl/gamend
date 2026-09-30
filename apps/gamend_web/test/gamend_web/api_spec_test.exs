defmodule GamendWeb.ApiSpecTest do
  use ExUnit.Case, async: false

  alias GamendWeb.ApiSpec

  # The endpoint dispatches through the router named in config, so a host app
  # that adds API routes serves them. The spec read GamendWeb.Router directly,
  # so it documented none of them: absent from /api/docs, from the generated
  # SDKs, and from the route existence checks in `mix gamend.api.lint`. The two
  # have to resolve the router the same way.
  defmodule HostRouter do
    use Phoenix.Router

    import Phoenix.Controller

    pipeline :api do
      plug :accepts, ["json"]
    end

    scope "/api/v1", GamendWeb.Api.V1, as: :api_v1 do
      pipe_through :api

      get "/host_only", HealthController, :index
    end
  end

  describe "spec/0 router resolution" do
    setup do
      original = Application.get_env(:gamend_web, :router)

      on_exit(fn ->
        if original do
          Application.put_env(:gamend_web, :router, original)
        else
          Application.delete_env(:gamend_web, :router)
        end
      end)

      :ok
    end

    test "falls back to core's router" do
      Application.delete_env(:gamend_web, :router)

      paths = Map.keys(ApiSpec.spec().paths)

      assert "/api/v1/login" in paths
      refute "/api/v1/host_only" in paths
    end

    test "documents the configured router's routes instead" do
      Application.put_env(:gamend_web, :router, HostRouter)

      paths = Map.keys(ApiSpec.spec().paths)

      assert "/api/v1/host_only" in paths
      refute "/api/v1/login" in paths
    end
  end
end
