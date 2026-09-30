defmodule GamendWeb.Api.V1.PaymentErrors do
  @moduledoc """
  The error answer for a failed payment call, shared by the checkout and
  webhook controllers. `Gamend.Payments` fails with an atom for every reason
  a client or a provider can act on, and its name is the code; the status
  follows the rule in docs/specs/api-conventions.md:

  - `*_not_found` is 404, `already_*` and `*_already_*` 409;
  - `*_not_configured` is 503: the server, not the request, is missing
    something, and a provider retries a webhook later;
  - a failed changeset is 422 `validation_failed`; anything else 400.

  A reason that is not an atom is an internal term, so it is logged and
  answered as `payment_failed` rather than shown.
  """

  import GamendWeb.ChangesetErrors, only: [unprocessable: 2]
  import GamendWeb.Reply

  require Logger

  @spec reply(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def reply(conn, %Ecto.Changeset{} = changeset), do: unprocessable(conn, changeset)
  def reply(conn, {reason, _detail}) when is_atom(reason), do: reply(conn, reason)

  def reply(conn, reason) when is_atom(reason) and not is_nil(reason) do
    code = Atom.to_string(reason)
    reply_error(conn, status(code), code)
  end

  def reply(conn, reason) do
    Logger.warning("payment call failed: #{inspect(reason)}")
    reply_error(conn, :bad_request, "payment_failed")
  end

  defp status(code) do
    cond do
      String.ends_with?(code, "_not_found") -> :not_found
      String.starts_with?(code, "already_") or String.contains?(code, "_already_") -> :conflict
      String.ends_with?(code, "_not_configured") -> :service_unavailable
      true -> :bad_request
    end
  end
end
