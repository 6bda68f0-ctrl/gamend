defmodule GamendWeb.AdminLive.Analytics do
  @moduledoc """
  Admin view over player activity and retention: DAU / WAU / MAU, new users,
  D1 / D7 / D30 cohort retention and payer conversion, plus a per-day table
  for the last 30 (or 90) UTC days. Read-only; the numbers come from
  `Gamend.Analytics`.
  """
  use GamendWeb, :live_view

  alias Gamend.Analytics

  @windows [30, 90]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Analytics")
     |> assign(:days, 30)
     |> reload()}
  end

  @impl true
  def handle_event("window", %{"days" => days}, socket) do
    days =
      case Integer.parse(days) do
        {n, ""} when n in @windows -> n
        _ -> 30
      end

    {:noreply, socket |> assign(:days, days) |> reload()}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, reload(socket)}

  # Economy and counters use a fixed 7-day window: they answer "what is the
  # game doing this week", the cohort table answers "how are we trending".
  @flow_days 7

  defp reload(socket) do
    socket
    |> assign(:summary, Analytics.summary())
    |> assign(:series, socket.assigns.days |> Analytics.daily_series() |> Enum.reverse())
    |> assign(:economy, Analytics.economy_totals(@flow_days))
    |> assign(:counters, Analytics.count_totals("*", @flow_days))
    |> assign(:flow_days, @flow_days)
  end

  # ── render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/admin"} class="btn btn-outline btn-sm">&larr; Back to Admin</.link>
            <h1 class="text-xl font-bold">Analytics · activity &amp; retention</h1>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">
              UTC days · as of {Date.to_iso8601(@summary.day)}
            </span>
            <button phx-click="refresh" class="btn btn-ghost btn-sm">Refresh</button>
          </div>
        </div>

        <div class="grid grid-cols-2 md:grid-cols-4 xl:grid-cols-8 gap-3">
          <.stat title="DAU" value={@summary.dau} desc="seen today" />
          <.stat title="WAU" value={@summary.wau} desc="last 7 days" />
          <.stat title="MAU" value={@summary.mau} desc="last 30 days" />
          <.stat title="Stickiness" value={pct(@summary.stickiness)} desc="DAU ÷ MAU" />
          <.stat title="D1" value={pct(@summary.d1)} desc="back the next day" />
          <.stat title="D7" value={pct(@summary.d7)} desc="back on day 7" />
          <.stat title="D30" value={pct(@summary.d30)} desc="back on day 30" />
          <.stat
            title="Payers"
            value={pct(@summary.conversion_30d)}
            desc={"#{@summary.payers_30d} of MAU, 30d"}
          />
        </div>

        <div class="text-xs text-base-content/60">
          New users: {@summary.new_users_7d} in the last 7 days, {@summary.new_users_30d} in the last 30.
          Retention is pooled over the cohorts of the last 60 days that have reached each horizon
          (a D7 needs a cohort at least 7 days old); "—" means no cohort has reached it yet.
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h2 class="card-title">Per day</h2>
              <div class="join">
                <button
                  :for={n <- [30, 90]}
                  phx-click="window"
                  phx-value-days={n}
                  class={["btn btn-sm join-item", @days == n && "btn-active"]}
                >
                  {n} days
                </button>
              </div>
            </div>

            <div class="overflow-x-auto">
              <table class="table table-sm table-zebra">
                <thead>
                  <tr>
                    <th>Day (UTC)</th>
                    <th class="text-right">Active</th>
                    <th class="text-right">New</th>
                    <th class="text-right">D1</th>
                    <th class="text-right">D7</th>
                    <th class="text-right">D30</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @series}>
                    <td class="font-mono">{Date.to_iso8601(row.day)}</td>
                    <td class="text-right">{row.active}</td>
                    <td class="text-right">{row.new_users}</td>
                    <td class="text-right">{pct(row.d1)}</td>
                    <td class="text-right">{pct(row.d7)}</td>
                    <td class="text-right">{pct(row.d30)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p class="text-xs text-base-content/60 mt-2">
              D1/D7/D30 on a row are that day's sign-up cohort: of the players who registered
              that day, the share seen again exactly 1 / 7 / 30 days later.
            </p>
          </div>
        </div>

        <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
          <div class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Economy · last {@flow_days} days</h2>
              <p class="text-xs text-base-content/60">
                Every wallet grant and spend, by the ledger <code>reason</code> the game
                passed. Sources are positive, sinks negative — the Net column is what inflates
                or drains balances.
              </p>
              <div class="overflow-x-auto">
                <table class="table table-sm table-zebra">
                  <thead>
                    <tr>
                      <th>Currency</th>
                      <th>Reason</th>
                      <th class="text-right">Granted</th>
                      <th class="text-right">Spent</th>
                      <th class="text-right">Net</th>
                      <th class="text-right">Entries</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- @economy}>
                      <td class="font-mono">{row.currency}</td>
                      <td class="font-mono">{row.reason}</td>
                      <td class="text-right">{row.granted}</td>
                      <td class="text-right">{row.spent}</td>
                      <td class={["text-right font-semibold", net_class(row.net)]}>{row.net}</td>
                      <td class="text-right">{row.entries}</td>
                    </tr>
                    <tr :if={@economy == []}>
                      <td colspan="6" class="text-base-content/60">
                        No ledger entries in the window.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Counters · last {@flow_days} days</h2>
              <p class="text-xs text-base-content/60">
                Game-defined daily counters (<code>Gamend.Analytics.count/3</code>): whatever
                the game reports, such as levels started, finished or failed. Empty until the
                game writes some.
              </p>
              <div class="overflow-x-auto">
                <table class="table table-sm table-zebra">
                  <thead>
                    <tr>
                      <th>Key</th>
                      <th class="text-right">Total</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{key, total} <- @counters}>
                      <td class="font-mono">{key}</td>
                      <td class="text-right">{total}</td>
                    </tr>
                    <tr :if={@counters == []}>
                      <td colspan="2" class="text-base-content/60">No counters yet.</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp net_class(n) when n > 0, do: "text-success"
  defp net_class(n) when n < 0, do: "text-error"
  defp net_class(_), do: nil

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :desc, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-100 p-3">
      <div class="text-xs text-base-content/60">{@title}</div>
      <div class="text-2xl font-bold">{@value}</div>
      <div :if={@desc} class="text-xs text-base-content/60">{@desc}</div>
    </div>
    """
  end

  defp pct(nil), do: "—"
  defp pct(rate) when is_float(rate), do: "#{Float.round(rate * 100, 1)}%"
end
