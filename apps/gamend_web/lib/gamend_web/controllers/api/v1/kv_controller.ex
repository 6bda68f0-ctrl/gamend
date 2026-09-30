defmodule GamendWeb.Api.V1.KvController do
  use GamendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Gamend.Accounts.Scope
  alias Gamend.Accounts.User
  alias Gamend.Hooks
  alias Gamend.KV
  alias GamendWeb.Schemas
  alias GamendWeb.Schemas.KvEntryResponse
  alias OpenApiSpex.Schema

  tags(["KV"])

  operation(:show,
    operation_id: "get_kv",
    summary: "Get a key/value entry",
    security: [%{"authorization" => []}],
    parameters: [
      key: [in: :path, schema: %Schema{type: :string}, description: "Key", required: true],
      user_id: [
        in: :query,
        schema: %Schema{type: :string, format: :uuid},
        description: "Optional owner user id",
        required: false
      ],
      lobby_id: [
        in: :query,
        schema: %Schema{type: :string, format: :uuid},
        description: "Optional owner lobby id",
        required: false
      ]
    ],
    responses: [
      ok: {"KV entry", "application/json", KvEntryResponse},
      unauthorized: Schemas.error("Not authenticated"),
      not_found: Schemas.error("No entry for that key and owner"),
      forbidden: Schemas.error("The key's access rule, or `before_kv_get`, refused")
    ]
  )

  def show(conn, %{"key" => key} = params) do
    user_id = Gamend.UUIDv7.cast_or_nil(params["user_id"])
    lobby_id = Gamend.UUIDv7.cast_or_nil(params["lobby_id"])

    # Resolve the plug-assigned scope to the fresh caller user (route is
    # authenticated via :api_auth).
    caller = Scope.user(Map.get(conn.assigns, :current_scope))

    case Hooks.internal_call(:before_kv_get, [key, %{user_id: user_id, lobby_id: lobby_id}],
           caller: caller
         ) do
      {:ok, access} ->
        if kv_access_allowed?(access, caller, user_id, lobby_id) do
          do_get(conn, key, user_id, lobby_id)
        else
          forbidden(conn)
        end

      {:error, _reason} ->
        forbidden(conn)
    end
  end

  defp kv_access_allowed?(:public, _caller, _user_id, _lobby_id), do: true

  defp kv_access_allowed?(:owner_only, caller, user_id, _lobby_id),
    do: caller_owns?(caller, user_id)

  defp kv_access_allowed?(:lobby_members_only, caller, _user_id, lobby_id),
    do: caller_in_lobby?(caller, lobby_id)

  defp kv_access_allowed?(:owner_or_lobby_member, caller, user_id, lobby_id),
    do: caller_owns?(caller, user_id) or caller_in_lobby?(caller, lobby_id)

  defp kv_access_allowed?(:admin_only, caller, _user_id, _lobby_id), do: caller_admin?(caller)
  defp kv_access_allowed?(:server_only, _caller, _user_id, _lobby_id), do: false
  defp kv_access_allowed?(_access, _caller, _user_id, _lobby_id), do: false

  defp caller_owns?(%User{id: caller_id}, user_id),
    do: is_binary(user_id) and caller_id == user_id

  defp caller_owns?(_caller, _user_id), do: false

  defp caller_in_lobby?(%User{lobby_id: caller_lobby_id}, lobby_id),
    do: is_binary(lobby_id) and caller_lobby_id == lobby_id

  defp caller_in_lobby?(_caller, _lobby_id), do: false

  defp caller_admin?(%User{is_admin: true}), do: true
  defp caller_admin?(_caller), do: false

  defp forbidden(conn), do: reply_error(conn, :forbidden, "forbidden")

  defp do_get(conn, key, user_id, lobby_id) do
    case KV.get(key, user_id: user_id, lobby_id: lobby_id) do
      {:ok, %{value: value, metadata: metadata}} ->
        reply_data(conn, %{
          key: key,
          user_id: user_id || "",
          lobby_id: lobby_id || "",
          data: value,
          metadata: metadata
        })

      :error ->
        reply_error(conn, :not_found, "not_found")
    end
  end
end
