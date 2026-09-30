defmodule GamendWeb.SearchIndexControllerTest do
  @moduledoc """
  The search index endpoint.

  The locale handling is the part worth pinning. The palette fetches this in
  the background, and the reader has no idea it happened — so a fetch that
  wrote the locale to the session would silently decide what language their
  *next* page comes back in. That is why the locale is a query parameter on a
  path with no prefix, and why one of these tests fetches a German index from
  a French session and then checks the session is still French.
  """
  use GamendWeb.ConnCase, async: false

  defmodule StubProvider do
    @moduledoc false
    def entries(context), do: send_back(:entries, context)
    def scopes(context), do: send_back(:scopes, context)

    defp send_back(key, context) do
      case Application.get_env(:gamend_web, :search_test_owner) do
        pid when is_pid(pid) -> send(pid, {key, context})
        _ -> :ok
      end

      Application.get_env(:gamend_web, :"search_test_#{key}", [])
    end
  end

  defmodule RaisingProvider do
    @moduledoc false
    def entries(_context), do: raise("boom")
  end

  defmodule LiveProvider do
    @moduledoc false
    def entries(_context), do: []

    def search(query, context) do
      send(Application.get_env(:gamend_web, :search_test_owner), {:search, query, context})

      [%{title: query, href: "/hit/" <> query, group: "Words"}]
    end
  end

  setup context do
    previous = Application.get_env(:gamend_web, :search_provider)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:gamend_web, :search_provider)
      else
        Application.put_env(:gamend_web, :search_provider, previous)
      end

      Application.delete_env(:gamend_web, :search_test_owner)
      Application.delete_env(:gamend_web, :search_test_entries)
      Application.delete_env(:gamend_web, :search_test_scopes)
    end)

    if Map.has_key?(context, :provider) do
      Application.put_env(:gamend_web, :search_provider, context.provider)
    end

    :ok
  end

  defp stub(entries, scopes \\ []) do
    Application.put_env(:gamend_web, :search_provider, StubProvider)
    Application.put_env(:gamend_web, :search_test_owner, self())
    Application.put_env(:gamend_web, :search_test_entries, entries)
    Application.put_env(:gamend_web, :search_test_scopes, scopes)
  end

  describe "the default index" do
    test "serves JSON with the theme's navigation in it", %{conn: conn} do
      conn = get(conn, "/search/index.json")

      assert %{"entries" => entries} = json_response(conn, 200)
      assert Enum.any?(entries, &(&1["href"] == "/play"))

      leaderboards = Enum.find(entries, &(&1["href"] == "/leaderboards"))
      assert leaderboards["title"] == "Leaderboards"
      assert leaderboards["group"] == "Social"
    end

    test "is cacheable, but only by the reader's own browser", %{conn: conn} do
      conn = get(conn, "/search/index.json")

      assert get_resp_header(conn, "cache-control") == ["private, max-age=600"]
    end

    test "how long is a setting", %{conn: conn} do
      Gamend.SettingsHelpers.put(:gamend_web, GamendWeb.SearchIndex, :index_max_age_seconds, 3600)

      on_exit(fn ->
        Gamend.SettingsHelpers.delete(:gamend_web, GamendWeb.SearchIndex, :index_max_age_seconds)
      end)

      conn = get(conn, "/search/index.json")

      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end

    test "asking again for an unchanged index is a 304 with no body", %{conn: conn} do
      first = get(conn, "/search/index.json")
      assert [etag] = get_resp_header(first, "etag")

      again =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/search/index.json")

      assert again.status == 304
      assert again.resp_body == ""
      assert get_resp_header(again, "etag") == [etag]
    end

    test "a changed index is sent in full", %{conn: conn} do
      stub([%{title: "One", href: "/one"}])
      [etag] = conn |> get("/search/index.json") |> get_resp_header("etag")

      stub([%{title: "Two", href: "/two"}])

      changed =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/search/index.json")

      assert %{"entries" => [%{"href" => "/two"}]} = json_response(changed, 200)
    end

    test "a client asking for JSON is not turned away", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/search/index.json")

      assert json_response(conn, 200)
    end
  end

  describe "locale" do
    test "translates into the locale it is asked for", %{conn: conn} do
      conn = get(conn, "/search/index.json?locale=de")

      %{"entries" => entries} = json_response(conn, 200)

      assert Enum.any?(entries, &(&1["title"] == "Bestenlisten"))
    end

    test "does not change the reader's session locale", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{preferred_locale: "fr"})
        |> get("/search/index.json?locale=de")

      assert json_response(conn, 200)
      assert get_session(conn, :preferred_locale) == "fr"
    end

    test "an unknown locale falls back rather than failing", %{conn: conn} do
      conn = get(conn, "/search/index.json?locale=zz")

      assert %{"entries" => entries} = json_response(conn, 200)
      assert Enum.any?(entries, &(&1["title"] == "Leaderboards"))
    end
  end

  describe "the provider" do
    test "is handed the locale and the current scope", %{conn: conn} do
      stub([])

      conn |> get("/search/index.json?locale=de") |> json_response(200)

      assert_received {:entries, %{locale: "de", scope: nil}}
    end

    test "sees the signed-in reader's scope", %{conn: conn} do
      stub([])
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      conn |> get("/search/index.json") |> json_response(200)

      assert_received {:entries, %{scope: %Gamend.Accounts.Scope{}}}
    end

    test "entries are normalized and query tokens survive", %{conn: conn} do
      stub(
        [
          %{title: "  Spanish  ", href: "/vocabulary/spanish"},
          %{title: "", href: "/dropped"},
          %{title: "Search", href: "/vocabulary/spanish?q={q}", scope: "es_es"}
        ],
        ["es_es"]
      )

      %{"entries" => entries, "scopes" => scopes} =
        conn |> get("/search/index.json") |> json_response(200)

      assert [first, action] = entries
      assert first["title"] == "Spanish"
      assert action["href"] == "/vocabulary/spanish?q={q}"
      assert action["scope"] == "es_es"
      assert scopes == ["es_es"]
    end

    @tag provider: RaisingProvider
    test "a crash costs the index, not the request", %{conn: conn} do
      assert %{"entries" => []} = conn |> get("/search/index.json") |> json_response(200)
    end
  end

  describe "live queries" do
    @tag provider: LiveProvider
    test "reach the provider with the query and the reader's scopes", %{conn: conn} do
      Application.put_env(:gamend_web, :search_test_owner, self())

      %{"entries" => entries} =
        conn |> get("/search/query.json?q=casa&scopes=es_es,ro&locale=de") |> json_response(200)

      assert_received {:search, "casa", %{locale: "de", scopes: ["es_es", "ro"]}}
      assert [%{"href" => "/hit/casa", "group" => "Words"}] = entries
    end

    @tag provider: LiveProvider
    test "are cached for far less time than the index", %{conn: conn} do
      Application.put_env(:gamend_web, :search_test_owner, self())
      conn = get(conn, "/search/query.json?q=casa")

      assert get_resp_header(conn, "cache-control") == ["private, max-age=60"]
    end

    @tag provider: LiveProvider
    test "scopes arriving from a browser are filtered to the shape of a code", %{conn: conn} do
      Application.put_env(:gamend_web, :search_test_owner, self())

      conn |> get("/search/query.json?q=casa&scopes=../../etc,es_es,a+b") |> json_response(200)

      assert_received {:search, "casa", %{scopes: ["es_es"]}}
    end

    @tag provider: LiveProvider
    test "an empty query is not sent on at all", %{conn: conn} do
      Application.put_env(:gamend_web, :search_test_owner, self())

      assert %{"entries" => []} = conn |> get("/search/query.json?q=") |> json_response(200)
      refute_received {:search, _query, _context}
    end

    test "a provider with no live search answers nothing rather than failing", %{conn: conn} do
      # The default provider has an index and no `search/2`.
      assert %{"entries" => []} = conn |> get("/search/query.json?q=casa") |> json_response(200)
    end

    @tag provider: LiveProvider
    test "the index says a live search exists, so the palette knows to ask", %{conn: conn} do
      Application.put_env(:gamend_web, :search_test_owner, self())
      html = conn |> get("/privacy") |> html_response(200)

      assert html =~ ~s(data-query-url="/search/query.json?locale=en")
    end

    test "and says nothing when it does not", %{conn: conn} do
      refute conn |> get("/privacy") |> html_response(200) =~ "data-query-url"
    end
  end

  describe "when search is turned off" do
    @tag provider: false
    test "the index is gone", %{conn: conn} do
      conn = get(conn, "/search/index.json")

      assert json_response(conn, 404) == %{"error" => "search_disabled"}
    end

    @tag provider: false
    test "so are live queries", %{conn: conn} do
      assert json_response(get(conn, "/search/query.json?q=casa"), 404) == %{
               "error" => "search_disabled"
             }
    end
  end
end
