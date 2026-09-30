defmodule GamendWeb.Api.V1.HealthController do
  @moduledoc """
  Health check endpoint for the API.
  """
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GamendWeb.Schemas.HealthResponse

  tags(["Health"])

  operation(:index,
    operation_id: "index",
    summary: "Health check",
    description: "Returns the health status of the API",
    responses: [
      ok: {"Health status", "application/json", HealthResponse}
    ]
  )

  def index(conn, _params) do
    reply_data(conn, %{status: "ok", timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})
  end
end
