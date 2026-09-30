defmodule GamendWeb.Api.V1.EconomyController do
  @moduledoc """
  Read-only wallet access for the current user. Balance mutations are
  server-authoritative (hooks / admin), never a raw client endpoint.
  """
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Gamend.Accounts.Scope
  alias Gamend.Economy
  alias GamendWeb.Pagination
  alias GamendWeb.Schemas
  alias GamendWeb.Schemas.{InventoryResponse, LedgerEntryPage, WalletBalancesResponse}
  alias OpenApiSpex.Schema

  tags(["Economy"])

  operation(:wallet,
    operation_id: "get_current_user_wallet",
    summary: "Current user's currency balances",
    security: [%{"authorization" => []}],
    responses: [
      ok: {"Balances", "application/json", WalletBalancesResponse},
      unauthorized: Schemas.error("Not authenticated")
    ]
  )

  def wallet(conn, _params) do
    user = Scope.user(conn.assigns.current_scope)
    reply_data(conn, Economy.balances(user.id))
  end

  operation(:ledger,
    operation_id: "list_current_user_ledger",
    summary: "Current user's ledger history",
    security: [%{"authorization" => []}],
    parameters: [
      currency: [in: :query, schema: %Schema{type: :string}, required: false],
      page: [in: :query, schema: %Schema{type: :integer, default: 1}, required: false],
      page_size: [in: :query, schema: %Schema{type: :integer, default: 25}, required: false]
    ],
    responses: [
      ok: {"Ledger, newest first", "application/json", LedgerEntryPage},
      unauthorized: Schemas.error("Not authenticated")
    ]
  )

  def ledger(conn, params) do
    user = Scope.user(conn.assigns.current_scope)
    {page, page_size} = Pagination.params(params)

    filters = [user_id: user.id, currency: params["currency"], page: page, page_size: page_size]
    entries = Economy.list_ledger(filters)
    total = Economy.count_ledger(filters)

    reply_page(conn, Enum.map(entries, &serialize/1), page, page_size, total)
  end

  operation(:inventory,
    operation_id: "get_current_user_inventory",
    summary: "Current user's item quantities",
    security: [%{"authorization" => []}],
    responses: [
      ok: {"Inventory", "application/json", InventoryResponse},
      unauthorized: Schemas.error("Not authenticated")
    ]
  )

  def inventory(conn, _params) do
    user = Scope.user(conn.assigns.current_scope)
    reply_data(conn, Gamend.Inventory.inventory(user.id))
  end

  defp serialize(entry) do
    %{
      id: entry.id,
      currency: entry.currency || "",
      delta: entry.delta,
      balance_after: entry.balance_after,
      reason: entry.reason || "",
      metadata: entry.metadata || %{},
      inserted_at: entry.inserted_at
    }
  end
end
