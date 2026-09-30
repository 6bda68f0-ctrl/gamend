defmodule GamendWeb.SearchIndex do
  @moduledoc """
  The site search palette's index: what the host offers, cleaned up.

  `GamendWeb.SearchIndex.Provider` is the contract a host implements; this is
  the edge around it. Everything a provider returns is treated as data from
  somewhere else — the host is trusted, but a typo in one entry must not cost
  the whole palette — so a bad entry is dropped rather than raised on, and a
  provider that crashes yields an empty index and a logged warning.

  Hrefs arrive clean (`/guide/hangman`) and leave localized
  (`/ro/guide/hangman`): the provider should not have to know about locale
  prefixes, and `HostLayouts.localized_href/2` already knows which paths have
  translations.
  """

  require Logger

  use Gamend.Settings.Provider,
    app: :gamend_web,
    group: :search,
    label: "Search"

  setting(:index_max_age_seconds, :integer,
    default: 600,
    doc:
      "How long a browser keeps the search index before it asks again. Asking again " <>
        "costs a body-less 304 when nothing changed, so this bounds how soon new " <>
        "content shows up, not how often the index is downloaded."
  )

  alias GamendWeb.HostLayoutNavigation
  alias GamendWeb.HostLayouts
  alias GamendWeb.SearchIndex.Default
  alias GamendWeb.SearchIndex.Provider

  @index_path "/search/index.json"
  @query_path "/search/query.json"

  # A `{Module.fn}` token that resolved to nothing leaves an empty label; that
  # is a row with no words on it, so it is not a row.
  @max_keywords 12

  @doc """
  The configured provider, or `false` when search is off.

  `nil` (unset) is not off — it is the default provider, so a host that
  configures nothing still gets its navigation links in the palette.
  """
  @spec provider() :: module() | false
  def provider do
    case Application.get_env(:gamend_web, :search_provider, Default) do
      false -> false
      nil -> false
      module when is_atom(module) -> module
      _other -> false
    end
  end

  @doc "Whether to render the search button and serve the index."
  @spec enabled?() :: boolean()
  def enabled?, do: provider() != false

  @doc """
  Where the palette fetches its index.

  The locale travels as a query parameter, not a path prefix: a prefixed URL
  would be handled by `GamendWeb.Plugs.LocalePath`, which writes the locale to
  the session, and a background fetch must never change what language the
  reader's *next* page comes back in. As a bonus the parameter keys the
  browser's cache, so switching language cannot replay the previous one's
  index.
  """
  @spec index_path(String.t()) :: String.t()
  def index_path(locale) when is_binary(locale), do: @index_path <> "?locale=" <> locale
  def index_path(_locale), do: @index_path

  @doc "The index route's path, without a locale."
  @spec index_path() :: String.t()
  def index_path, do: @index_path

  @doc """
  The host's entries, validated and localized.

  Returns `[]` when search is disabled, when the provider is not loadable, or
  when it raises.
  """
  @spec entries(Provider.context()) :: [map()]
  def entries(context) do
    context
    |> call_provider(:entries, [])
    |> Enum.map(&normalize_entry(&1, context))
    |> Enum.reject(&is_nil/1)
    |> dedupe_by_href()
  end

  @doc """
  The scopes the server suggests, most relevant first.

  Optional for a provider; `[]` when it does not implement `c:scopes/1`.
  """
  @spec scopes(Provider.context()) :: [String.t()]
  def scopes(context) do
    context
    |> call_provider(:scopes, [])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc """
  Whether the provider answers live queries as well as holding an index.
  """
  @spec live?() :: boolean()
  def live? do
    module = provider()

    module != false and Code.ensure_loaded?(module) and function_exported?(module, :search, 2)
  end

  @doc "Where the palette sends a query the index cannot answer itself."
  @spec query_path(String.t()) :: String.t()
  def query_path(locale) when is_binary(locale), do: @query_path <> "?locale=" <> locale
  def query_path(_locale), do: @query_path

  @doc """
  Rows for one query, from a provider that answers them.

  Validated and localized exactly as `entries/1` is, and `[]` for a provider
  that does not implement `c:GamendWeb.SearchIndex.Provider.search/2`.
  """
  @spec search(String.t(), Provider.context()) :: [map()]
  def search(query, context) when is_binary(query) do
    if live?() do
      provider()
      |> safely(:search, [query, context], [])
      |> Enum.map(&normalize_entry(&1, context))
      |> Enum.reject(&is_nil/1)
      |> dedupe_by_href()
    else
      []
    end
  end

  def search(_query, _context), do: []

  @doc """
  The theme's navigation as search entries.

  The default provider is this and nothing else; a host that supplies its own
  provider usually starts with this list and adds its content to it.
  """
  @spec navigation_entries(Provider.context()) :: [map()]
  def navigation_entries(%{} = context) do
    scope = Map.get(context, :scope)
    locale = Map.get(context, :locale) || HostLayouts.current_locale()

    locale
    |> HostLayouts.navigation()
    |> HostLayoutNavigation.flat_links(scope)
  end

  def navigation_entries(_context), do: []

  # ── the provider edge ────────────────────────────────────────────────────

  defp call_provider(context, fun, default), do: safely(provider(), fun, [context], default)

  defp safely(module, fun, args, default) do
    with true <- module != false,
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, fun, length(args)),
         result when is_list(result) <- apply(module, fun, args) do
      result
    else
      _ -> default
    end
  rescue
    error ->
      Logger.warning(
        "search provider #{inspect(provider())}.#{fun} raised: #{Exception.message(error)}"
      )

      default
  catch
    kind, reason ->
      Logger.warning("search provider #{inspect(provider())}.#{fun} #{kind}: #{inspect(reason)}")

      default
  end

  # ── normalization ────────────────────────────────────────────────────────

  defp normalize_entry(%{} = entry, context) do
    title = string_at(entry, :title)
    href = string_at(entry, :href)

    if title == "" or href == "" do
      nil
    else
      %{
        "title" => title,
        "href" => localize(href, context),
        "group" => Gamend.Parse.blank_to_nil(string_at(entry, :group)),
        "subtitle" => Gamend.Parse.blank_to_nil(string_at(entry, :subtitle)),
        "keywords" => keywords_at(entry),
        "scope" => Gamend.Parse.blank_to_nil(string_at(entry, :scope))
      }
    end
  end

  defp normalize_entry(_entry, _context), do: nil

  # An external href (`https://…`, `//…`) is left exactly as the host wrote it.
  defp localize("/" <> _ = href, context) do
    case Map.get(context, :locale) do
      locale when is_binary(locale) -> HostLayouts.localized_href(href, locale)
      _ -> href
    end
  end

  defp localize(href, _context), do: href

  defp keywords_at(entry) do
    entry
    |> value_at(:keywords)
    |> List.wrap()
    |> Enum.map(&to_string_safe/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_keywords)
  end

  # Entries are written as atom-keyed maps in Elixir, but a provider that
  # builds them from JSON or a database row hands over strings.
  defp value_at(entry, key) do
    case Map.fetch(entry, key) do
      {:ok, value} -> value
      :error -> Map.get(entry, Atom.to_string(key))
    end
  end

  defp string_at(entry, key), do: entry |> value_at(key) |> to_string_safe() |> String.trim()

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp to_string_safe(_value), do: ""

  # First one wins: a host listing its own entries after the navigation ones
  # does not shadow a nav link, and nothing is offered twice.
  defp dedupe_by_href(entries) do
    {kept, _seen} =
      Enum.reduce(entries, {[], MapSet.new()}, fn entry, {kept, seen} ->
        href = entry["href"]

        if MapSet.member?(seen, href) do
          {kept, seen}
        else
          {[entry | kept], MapSet.put(seen, href)}
        end
      end)

    Enum.reverse(kept)
  end
end
