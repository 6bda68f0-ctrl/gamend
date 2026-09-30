defmodule GamendWeb.BlogFeedControllerTest do
  use GamendWeb.ConnCase, async: false

  alias Gamend.Content

  setup do
    root = Path.join(System.tmp_dir!(), "gamend_feed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "_authors"))

    File.write!(
      Path.join(root, "_authors/dragos.md"),
      "---\nname: Dragos\nurl: https://github.com/Ughuuu\n---\n"
    )

    File.write!(Path.join(root, "2026-08-02-hello.md"), """
    ---
    title: Hello & welcome
    slug: hello
    description: The first <post>.
    authors: [dragos]
    ---

    Body.
    """)

    File.write!(Path.join(root, "2026-09-01-second.md"), "# Second\n\nMore.\n")

    original = Application.get_env(:gamend_core, Gamend.Content, [])

    Application.put_env(
      :gamend_core,
      Gamend.Content,
      Keyword.put(original, :blog_candidates, [root])
    )

    Content.reload()

    on_exit(fn ->
      Application.put_env(:gamend_core, Gamend.Content, original)
      Content.reload()
      File.rm_rf(root)
    end)

    :ok
  end

  test "RSS lists the posts newest first with escaped text", %{conn: conn} do
    conn = get(conn, "/blog/rss.xml")

    assert response_content_type(conn, :xml) =~ "application/rss+xml"
    body = response(conn, 200)

    assert body =~ ~s(<rss version="2.0")
    assert body =~ "<title>Hello &amp; welcome</title>"
    assert body =~ "<description>The first &lt;post&gt;.</description>"
    assert body =~ "<dc:creator xmlns:dc=\"http://purl.org/dc/elements/1.1/\">Dragos</dc:creator>"
    assert body =~ "<pubDate>Sun, 02 Aug 2026 00:00:00 +0000</pubDate>"
    assert body =~ "/blog/hello</link>"

    [second, hello] =
      Regex.scan(~r/<item>.*?<title>([^<]+)<\/title>/s, body) |> Enum.map(&List.last/1)

    assert second == "Second"
    assert hello == "Hello &amp; welcome"
  end

  test "Atom carries the same entries", %{conn: conn} do
    conn = get(conn, "/blog/atom.xml")

    assert response_content_type(conn, :xml) =~ "application/atom+xml"
    body = response(conn, 200)

    assert body =~ ~s(<feed xmlns="http://www.w3.org/2005/Atom">)
    assert body =~ "<updated>2026-09-01T00:00:00Z</updated>"
    assert body =~ "<author><name>Dragos</name><uri>https://github.com/Ughuuu</uri></author>"

    assert body =~ ~s(<link href="http://localhost:4002/blog/hello"/>) or
             body =~ "/blog/hello\"/>"
  end

  # The feed routes sit before `/blog/:slug`; a post is still a post.
  test "a post named like a feed is still a post", %{conn: conn} do
    assert conn |> get("/blog/hello") |> html_response(200) =~ "Hello &amp; welcome"
  end
end
