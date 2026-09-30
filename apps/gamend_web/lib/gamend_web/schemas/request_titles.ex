defmodule GamendWeb.Schemas.RequestTitles do
  @moduledoc """
  Titles every inline request body `<OperationId>Request`.

  A generator names an untitled inline body after its operation, which is the
  name anyone would choose, but it merges bodies that are identical down to
  their descriptions and keeps the first operation's name for all of them. So
  the player's own avatar upload took an `AdminSetQuestIconRequest` and
  `join_lobby` a `PartyJoinLobbyRequest`: 21 operations, all bodies shared
  through a controller attribute. A title makes each body distinct and names
  it explicitly — the same name the generator already gave every body it did
  not merge, so nothing else moves.

  Applied once, as the last step of `GamendWeb.ApiSpec.spec/0`. A body that
  already has a title, or is not an object with properties, is left alone.
  """

  alias OpenApiSpex.{MediaType, OpenApi, Operation, PathItem, RequestBody, Schema}

  @verbs [:get, :put, :post, :delete, :options, :head, :patch, :trace]

  @spec put_titles(OpenApi.t()) :: OpenApi.t()
  def put_titles(%OpenApi{paths: paths} = spec) do
    %{spec | paths: Map.new(paths, fn {path, item} -> {path, title_item(item)} end)}
  end

  @doc "The title a body of `operation_id` gets: `join_lobby` → `JoinLobbyRequest`."
  @spec title(String.t()) :: String.t()
  def title(operation_id), do: Macro.camelize(operation_id) <> "Request"

  defp title_item(%PathItem{} = item) do
    Enum.reduce(@verbs, item, fn verb, acc ->
      case Map.get(acc, verb) do
        %Operation{} = operation -> Map.put(acc, verb, title_operation(operation))
        _ -> acc
      end
    end)
  end

  defp title_operation(
         %Operation{operationId: id, requestBody: %RequestBody{content: %{} = content} = body} =
           operation
       ) do
    content = Map.new(content, fn {type, media} -> {type, title_media(media, id)} end)
    %{operation | requestBody: %{body | content: content}}
  end

  defp title_operation(operation), do: operation

  defp title_media(
         %MediaType{schema: %Schema{title: nil, properties: %{} = props} = schema} = media,
         id
       )
       when map_size(props) > 0,
       do: %{media | schema: %{schema | title: title(id)}}

  defp title_media(media, _id), do: media
end
