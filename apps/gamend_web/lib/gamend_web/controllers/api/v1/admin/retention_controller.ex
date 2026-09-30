defmodule GamendWeb.Api.V1.Admin.RetentionController do
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Gamend.Retention
  alias GamendWeb.Schemas
  alias GamendWeb.Schemas.RetentionStatusResponse

  tags(["Admin – Retention"])

  operation(:show,
    operation_id: "admin_get_retention_status",
    summary: "Last retention sweep (admin)",
    security: [%{"authorization" => []}],
    responses: [
      ok: {"Status", "application/json", RetentionStatusResponse},
      unauthorized: Schemas.error("Not authenticated"),
      forbidden: Schemas.error("Admin required")
    ]
  )

  def show(conn, _params), do: reply_data(conn, serialize(Retention.status()))

  operation(:run,
    operation_id: "admin_run_retention",
    summary: "Run a retention sweep now (admin)",
    description:
      "Sweeps immediately instead of waiting for the next 6h cycle. Runs inside " <>
        "the sweeper, so it can never overlap the scheduled run.",
    security: [%{"authorization" => []}],
    responses: [
      ok: {"Status after the sweep", "application/json", RetentionStatusResponse},
      unauthorized: Schemas.error("Not authenticated"),
      forbidden: Schemas.error("Admin required"),
      service_unavailable: Schemas.error("Sweeper not running")
    ]
  )

  def run(conn, _params) do
    _results = Retention.run_now()
    reply_data(conn, serialize(Retention.status()))
  catch
    :exit, _reason ->
      reply_error(
        conn,
        :service_unavailable,
        "sweeper_not_running",
        "The retention sweeper is not running"
      )
  end

  defp serialize(status) do
    %{
      last_run_at: status.last_run_at,
      duration_ms: status.duration_ms,
      results: Map.new(status.results, fn {class, count} -> {to_string(class), count} end)
    }
  end
end
