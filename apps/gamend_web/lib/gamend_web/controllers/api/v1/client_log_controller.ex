defmodule GamendWeb.Api.V1.ClientLogController do
  @moduledoc """
  Ingest for logs from the game client, and the policy that tells a client what
  to send.

  Optional auth, deliberately. The entries worth having most are the ones from
  before a client has a token — a failed login, a boot that never got as far as
  the network — and requiring a bearer token would drop exactly those. A batch
  from an authenticated caller is bound to that user; an anonymous one is bound
  to its device, and adopted by the user when the same run signs in. See
  `Gamend.ClientLogs`.

  ## Transport

  HTTP rather than the user channel the client already holds open, because the
  interesting failures are the ones where that channel is down. A batch that
  can only be delivered over a working socket is a batch that cannot explain a
  broken one.
  """
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Gamend.Accounts.Scope
  alias Gamend.ClientLogs
  alias GamendWeb.Schemas
  alias GamendWeb.Schemas.ClientLogBatch
  alias GamendWeb.Schemas.ClientLogPolicyResponse
  alias GamendWeb.Schemas.ClientLogResultResponse

  tags(["Client logs"])

  operation(:policy,
    operation_id: "get_client_log_policy",
    security: [%{}, %{"authorization" => []}],
    summary: "Client log capture policy",
    description:
      "What the client should collect and upload: whether collection is on at all, the " <>
        "lowest level to send, and per-category overrides. Fetch at startup and on resume; " <>
        "a client that cannot reach this should collect nothing.",
    responses: [
      ok: {"Capture policy", "application/json", ClientLogPolicyResponse}
    ]
  )

  def policy(conn, _params), do: reply_data(conn, ClientLogs.capture_policy())

  operation(:create,
    operation_id: "upload_client_logs",
    security: [%{}, %{"authorization" => []}],
    summary: "Upload a batch of client log entries",
    description:
      "Entries are re-emitted into the server's own log stream, so a search for the " <>
        "session id returns client and server lines together. Accepts at most 200 entries " <>
        "per call; the surplus is discarded and counted as dropped.",
    request_body: {"Log batch", "application/json", ClientLogBatch},
    responses: [
      accepted: {"Batch accepted", "application/json", ClientLogResultResponse},
      bad_request: Schemas.error("Malformed batch (invalid_batch)"),
      forbidden: Schemas.error("The session belongs to another user (session_forbidden)"),
      service_unavailable: Schemas.error("Collection is disabled (collection_disabled)")
    ]
  )

  def create(conn, params) do
    user_id = conn.assigns |> Map.get(:current_scope) |> Scope.user_id()

    case ClientLogs.ingest(body(conn, params), user_id: user_id) do
      {:ok, summary} ->
        reply_data(conn, :accepted, summary)

      {:error, :disabled} ->
        # 503 rather than 404: the route exists and the client is doing the
        # right thing, so it should back off and retry later rather than treat
        # collection as permanently gone.
        reply_error(conn, :service_unavailable, "collection_disabled")

      {:error, :forbidden} ->
        reply_error(conn, :forbidden, "session_forbidden")

      {:error, :invalid} ->
        reply_error(conn, :bad_request, "invalid_batch")
    end
  end

  # Phoenix hands JSON params with atom-less string keys, but OpenApiSpex's
  # cast step replaces the body with a struct when a spec is attached. Take
  # whichever shape arrived and normalize to the string-keyed map the context
  # expects, rather than making the context handle both.
  defp body(conn, params) do
    case conn.private[:open_api_spex] do
      %{body_params: %_{} = cast} -> cast |> Map.from_struct() |> stringify()
      _ -> params
    end
  end

  defp stringify(%_{} = struct), do: struct |> Map.from_struct() |> stringify()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
