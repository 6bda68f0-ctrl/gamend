defmodule GamendWeb.Schemas.OkResponse do
  @moduledoc "An action with nothing to return but that it happened: `{\"ok\": true}`."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OkResponse",
    description: "The action succeeded",
    type: :object,
    properties: %{ok: %Schema{type: :boolean}},
    required: [:ok]
  })
end
