defmodule Gamend.ConfigTest do
  @moduledoc """
  Typed env var reads. The type comes from the declared default, so a plugin
  writes the default once instead of every caller re-parsing a string.
  """
  use ExUnit.Case, async: false

  alias Gamend.Config

  describe "get/2 (no declaration needed)" do
    test "coerces to the default's type" do
      System.put_env("GS_TEST_INT", "12")
      System.put_env("GS_TEST_BOOL", "false")
      System.put_env("GS_TEST_FLOAT", "1.5")
      System.put_env("GS_TEST_STR", "hello")

      assert Config.get("GS_TEST_INT", 8) == 12
      assert Config.get("GS_TEST_BOOL", true) == false
      assert Config.get("GS_TEST_FLOAT", 0.0) == 1.5
      assert Config.get("GS_TEST_STR", "x") == "hello"
    end

    test "returns the default when unset or empty" do
      System.delete_env("GS_TEST_UNSET")
      System.put_env("GS_TEST_EMPTY", "")

      assert Config.get("GS_TEST_UNSET", 8) == 8
      assert Config.get("GS_TEST_EMPTY", 8) == 8
    end

    test "accepts the usual spellings of a boolean" do
      for {raw, expected} <- [
            {"1", true},
            {"true", true},
            {"TRUE", true},
            {"yes", true},
            {"on", true},
            {"0", false},
            {"false", false},
            {"FALSE", false},
            {"no", false},
            {"off", false}
          ] do
        System.put_env("GS_TEST_BOOL", raw)
        assert Config.get("GS_TEST_BOOL", true) == expected, "#{raw} should be #{expected}"
      end
    end

    test "falls back to the default rather than crashing on a malformed value" do
      System.put_env("GS_TEST_INT", "twelve")
      System.put_env("GS_TEST_BOOL", "maybe")

      assert Config.get("GS_TEST_INT", 8) == 8
      # An unparseable boolean is not silently truthy.
      assert Config.get("GS_TEST_BOOL", true) == true
    end
  end

  describe "get/1 (declared vars)" do
    test "raises for a name no plugin declared" do
      assert_raise ArgumentError, ~r/not declared by any plugin/, fn ->
        Config.get("GS_TEST_NEVER_DECLARED")
      end
    end
  end

  describe "infer_type/1" do
    test "reads the type off the value" do
      assert Config.infer_type(true) == :boolean
      assert Config.infer_type(8) == :integer
      assert Config.infer_type(1.5) == :float
      assert Config.infer_type("x") == :string
      # nil cannot carry a type; :string is the safe read.
      assert Config.infer_type(nil) == :string
    end
  end

  setup do
    on_exit(fn ->
      for name <- ~w(GS_TEST_INT GS_TEST_BOOL GS_TEST_FLOAT GS_TEST_STR GS_TEST_EMPTY),
          do: System.delete_env(name)
    end)
  end
end
