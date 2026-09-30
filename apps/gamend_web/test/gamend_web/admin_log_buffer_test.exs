defmodule GamendWeb.AdminLogBufferTest do
  @moduledoc """
  `count_by_level/1` is what the admin page's level chips read. It has to count
  the same entries the list beside it shows, minus the level filter itself —
  counting the whole buffer is what let the page offer `error(7)` and then list
  one, the other six being client entries hidden by the default source filter.
  """
  use ExUnit.Case, async: false

  alias GamendWeb.AdminLogBuffer

  setup do
    # The buffer is started by the application, process-wide and shared with anything else logging during
    # the run, so every assertion scopes itself to this marker.
    marker = "count-by-level-#{System.unique_integer([:positive])}"

    put = fn level, source ->
      AdminLogBuffer.put(%{
        level: level,
        message: "#{marker} #{level} #{source}",
        meta: %{source: source}
      })
    end

    put.(:error, :client)
    put.(:error, :client)
    put.(:error, :server)
    put.(:warning, :server)

    {:ok, marker: marker}
  end

  describe "count_by_level/1" do
    test "with no options it counts the whole buffer", %{marker: marker} do
      counts = AdminLogBuffer.count_by_level(query: marker)

      assert counts[:error] == 3
      assert counts[:warning] == 1
    end

    test "it honours every other filter", %{marker: marker} do
      counts = AdminLogBuffer.count_by_level(query: marker, source: "server")

      assert counts[:error] == 1
      assert counts[:warning] == 1
    end

    test "it ignores :level, so a chip counts what picking it would show", %{marker: marker} do
      # The caller passes the whole filter set, current level included; the
      # count must still answer for every level, or each chip would report the
      # selected one's total.
      counts = AdminLogBuffer.count_by_level(query: marker, source: "server", level: "error")

      assert counts[:error] == 1
      assert counts[:warning] == 1
    end

    test "the count agrees with what list/1 returns", %{marker: marker} do
      opts = [query: marker, source: "server", level: "error"]

      assert AdminLogBuffer.count_by_level(opts)[:error] == length(AdminLogBuffer.list(opts))
    end
  end
end
