defmodule GamendWeb.SearchIndexController do
  @moduledoc """
  The site search palette's index, as JSON.

  Fetched once per page load, on the first time the palette opens. Small
  enough to filter in the browser (a few hundred rows), which is what makes
  the palette feel instant — there is no request per keystroke.

  The locale arrives as a query parameter. A prefixed path would go through
  `GamendWeb.Plugs.LocalePath`, which stores the locale in the session, and a
  background fetch must not decide what language the reader's next page is in.
  """

  use GamendWeb, :controller

  alias GamendWeb.GettextSync
  alias GamendWeb.SearchIndex

  @query_cache_control "private, max-age=60"
  @max_query 100
  @max_scopes 6

  # The index is built from memory (the host's content rows are cached until
  # the content reloads), and the browser keeps it for
  # `search.index_max_age_seconds`. After that it asks again with the ETag it
  # holds, and an index that has not changed is a 304 with no body: the reader
  # downloads it once per content change, and a change still reaches them.
  # Not immutable: `scopes` and the navigation depend on who is reading.
  def show(conn, params) do
    if SearchIndex.enabled?() do
      locale = resolve_locale(params)
      GettextSync.put_locale(locale)

      context = %{scope: conn.assigns[:current_scope], locale: locale}
      body = %{entries: SearchIndex.entries(context), scopes: SearchIndex.scopes(context)}
      etag = ~s("#{body |> :erlang.phash2() |> Integer.to_string(36)}")

      conn =
        conn
        |> put_resp_header("cache-control", "private, max-age=#{index_max_age()}")
        |> put_resp_header("etag", etag)

      if etag in if_none_match(conn), do: send_resp(conn, 304, ""), else: json(conn, body)
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "search_disabled"})
    end
  end

  @doc """
  Rows for one query, from a provider that answers them live.

  Separate from the index and cached for a much shorter time: the index is the
  same for everyone on a locale and worth holding, while this is one reader's
  keystrokes.
  """
  def query(conn, params) do
    if SearchIndex.enabled?() do
      locale = resolve_locale(params)
      GettextSync.put_locale(locale)

      query =
        params |> Map.get("q", "") |> to_string() |> String.slice(0, @max_query) |> String.trim()

      context = %{
        scope: conn.assigns[:current_scope],
        locale: locale,
        scopes: scopes_param(params)
      }

      rows = if query == "", do: [], else: SearchIndex.search(query, context)

      conn
      |> put_resp_header("cache-control", @query_cache_control)
      |> json(%{entries: rows})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "search_disabled"})
    end
  end

  defp index_max_age, do: max(Gamend.Settings.get(SearchIndex, :index_max_age_seconds), 0)

  defp if_none_match(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
  end

  # What the page said the reader is most likely to mean. It arrives from the
  # browser, so it is filtered to the shape of a language code rather than
  # passed to a provider as typed.
  defp scopes_param(params) do
    params
    |> Map.get("scopes", "")
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/^[a-zA-Z0-9_-]{1,32}$/, &1))
    |> Enum.uniq()
    |> Enum.take(@max_scopes)
  end

  # An unknown locale is not an error: the palette asked for something this
  # host does not have, and the reader's session locale is a better answer
  # than a 400 they cannot see.
  defp resolve_locale(params) do
    GettextSync.normalize_locale(params["locale"]) || GettextSync.current_locale()
  end
end
