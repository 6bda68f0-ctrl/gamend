defmodule GamendWeb.Schemas.Envelope do
  @moduledoc """
  The response envelopes, declared once instead of restated per entity.

      defmodule GamendWeb.Schemas.LobbyPage do
        use GamendWeb.Schemas.Envelope, page: GamendWeb.Schemas.Lobby
      end

  - `page: T` is `{data: [T], meta: PageMeta}`, every paginated list.
  - `data: T` is `{data: T}`; `extra:` adds properties beside `data`, and
    `required:` names which of them are always sent.

  The component's title is the module's last segment, so the name a
  generator emits is the name in the code.
  """

  alias GamendWeb.Schemas.PageMeta
  alias OpenApiSpex.Schema

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts, envelope: __MODULE__] do
      require OpenApiSpex

      OpenApiSpex.schema(envelope.build(__MODULE__ |> Module.split() |> List.last(), opts))
    end
  end

  @doc false
  @spec build(String.t(), keyword()) :: map()
  def build(title, opts) do
    case Keyword.fetch(opts, :page) do
      {:ok, item} ->
        %{
          title: title,
          description: Keyword.get(opts, :description, "A page of #{title_of(item)} rows"),
          type: :object,
          properties: %{data: %Schema{type: :array, items: item}, meta: PageMeta},
          required: [:data, :meta]
        }

      :error ->
        data = Keyword.fetch!(opts, :data)

        %{
          title: title,
          description: Keyword.get(opts, :description, "#{title_of(data)} under `data`"),
          type: :object,
          properties: Map.put(Keyword.get(opts, :extra, %{}), :data, data),
          required: [:data | Keyword.get(opts, :required, [])]
        }
    end
  end

  defp title_of(module) when is_atom(module), do: module.schema().title
  defp title_of(%Schema{title: title}) when is_binary(title), do: title
  defp title_of(_schema), do: "the result"
end
