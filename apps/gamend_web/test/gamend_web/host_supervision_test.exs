defmodule GamendWeb.HostSupervisionTest do
  use ExUnit.Case, async: false

  alias GamendWeb.HostSupervision

  # A host app declares settings with Gamend.Settings.Provider and expects them
  # validated, listed in the admin panel and emitted into .env.example. None of
  # that happened before init_runtime/1 registered the app: Settings.apps/0 was
  # core's two apps and nothing else, so the declarations were never discovered
  # and Settings.get/2 went on answering with compiled defaults. The symptom was
  # an env var that did nothing and said nothing.
  describe "init_runtime/1 host app registration" do
    setup do
      original = Application.get_env(:gamend_core, Gamend.Settings, [])

      on_exit(fn ->
        Application.put_env(:gamend_core, Gamend.Settings, original)
        Gamend.Settings.reload()
      end)

      :ok
    end

    test "registers the app named by :host_app" do
      refute :some_host_app in Gamend.Settings.apps()

      HostSupervision.init_runtime(host_app: :some_host_app)

      assert :some_host_app in Gamend.Settings.apps()
    end

    test "falls back to the :host_static_app config a host already sets" do
      original = Application.get_env(:gamend_web, :host_static_app)
      Application.put_env(:gamend_web, :host_static_app, :configured_host_app)

      on_exit(fn ->
        if original do
          Application.put_env(:gamend_web, :host_static_app, original)
        else
          Application.delete_env(:gamend_web, :host_static_app)
        end
      end)

      HostSupervision.init_runtime()

      assert :configured_host_app in Gamend.Settings.apps()
    end

    test "is idempotent, because init_runtime/1 is documented as safe to repeat" do
      HostSupervision.init_runtime(host_app: :repeated_host_app)
      HostSupervision.init_runtime(host_app: :repeated_host_app)

      assert Enum.count(Gamend.Settings.apps(), &(&1 == :repeated_host_app)) == 1
    end

    test "registers nothing when the host is unconfigured" do
      before = Gamend.Settings.apps()

      HostSupervision.init_runtime(host_app: :gamend_web)

      assert Gamend.Settings.apps() == before
    end
  end
end
