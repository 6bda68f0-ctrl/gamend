defmodule Gamend.QueryTest do
  @moduledoc """
  The clamping `Gamend.Query` exists for.

  Before it, three contexts applied `:page_size` straight from the caller's
  options. `GamendWeb.Pagination` clamps at the controller and
  `mix gamend.api.lint` keeps controllers honest — but a plugin calls the
  context directly, and nothing was watching that path.
  """
  use Gamend.DataCase

  alias Gamend.Limits
  alias Gamend.Query

  defp limit_of(query), do: query.limit && Macro.expand(query.limit.expr, __ENV__)

  defp params(query),
    do: Enum.map(query.limit.params ++ (query.offset.params || []), &elem(&1, 0))

  describe "page/2" do
    test "clamps page_size to the configured maximum" do
      max = Limits.get(:max_page_size)

      [size, offset] = params(Query.page(Gamend.Accounts.User, page: 1, page_size: 1_000_000))

      assert size == max
      assert offset == 0
    end

    test "a page_size below one is raised to one" do
      [size, _offset] = params(Query.page(Gamend.Accounts.User, page: 1, page_size: 0))
      assert size == 1
    end

    test "defaults to the first page when none is given" do
      [_size, offset] = params(Query.page(Gamend.Accounts.User, []))
      assert offset == 0
    end

    test "a page below one is raised to one, so the offset never goes negative" do
      [_size, offset] = params(Query.page(Gamend.Accounts.User, page: -5, page_size: 10))
      assert offset == 0
    end

    test "offset follows the clamped size, not the requested one" do
      max = Limits.get(:max_page_size)
      [size, offset] = params(Query.page(Gamend.Accounts.User, page: 3, page_size: 10_000))

      assert size == max
      assert offset == 2 * max
    end
  end

  describe "maybe_page/2" do
    test "windows when a page is given" do
      [size, offset] = params(Query.maybe_page(Gamend.Accounts.User, page: 2, page_size: 10))
      assert size == 10
      assert offset == 10
    end

    test "bounds an unwindowed read rather than leaving it unlimited" do
      query = Query.maybe_page(Gamend.Accounts.User, [])

      assert limit_of(query) == Query.unpaginated_limit()
      assert query.offset == nil
    end

    test "still clamps the size it is given" do
      max = Limits.get(:max_page_size)
      [size, _offset] = params(Query.maybe_page(Gamend.Accounts.User, page: 1, page_size: 99_999))
      assert size == max
    end
  end

  describe "the contexts that used not to clamp" do
    test "an enormous page_size reaching a context directly is still bounded" do
      max = Limits.get(:max_page_size)

      # This is the call a plugin makes; it never passes through
      # GamendWeb.Pagination.
      assert length(Gamend.Economy.list_ledger(page: 1, page_size: 10_000_000)) <= max
      assert length(Gamend.Inventory.list_items(page: 1, page_size: 10_000_000)) <= max
    end
  end

  describe "filter_user/2" do
    setup do
      alice = Gamend.AccountsFixtures.user_fixture()
      {:ok, alice} = Gamend.Accounts.update_user(alice, %{display_name: "Alice Wonder"})
      bob = Gamend.AccountsFixtures.user_fixture()

      {:ok, _} = Gamend.Economy.grant(alice.id, "gold", 5)
      {:ok, _} = Gamend.Economy.grant(bob.id, "gold", 7)

      %{alice: alice, bob: bob}
    end

    defp owners(filter) do
      Gamend.Economy.Wallet
      |> Query.filter_user(filter)
      |> Gamend.Repo.all()
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
    end

    test "an exact id narrows to that user", %{alice: alice} do
      assert owners(alice.id) == [alice.id]
    end

    test "a case-insensitive name substring finds the user", %{alice: alice} do
      assert owners("WONDER") == [alice.id]
    end

    test "matches the username too", %{bob: bob} do
      assert bob.id in owners(String.slice(bob.username, 0, 5))
    end

    test "nil and a blank search leave the query alone", %{alice: alice, bob: bob} do
      assert Enum.sort(owners(nil)) == Enum.sort([alice.id, bob.id])
      assert Enum.sort(owners("")) == Enum.sort([alice.id, bob.id])
    end

    test "LIKE metacharacters in the search are literal" do
      assert owners("%") == []
    end
  end

  describe "filter_id/3" do
    setup do
      alice = Gamend.AccountsFixtures.user_fixture()
      bob = Gamend.AccountsFixtures.user_fixture()

      {:ok, _} = Gamend.Economy.grant(alice.id, "gold", 5)
      {:ok, _} = Gamend.Economy.grant(bob.id, "gold", 7)

      %{alice: alice, bob: bob}
    end

    defp owners_by_id(value) do
      Gamend.Economy.Wallet
      |> Query.filter_id(:user_id, value)
      |> Gamend.Repo.all()
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
    end

    test "narrows to exactly that id", %{alice: alice} do
      assert owners_by_id(alice.id) == [alice.id]
    end

    test "never searches names", %{alice: alice} do
      assert owners_by_id(alice.username) == []
    end

    test "a malformed id matches nothing rather than raising or matching everything" do
      assert owners_by_id("not-a-uuid") == []
    end

    test "nil and blank leave the query alone", %{alice: alice, bob: bob} do
      assert Enum.sort(owners_by_id(nil)) == Enum.sort([alice.id, bob.id])
      assert Enum.sort(owners_by_id("")) == Enum.sort([alice.id, bob.id])
    end

    test "KV listings take a malformed id from an admin filter without crashing" do
      assert Gamend.KV.list_entries(user_id: "not-a-uuid") == []
      assert Gamend.KV.count_entries(lobby_id: "not-a-uuid") == 0
    end
  end
end
