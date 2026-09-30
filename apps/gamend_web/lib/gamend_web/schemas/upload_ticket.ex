defmodule GamendWeb.Schemas.UploadTicket do
  @moduledoc """
  A presigned upload, as `GamendWeb.Uploads.ticket/5` answers: PUT the bytes
  to `url` with `headers`, then confirm `key` on the matching endpoint.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "UploadTicket",
    description: "Where and how to upload an object",
    type: :object,
    properties: %{
      method: %Schema{type: :string, description: "HTTP method, always PUT", example: "PUT"},
      url: %Schema{type: :string, description: "Where to send the bytes"},
      headers: %Schema{
        type: :object,
        description: "Headers the upload must carry",
        additionalProperties: %Schema{type: :string}
      },
      key: %Schema{type: :string, description: "The object key to confirm afterwards"},
      expires_in: %Schema{type: :integer, description: "Seconds the ticket stays valid"},
      token: %Schema{
        type: :string,
        description: "Local storage only: the signed upload token, also carried in `url`"
      }
    },
    required: [:method, :url, :headers, :key, :expires_in]
  })
end

defmodule GamendWeb.Schemas.UploadTicketResponse do
  @moduledoc "An upload ticket under `data`."
  use GamendWeb.Schemas.Envelope, data: GamendWeb.Schemas.UploadTicket
end
