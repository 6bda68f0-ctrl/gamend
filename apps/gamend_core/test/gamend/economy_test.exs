defmodule Gamend.EconomyTest do
  use Gamend.DataCase, async: true

  alias Gamend.Economy

  setup do
    %{user: Gamend.AccountsFixtures.user_fixture()}
  end

  describe "grant/4" do
    test "adds balance and records a ledger entry", %{user: user} do
      assert {:ok, 100} = Economy.grant(user.id, "gold", 100, reason: "match_reward")
      assert Economy.balance(user.id, "gold") == 100

      assert [entry] = Economy.list_ledger(user_id: user.id)
      assert entry.delta == 100
      assert entry.balance_after == 100
      assert entry.reason == "match_reward"
    end

    test "accumulates across grants", %{user: user} do
      assert {:ok, 100} = Economy.grant(user.id, "gold", 100)
      assert {:ok, 150} = Economy.grant(user.id, "gold", 50)
      assert Economy.balance(user.id, "gold") == 150
    end

    test "granting nothing is a no-op, not a crash", %{user: user} do
      {:ok, _} = Economy.grant(user.id, "gold", 100)

      # Callers compute amounts — a payout after a cap, a price after a
      # discount — and zero is an ordinary answer.
      assert {:ok, 100} = Economy.grant(user.id, "gold", 0)
      assert Economy.balance(user.id, "gold") == 100
      # Nothing written means nothing to explain in the ledger later.
      assert length(Economy.list_ledger(user_id: user.id)) == 1
    end

    test "rejects an invalid currency", %{user: user} do
      assert {:error, :invalid_currency} = Economy.grant(user.id, "", 10)
    end
  end

  describe "spend/4" do
    test "spending nothing succeeds and charges nothing", %{user: user} do
      {:ok, _} = Economy.grant(user.id, "gold", 50)

      # Free is a price: an item the player has already earned costs zero.
      assert {:ok, 50} = Economy.spend(user.id, "gold", 0, reason: "free_item")
      assert Economy.balance(user.id, "gold") == 50
      assert length(Economy.list_ledger(user_id: user.id)) == 1
    end

    test "spending nothing works on an empty wallet too", %{user: user} do
      assert {:ok, 0} = Economy.spend(user.id, "gems", 0)
    end

    test "subtracts and records a negative delta", %{user: user} do
      Economy.grant(user.id, "gold", 100)
      assert {:ok, 70} = Economy.spend(user.id, "gold", 30, reason: "store")

      assert [%{delta: -30, balance_after: 70, reason: "store"} | _] =
               Economy.list_ledger(user_id: user.id)
    end

    test "refuses to overspend and writes no ledger entry", %{user: user} do
      Economy.grant(user.id, "gold", 100)
      before = Economy.count_ledger(user_id: user.id)

      assert {:error, :insufficient_funds} = Economy.spend(user.id, "gold", 1000)
      assert Economy.balance(user.id, "gold") == 100
      assert Economy.count_ledger(user_id: user.id) == before
    end

    test "spends down to a floor of zero", %{user: user} do
      Economy.grant(user.id, "gold", 100)
      for _ <- 1..6, do: assert({:ok, _} = Economy.spend(user.id, "gold", 15))
      assert Economy.balance(user.id, "gold") == 10
      assert {:error, :insufficient_funds} = Economy.spend(user.id, "gold", 15)
      assert Economy.balance(user.id, "gold") == 10
    end

    test "spending a currency with no wallet fails", %{user: user} do
      assert {:error, :insufficient_funds} = Economy.spend(user.id, "gold", 1)
    end
  end

  describe "idempotency" do
    test "a repeated grant with the same key applies once", %{user: user} do
      assert {:ok, 5} = Economy.grant(user.id, "gems", 5, idempotency_key: "order-1")
      assert {:ok, 5} = Economy.grant(user.id, "gems", 5, idempotency_key: "order-1")
      assert Economy.balance(user.id, "gems") == 5
      assert Economy.count_ledger(user_id: user.id) == 1
    end

    test "a repeated spend with the same key applies once", %{user: user} do
      Economy.grant(user.id, "gold", 100)
      assert {:ok, 60} = Economy.spend(user.id, "gold", 40, idempotency_key: "spend-1")
      assert {:ok, 60} = Economy.spend(user.id, "gold", 40, idempotency_key: "spend-1")
      assert Economy.balance(user.id, "gold") == 60
    end
  end

  describe "realtime" do
    test "broadcasts wallet_updated to subscribers after a change", %{user: user} do
      Economy.subscribe(user.id)
      assert {:ok, 100} = Economy.grant(user.id, "gold", 100)
      assert_receive {:wallet_updated, %{currency: "gold", balance: 100, delta: 100}}

      assert {:ok, 70} = Economy.spend(user.id, "gold", 30)
      assert_receive {:wallet_updated, %{currency: "gold", balance: 70, delta: -30}}
    end
  end

  describe "reads" do
    test "balances/1 returns every currency", %{user: user} do
      Economy.grant(user.id, "gold", 100)
      Economy.grant(user.id, "gems", 5)
      assert Economy.balances(user.id) == %{"gold" => 100, "gems" => 5}
    end

    test "balance/2 is 0 for an unknown currency", %{user: user} do
      assert Economy.balance(user.id, "nope") == 0
    end

    test "list_ledger filters by currency and paginates", %{user: user} do
      Economy.grant(user.id, "gold", 10)
      Economy.grant(user.id, "gems", 10)

      assert length(Economy.list_ledger(user_id: user.id)) == 2
      assert [%{currency: "gems"}] = Economy.list_ledger(user_id: user.id, currency: "gems")
      assert length(Economy.list_ledger(user_id: user.id, page_size: 1)) == 1
      assert Economy.count_ledger(user_id: user.id) == 2
    end
  end
end
