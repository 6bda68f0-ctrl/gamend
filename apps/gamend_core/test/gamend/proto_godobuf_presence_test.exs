defmodule Gamend.Proto.GodobufPresenceTest do
  @moduledoc """
  The GDScript presence fixup, ported from `clients/fix_godobuf_presence.py`
  for `mix host.proto.gen`. Verified against real godobuf output shapes.
  """
  use ExUnit.Case, async: true

  alias Gamend.Proto.GodobufPresence

  # Real godobuf output: a PBField declaration, then the has_() it belongs to.
  defp source(field, tag) do
    """
    \t\t\t__#{field} = PBField.new("#{field}", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, #{tag}, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
    \t\tfunc has_#{field}() -> bool:
    \t\t\tif __#{field}.value != null:
    \t\t\t\treturn true
    \t\t\treturn false
    """
  end

  test "rewrites a null check into a FILLED state check" do
    {out, count} = GodobufPresence.fix("name" |> source(3))

    assert count == 1
    assert out =~ "return data[3].state == PB_SERVICE_STATE.FILLED"
    refute out =~ "!= null"
    # The declaration and the func signature are preserved verbatim.
    assert out =~ ~s(__name = PBField.new("name")
    assert out =~ "func has_name() -> bool:"
  end

  test "uses each field's own tag" do
    {out, count} = GodobufPresence.fix(source("alpha", 1) <> source("beta", 7))

    assert count == 2
    assert out =~ "data[1].state"
    assert out =~ "data[7].state"
  end

  test "leaves a has_() whose body is not the null-check pattern alone" do
    oneof = """
    \t\t\t__kind = PBField.new("kind", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 2, true, "")
    \t\tfunc has_kind() -> bool:
    \t\t\treturn data[2].state == PB_SERVICE_STATE.FILLED
    """

    assert {^oneof, 0} = GodobufPresence.fix(oneof)
  end

  test "leaves a has_() with no matching field declaration alone" do
    orphan = """
    \t\tfunc has_ghost() -> bool:
    \t\t\tif __ghost.value != null:
    \t\t\t\treturn true
    \t\t\treturn false
    """

    assert {^orphan, 0} = GodobufPresence.fix(orphan)
  end

  test "is a no-op on source with nothing to rewrite" do
    plain = "class Foo:\n\tvar x = 1\n"
    assert {^plain, 0} = GodobufPresence.fix(plain)
  end
end
