defmodule Gamend.SignalsTest do
  # Signals are pub/sub over the process mailbox, so each test uses its own
  # plugin name and nothing has to be serialised.
  use ExUnit.Case, async: true

  alias Gamend.Signals

  setup do
    %{plugin: "plugin_#{System.unique_integer([:positive])}"}
  end

  describe "topic/2" do
    test "scopes a name to its plugin", %{plugin: plugin} do
      assert Signals.topic(plugin, "level_up") == "gdsignal:#{plugin}:level_up"
      refute Signals.topic(plugin, "a") == Signals.topic(plugin, "b")
    end
  end

  describe "emit and await" do
    test "a subscriber receives the payload", %{plugin: plugin} do
      :ok = Signals.subscribe(plugin, "level_up")
      :ok = Signals.emit(plugin, "level_up", ["user-1", 5])

      assert {:ok, ["user-1", 5]} = Signals.await(plugin, "level_up", 500)
    end

    test "a signal with no payload arrives as nil", %{plugin: plugin} do
      :ok = Signals.subscribe(plugin, "ready")
      :ok = Signals.emit(plugin, "ready")

      assert {:ok, nil} = Signals.await(plugin, "ready", 500)
    end

    test "await times out rather than blocking forever", %{plugin: plugin} do
      :ok = Signals.subscribe(plugin, "never")

      assert {:error, :timeout} = Signals.await(plugin, "never", 50)
    end

    test "a signal nobody is listening for is dropped, not an error", %{plugin: plugin} do
      # Godot does the same: emitting into the void is fine.
      assert :ok = Signals.emit(plugin, "unheard", 1)
    end

    test "only signals emitted after subscribing are seen", %{plugin: plugin} do
      # The reason the GDScript front end subscribes at function entry.
      :ok = Signals.emit(plugin, "early", "missed")
      :ok = Signals.subscribe(plugin, "early")

      assert {:error, :timeout} = Signals.await(plugin, "early", 50)
    end

    test "successive emits queue in order", %{plugin: plugin} do
      :ok = Signals.subscribe(plugin, "tick")
      for n <- 1..3, do: Signals.emit(plugin, "tick", n)

      assert {:ok, 1} = Signals.await(plugin, "tick", 500)
      assert {:ok, 2} = Signals.await(plugin, "tick", 500)
      assert {:ok, 3} = Signals.await(plugin, "tick", 500)
    end
  end

  describe "isolation" do
    test "two plugins may use the same signal name", %{plugin: plugin} do
      other = plugin <> "_other"

      :ok = Signals.subscribe(plugin, "shared")
      :ok = Signals.emit(other, "shared", "not for you")

      assert {:error, :timeout} = Signals.await(plugin, "shared", 50)
    end

    test "a different signal name in the same plugin does not cross over", %{plugin: plugin} do
      :ok = Signals.subscribe(plugin, "wanted")
      :ok = Signals.emit(plugin, "other", 1)

      assert {:error, :timeout} = Signals.await(plugin, "wanted", 50)
    end

    test "every subscriber receives the emit", %{plugin: plugin} do
      parent = self()

      waiters =
        for _ <- 1..3 do
          Task.async(fn ->
            :ok = Signals.subscribe(plugin, "broadcast")
            send(parent, :ready)
            Signals.await(plugin, "broadcast", 1_000)
          end)
        end

      for _ <- 1..3, do: assert_receive(:ready, 1_000)
      :ok = Signals.emit(plugin, "broadcast", "hello")

      assert Enum.map(waiters, &Task.await(&1, 2_000)) == List.duplicate({:ok, "hello"}, 3)
    end

    test "a subscription belongs to the process that made it", %{plugin: plugin} do
      # A hook's Task subscribing does not leak into the caller.
      Task.async(fn -> Signals.subscribe(plugin, "scoped") end) |> Task.await(1_000)
      :ok = Signals.emit(plugin, "scoped", 1)

      assert {:error, :timeout} = Signals.await(plugin, "scoped", 50)
    end
  end
end
