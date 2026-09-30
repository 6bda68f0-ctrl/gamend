defmodule GamendWeb.Schemas do
  @moduledoc """
  Helpers for the named OpenAPI components under `GamendWeb.Schemas.*`.

  Every response shape is a module there, so the document names it and a
  generator emits `Lobby` rather than `ListLobbies200ResponseDataInner`. The
  naming rules are in `docs/specs/named-api-schemas.md`.
  """

  alias GamendWeb.Schemas.ErrorResponse

  @doc """
  An error response for an operation's `responses:` list. Every error body is
  the one `ErrorResponse`, so each operation only says what the status means.
  """
  @spec error(String.t()) :: {String.t(), String.t(), module()}
  def error(description), do: {description, "application/json", ErrorResponse}
end
