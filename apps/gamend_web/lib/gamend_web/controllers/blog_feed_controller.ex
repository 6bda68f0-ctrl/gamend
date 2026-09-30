defmodule GamendWeb.BlogFeedController do
  @moduledoc """
  The blog as a feed: `/blog/rss.xml` and `/blog/atom.xml`.

  Built by hand rather than through a library: a feed is forty lines of
  XML with six fields per entry, and the two dialects differ in little more
  than the names of those fields. Every text node goes through one escape.
  The site's title and description come from the theme, the way the pages
  get them; entries are `Gamend.Content.list_blog_posts/0`, newest first.
  """

  use GamendWeb, :controller

  alias Gamend.Content

  # A feed reader polls; a hundred posts is more than one needs, and the
  # whole archive on every poll is bytes nobody reads.
  @limit 50

  def rss(conn, _params) do
    {site, posts} = feed_data()

    items =
      Enum.map_join(posts, "\n", fn post ->
        """
            <item>
              <title>#{escape(post.title)}</title>
              <link>#{post_url(site, post)}</link>
              <guid isPermaLink="true">#{post_url(site, post)}</guid>
              <pubDate>#{rfc_2822(post.date)}</pubDate>
              <description>#{escape(post.excerpt)}</description>#{rss_authors(post)}
            </item>
        """
      end)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>#{escape(site.title)}</title>
        <link>#{site.url}/blog</link>
        <description>#{escape(site.description)}</description>
        <language>#{site.locale}</language>
        <atom:link href="#{site.url}/blog/rss.xml" rel="self" type="application/rss+xml"/>
    #{items}
      </channel>
    </rss>
    """

    send_xml(conn, "application/rss+xml", xml)
  end

  def atom(conn, _params) do
    {site, posts} = feed_data()

    updated =
      case posts do
        [newest | _] -> atom_time(newest.date)
        [] -> atom_time(Date.utc_today())
      end

    entries =
      Enum.map_join(posts, "\n", fn post ->
        """
          <entry>
            <title>#{escape(post.title)}</title>
            <link href="#{post_url(site, post)}"/>
            <id>#{post_url(site, post)}</id>
            <updated>#{atom_time(post.date)}</updated>
            <summary>#{escape(post.excerpt)}</summary>#{atom_authors(post)}
          </entry>
        """
      end)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>#{escape(site.title)}</title>
      <link href="#{site.url}/blog"/>
      <link href="#{site.url}/blog/atom.xml" rel="self"/>
      <id>#{site.url}/blog</id>
      <updated>#{updated}</updated>
    #{entries}
    </feed>
    """

    send_xml(conn, "application/atom+xml", xml)
  end

  defp feed_data do
    locale = Gettext.get_locale(GamendWeb.Gettext)
    theme = GamendWeb.Layouts.resolve_theme(locale, %{})

    site = %{
      url: GamendWeb.endpoint().url(),
      title: Map.get(theme, "title") || "Blog",
      description: Map.get(theme, "description") || "",
      locale: locale
    }

    {site, Content.list_blog_posts() |> Enum.take(@limit)}
  end

  defp post_url(site, post), do: "#{site.url}/blog/#{post.slug}"

  defp rss_authors(%{authors: [_ | _] = authors}) do
    "\n          <dc:creator xmlns:dc=\"http://purl.org/dc/elements/1.1/\">" <>
      escape(Enum.map_join(authors, ", ", & &1.name)) <> "</dc:creator>"
  end

  defp rss_authors(_post), do: ""

  defp atom_authors(%{authors: [_ | _] = authors}) do
    Enum.map_join(authors, "", fn author ->
      "\n        <author><name>#{escape(author.name)}</name>" <>
        if(author[:url], do: "<uri>#{escape(author.url)}</uri>", else: "") <> "</author>"
    end)
  end

  defp atom_authors(_post), do: ""

  # Midnight UTC on the post's date: a post has a day, not a time.
  defp rfc_2822(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")
  end

  defp atom_time(%Date{} = date) do
    date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()
  end

  defp send_xml(conn, type, xml) do
    conn
    |> put_resp_content_type(type)
    |> put_resp_header("cache-control", "public, max-age=900")
    |> send_resp(200, xml)
  end

  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
