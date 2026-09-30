defmodule GamendWeb.Api.V1.Admin.StorageController do
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Gamend.Storage
  alias GamendWeb.Schemas

  alias GamendWeb.Schemas.{
    OkResponse,
    StorageObjectPage,
    StorageObjectResponse,
    StorageUsageResponse
  }

  alias GamendWeb.Uploads
  alias OpenApiSpex.Schema

  tags(["Admin – Storage"])

  operation(:index,
    operation_id: "admin_list_storage_objects",
    summary: "List stored objects with usage (admin)",
    security: [%{"authorization" => []}],
    parameters: [
      prefix: [in: :query, schema: %Schema{type: :string}, required: false],
      page: [in: :query, schema: %Schema{type: :integer, default: 1}, required: false],
      page_size: [in: :query, schema: %Schema{type: :integer, default: 25}, required: false]
    ],
    responses: [
      ok: {"Objects", "application/json", StorageObjectPage},
      unauthorized: Schemas.error("Not authenticated"),
      forbidden: Schemas.error("Admin required")
    ]
  )

  def index(conn, params) do
    {page, page_size} = GamendWeb.Pagination.params(params)
    prefix = params["prefix"] || ""
    offset = (page - 1) * page_size

    objects = Storage.list_objects(prefix: prefix, offset: offset, limit: page_size)
    usage = Storage.usage(prefix: prefix)

    reply_page(conn, Enum.map(objects, &serialize/1), page, page_size, usage.count)
  end

  operation(:usage,
    operation_id: "admin_storage_usage",
    summary: "Objects and bytes stored under a prefix (admin)",
    security: [%{"authorization" => []}],
    parameters: [prefix: [in: :query, schema: %Schema{type: :string}, required: false]],
    responses: [
      ok: {"Usage", "application/json", StorageUsageResponse},
      unauthorized: Schemas.error("Not authenticated"),
      forbidden: Schemas.error("Admin required")
    ]
  )

  def usage(conn, params) do
    reply_data(conn, Map.take(Storage.usage(prefix: params["prefix"] || ""), [:count, :bytes]))
  end

  operation(:delete,
    operation_id: "admin_delete_storage_object",
    summary: "Delete a stored object (admin)",
    security: [%{"authorization" => []}],
    parameters: [
      key: [in: :query, schema: %Schema{type: :string}, required: true]
    ],
    responses: [
      ok: {"Deleted", "application/json", OkResponse},
      bad_request: Schemas.error("Missing key / delete failed"),
      unauthorized: Schemas.error("Not authenticated"),
      forbidden: Schemas.error("Admin required")
    ]
  )

  def delete(conn, %{"key" => key}) when is_binary(key) and key != "" do
    case Storage.delete(key) do
      :ok -> reply_ok(conn)
      {:error, _} -> reply_error(conn, :bad_request, "delete_failed")
    end
  end

  def delete(conn, _), do: reply_error(conn, :bad_request, "missing_param", "key is required")

  operation(:upload,
    operation_id: "admin_upload_storage_object",
    summary: "Upload or overwrite an object at any key (admin)",
    security: [%{"authorization" => []}],
    parameters: [key: [in: :query, schema: %Schema{type: :string}, required: true]],
    request_body:
      {"Raw file bytes", "application/octet-stream", %Schema{type: :string, format: :binary}},
    responses: [
      created: {"Uploaded", "application/json", StorageObjectResponse},
      bad_request: Schemas.error("Missing key / upload failed"),
      request_entity_too_large: Schemas.error("Too large"),
      unauthorized: Schemas.error("Not authenticated"),
      forbidden: Schemas.error("Admin required")
    ]
  )

  def upload(conn, %{"key" => key}) when is_binary(key) and key != "" do
    content_type = Uploads.request_content_type(conn, "application/octet-stream")

    with {:ok, body, conn} <- Uploads.read_full_body(conn, Gamend.Limits.get(:max_upload_bytes)),
         {:ok, ^key} <- Storage.put(key, body, content_type: content_type) do
      reply_data(conn, :created, %{
        key: key,
        size: byte_size(body),
        last_modified: DateTime.utc_now(:second) |> DateTime.to_iso8601()
      })
    else
      {:error, :too_large} ->
        reply_error(conn, :request_entity_too_large, "too_large")

      _ ->
        reply_error(conn, :bad_request, "upload_failed")
    end
  end

  def upload(conn, _), do: reply_error(conn, :bad_request, "missing_param", "key is required")

  operation(:download,
    operation_id: "admin_download_storage_object",
    summary: "Download an object by key (admin)",
    security: [%{"authorization" => []}],
    parameters: [key: [in: :query, schema: %Schema{type: :string}, required: true]],
    responses: [
      ok: {"Object bytes", "application/octet-stream", %Schema{type: :string, format: :binary}},
      not_found: Schemas.error("Not found"),
      unauthorized: Schemas.error("Not authenticated"),
      forbidden: Schemas.error("Admin required")
    ]
  )

  def download(conn, %{"key" => key}) when is_binary(key) and key != "" do
    case Storage.get(key) do
      {:ok, data} ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type(MIME.from_path(key))
        |> send_resp(200, data)

      {:error, _} ->
        reply_error(conn, :not_found, "not_found")
    end
  end

  def download(conn, _), do: reply_error(conn, :bad_request, "missing_param", "key is required")

  defp serialize(obj) do
    %{
      key: obj.key,
      size: obj.size,
      last_modified: obj.last_modified && DateTime.to_iso8601(obj.last_modified)
    }
  end
end
