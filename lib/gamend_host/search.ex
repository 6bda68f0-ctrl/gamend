defmodule GamendHost.Search do
  @moduledoc """
  What the site search palette finds on this host.

  Core owns the palette — the button, the dialog, the ranking, the keyboard —
  and this owns the catalogue. Everything here is derived from the same
  `Gamend.Content` collections the pages themselves render from, so a guide or
  a post cannot exist on the site and be missing from search.

  The navigation comes first because `GamendWeb.SearchIndex` dedupes by href
  and keeps the first row it saw: `/blog` is the nav's own link, not a post
  that happens to share the path.

  Only destinations, no query actions: every answerable thing on this host is
  a page or a section of one, and together they are small enough to send in
  the index (about 600 rows). A host whose content is too large to enumerate —
  a dictionary, a product catalogue — implements
  `c:GamendWeb.SearchIndex.Provider.search/2` as well.

  ## Cost

  The content rows are built once per locale and kept by
  `Gamend.Content.memoize/2` until the content reloads, so opening the
  palette costs a cache read plus the navigation, which depends on who is
  asking. The browser fetches the index once and filters it in memory.
  """

  @behaviour GamendWeb.SearchIndex.Provider

  use Gettext, backend: GamendHost.Gettext

  alias Gamend.Content
  alias GamendWeb.SearchIndex

  @impl true
  def entries(context) do
    SearchIndex.navigation_entries(context) ++ content_entries()
  end

  # Keyed by locale because the group labels are translated. Sections come
  # last: at an equal rank the palette keeps the host's order, so a guide
  # whose title matches stays above its own sections.
  defp content_entries do
    locale = Gettext.get_locale(GamendHost.Gettext)

    Content.memoize({__MODULE__, :entries, locale}, fn ->
      doc_entries() ++ blog_entries() ++ section_entries()
    end)
  end

  # One heading for every guide rather than one per category. A category title
  # comes from its `_category.md` and is English only, so seven of them would
  # put seven untranslated headings in a palette whose every other heading is
  # translated. The category is not lost — it rides along as a keyword, so
  # "monetization" still finds the guides under it without being printed on
  # each row.
  defp doc_entries do
    group = gettext("Documentation")

    Enum.flat_map(Content.list_doc_categories(), fn %{category: category, guides: guides} ->
      Enum.map(guides, fn doc ->
        %{
          title: doc.title,
          href: "/docs/#{doc.slug}",
          group: group,
          subtitle: doc.summary,
          keywords: [category | doc.keywords]
        }
      end)
    end)
  end

  # Every `##` and `###` of every guide, linking to its anchor, so a word that
  # names a section ("Usernames") finds it rather than the guide that holds
  # it. The subtitle says which guide, then the section's first sentence: the
  # palette matches its words too, below titles and keywords.
  defp section_entries do
    group = gettext("Documentation")

    for %{guides: guides} <- Content.list_doc_categories(),
        doc <- guides,
        section <- Content.doc_sections(doc.slug) do
      %{
        title: section.text,
        href: "/docs/#{doc.slug}##{section.id}",
        group: group,
        subtitle: Enum.join(Enum.reject([doc.title, section.lede], &is_nil/1), " · ")
      }
    end
  end

  # The date and not the excerpt: the subtitle is the truncated right-hand half
  # of a row, and half of a first sentence tells a reader less than knowing
  # which post is the recent one.
  defp blog_entries do
    group = gettext("Blog")

    Enum.map(Content.list_blog_posts(), fn post ->
      %{
        title: post.title,
        href: "/blog/#{post.slug}",
        group: group,
        subtitle: blog_date(post),
        keywords: post.keywords
      }
    end)
  end

  defp blog_date(%{date: %Date{} = date}), do: Date.to_iso8601(date)
  defp blog_date(_post), do: nil
end
