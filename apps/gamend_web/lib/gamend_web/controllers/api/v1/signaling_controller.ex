defmodule GamendWeb.Api.V1.SignalingController do
  @moduledoc """
  Read-only view of WebRTC signaling.

  Signaling itself runs over the `signaling:*` channel; this exists only so
  room occupancy is visible without opening one.
  """
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Gamend.Signaling
  alias GamendWeb.Schemas.SignalingStatsResponse

  tags(["Signaling"])

  operation(:stats,
    operation_id: "signaling_stats",
    summary: "WebRTC room counts",
    description:
      "Rooms configured, rooms with someone connected, and total peers. Public, and cached — treat the numbers as up to a minute old.",
    responses: [
      ok: {"Signaling stats", "application/json", SignalingStatsResponse}
    ]
  )

  def stats(conn, _params), do: reply_data(conn, Signaling.stats())
end
