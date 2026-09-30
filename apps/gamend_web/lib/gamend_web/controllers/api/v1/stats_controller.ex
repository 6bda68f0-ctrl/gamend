defmodule GamendWeb.Api.V1.StatsController do
  @moduledoc """
  `GET /api/v1/stats` — every public counter in one response, from
  `Gamend.Analytics.snapshot/0`. The per-resource `/<resource>/stats`
  endpoints keep working and read the same cached composition; this one saves
  a client six requests. Gated by `:public_stats` like the others.
  """
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Gamend.Analytics
  alias GamendWeb.Schemas.ServerStatsResponse

  tags(["Stats"])

  operation(:show,
    operation_id: "get_stats",
    summary: "All public server counters in one call",
    description:
      "Players, activity (DAU / WAU / MAU, new users), lobbies, parties, quests, " <>
        "signaling, matchmaking queue and tournaments. Cached for a minute server-side.",
    responses: [ok: {"Snapshot", "application/json", ServerStatsResponse}]
  )

  def show(conn, _params), do: reply_data(conn, Analytics.snapshot())
end
