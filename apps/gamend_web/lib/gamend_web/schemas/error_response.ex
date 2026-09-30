defmodule GamendWeb.Schemas.ErrorResponse do
  @moduledoc """
  Every non-2xx JSON body (docs/specs/api-conventions.md, R12 and R15): a
  snake_case `error` code, optional `message` prose for a person, and the
  per-field `errors` only with `validation_failed`.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ErrorResponse",
    description: "Error response",
    type: :object,
    properties: %{
      error: %Schema{
        type: :string,
        pattern: "^[a-z][a-z0-9_]*$",
        description: "snake_case reason a client can switch on",
        example: "not_found"
      },
      message: %Schema{type: :string, description: "A human-readable explanation"},
      errors: %Schema{
        type: :object,
        description: "With validation_failed only: per-field messages, already translated",
        additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
      }
    },
    required: [:error]
  })
end
