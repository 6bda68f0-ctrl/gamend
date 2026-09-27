defmodule GamendWeb.ContentPages do
  @moduledoc """
  The changelog, roadmap and blog pages: one markup, two rendering styles.

  ## Why components rather than one LiveView

  gamend serves these as LiveViews; Polyglot Pirates serves them from a plain
  controller, because a changelog has nothing live on it and a dead render is
  one less socket. Both are defensible, and neither host should have to change
  to share the page — so what is shared is the *markup*, which a LiveView's
  `render/1` and a `.html.heex` template can both call.

  The three copies that existed before this said the same thing in three
  slightly different ways, and the differences were all accidents: gamend's
  `page_title` was an untranslated string and its empty-state body was an
  English literal, while Polyglot's had a card around the article and a
  reusable empty state. Nothing chose any of that; one was written after the
  other.

  The blog arrived here later for exactly that reason. It stayed a shim that
  looked up `GamendWeb.HostBlogLive` by name, so each host wrote the page
  itself: gamend and the starter carried byte-identical 237-line copies, each
  with its own private `group_blog_posts/1` reimplementing
  `Gamend.Content.blog_posts_grouped/0` — which was therefore dead in core. The
  copies had already drifted: the starter rendered dates with
  `Calendar.strftime`, so they never picked up the reader's timezone the way
  `<.timestamp>` does.

  ## `href`, not `navigate`

  The cross-links between the two pages are plain anchors. `navigate` needs a
  LiveView root to push into, and on a controller-rendered page there is none —
  it would render an `<a>` that the client script treats as live and the server
  has nowhere to route. These are static documents where a full navigation is
  what happens anyway.
  """

  use GamendWeb, :html

  attr :flash, :map, required: true
  attr :current_scope, :any, default: nil
  attr :current_path, :string, default: nil
  attr :html, :string, default: nil
  attr :roadmap_available?, :boolean, default: false

  @doc "The changelog page, with a link across to the roadmap when there is one."
  def changelog(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.content_page
        title={gettext("Changelog")}
        html={@html}
        sibling_path={@roadmap_available? && ~p"/roadmap"}
        sibling_icon="hero-map"
        sibling_label={gettext("Roadmap")}
        empty_icon="hero-document-text"
        empty_text={gettext("Add a changelog file at CHANGELOG.md to display it here.")}
      />
    </Layouts.app>
    """
  end

  attr :flash, :map, required: true
  attr :current_scope, :any, default: nil
  attr :current_path, :string, default: nil
  attr :html, :string, default: nil
  attr :changelog_available?, :boolean, default: false

  @doc "The roadmap page, with a link across to the changelog when there is one."
  def roadmap(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.content_page
        title={gettext("Roadmap")}
        html={@html}
        sibling_path={@changelog_available? && ~p"/changelog"}
        sibling_icon="hero-document-text"
        sibling_label={gettext("Changelog")}
        empty_icon="hero-map"
        empty_text={gettext("Add a roadmap file at ROADMAP.md to display it here.")}
      />
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :html, :string, default: nil
  attr :sibling_path, :any, default: nil
  attr :sibling_icon, :string, required: true
  attr :sibling_label, :string, required: true
  attr :empty_icon, :string, required: true
  attr :empty_text, :string, required: true

  # The two pages differ only in their copy and which way the cross-link
  # points, so the shape is written once. `sibling_path` is false rather than
  # nil when the other page has no file, which `:if` reads the same way.
  defp content_page(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-row items-center justify-between gap-3">
        <h1 class="text-4xl font-black text-base-content/95">{@title}</h1>

        <.link :if={@sibling_path} href={@sibling_path} class="btn btn-outline btn-sm">
          <.icon name={@sibling_icon} class="size-4" />
          {@sibling_label}
        </.link>
      </div>

      <section
        :if={@html}
        class="rounded-3xl border border-base-300 bg-base-100/90 p-5 shadow-sm sm:p-8"
      >
        <article class="markdown-content">{raw(@html)}</article>
      </section>

      <.empty_state :if={!@html} icon={@empty_icon} title={gettext("No results.")} text={@empty_text} />
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :current_scope, :any, default: nil
  attr :current_path, :string, default: nil
  attr :blog_available?, :boolean, default: false
  attr :grouped_posts, :list, default: []
  attr :changelog_available?, :boolean, default: false
  attr :roadmap_available?, :boolean, default: false

  attr :grid?, :boolean,
    default: false,
    doc: "cards two and three to a row, see `GamendWeb.BlogLive.layout/1`"

  @doc """
  The blog index: every post grouped by year and month, newest first.

  Takes `grouped_posts` in the shape `Gamend.Content.blog_posts_grouped/0`
  returns.
  """
  def blog_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class={[
        "mx-auto px-4 py-8 sm:px-6",
        if(@grid?, do: "max-w-6xl", else: "max-w-4xl")
      ]}>
        <.empty_state
          :if={!@blog_available?}
          icon="hero-newspaper"
          title={gettext("No results.")}
          text={gettext("Register a blog directory to display posts here.")}
        />

        <div :if={@blog_available?}>
          <div class="mb-8 flex items-center justify-between">
            <h1 class="text-3xl font-bold">{gettext("Blog")}</h1>

            <div class="flex items-center gap-3">
              <.link
                :if={@roadmap_available?}
                href={~p"/roadmap"}
                class="inline-flex items-center gap-1.5 text-sm text-base-content/70 transition-colors hover:text-primary"
              >
                <.icon name="hero-map" class="size-4" /> {gettext("Roadmap")}
              </.link>
              <.link
                :if={@changelog_available?}
                href={~p"/changelog"}
                class="inline-flex items-center gap-1.5 text-sm text-base-content/70 transition-colors hover:text-primary"
              >
                <.icon name="hero-document-text" class="size-4" /> {gettext("Changelog")}
              </.link>
            </div>
          </div>

          <.empty_state
            :if={@grouped_posts == []}
            icon="hero-pencil-square"
            title={gettext("No results.")}
          />

          <div :if={@grouped_posts != []} class="space-y-10">
            <section :for={{year, months} <- @grouped_posts}>
              <h2 class="mb-6 border-b border-base-300 pb-2 text-2xl font-bold text-base-content/90">
                {year}
              </h2>

              <div :for={{month, posts} <- months} class="mb-8">
                <h3 class="mb-4 text-sm font-semibold uppercase tracking-[0.22em] text-base-content/70">
                  <.month_heading year={year} month={month} />
                </h3>

                <div class={
                  if(@grid?,
                    do: "grid gap-5 sm:grid-cols-2 lg:grid-cols-3",
                    else: "space-y-4"
                  )
                }>
                  <article
                    :for={post <- posts}
                    class="overflow-hidden rounded-3xl border border-base-300 bg-base-100/95 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md"
                  >
                    <.link
                      navigate={~p"/blog/#{post.slug}"}
                      class={if(@grid?, do: "flex h-full flex-col", else: "block sm:flex")}
                    >
                      <%!-- The cover, when the post has one: cropped to a
                            landscape tile beside the text in the list, above
                            it in the grid, whole on the post itself. --%>
                      <img
                        :if={post[:image]}
                        src={post.image}
                        alt=""
                        loading="lazy"
                        decoding="async"
                        class={[
                          "aspect-video w-full object-cover",
                          !@grid? && "sm:w-64 sm:shrink-0"
                        ]}
                      />
                      <div class="space-y-2 p-5">
                        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs uppercase tracking-[0.18em] text-base-content/70">
                          <span><.timestamp at={post.date} format="date" /></span>
                          <span :if={post[:reading_minutes]}>
                            {ngettext("%{count} min read", "%{count} min read", post.reading_minutes)}
                          </span>
                        </div>

                        <h4 class="text-xl font-semibold text-base-content/90 transition-colors hover:text-primary">
                          {post.title}
                        </h4>

                        <p class="text-sm leading-6 text-base-content/70">{post.excerpt}</p>

                        <.post_authors
                          :if={post[:authors] not in [nil, []]}
                          authors={post.authors}
                          links?={false}
                        />
                      </div>
                    </.link>
                  </article>
                </div>
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :flash, :map, required: true
  attr :current_scope, :any, default: nil
  attr :current_path, :string, default: nil
  attr :post, :map, required: true
  attr :html, :string, default: nil
  attr :prev, :any, default: nil
  attr :next, :any, default: nil

  @doc "One blog post, with links to the neighbouring posts."
  def blog_post(assigns) do
    assigns = assign(assigns, :cover, cover(assigns.post, assigns.html))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class="mx-auto max-w-4xl px-4 py-8 sm:px-6">
        <article class="space-y-10">
          <div class="space-y-4">
            <div class="flex flex-wrap items-center gap-3 text-xs uppercase tracking-[0.2em] text-base-content/70">
              <.link navigate={~p"/blog"} class="transition-colors hover:text-primary">
                {gettext("Blog")}
              </.link>
              <span>/</span>
              <span><.timestamp at={@post.date} format="date" /></span>
              <span :if={@post[:reading_minutes]}>
                · {ngettext("%{count} min read", "%{count} min read", @post.reading_minutes)}
              </span>
            </div>

            <div class="space-y-3">
              <h1 class="text-4xl font-bold leading-tight text-base-content/95 sm:text-5xl">
                {@post.title}
              </h1>
              <p class="max-w-2xl text-base leading-7 text-base-content/70">{@post.excerpt}</p>
              <.post_authors :if={@post[:authors] not in [nil, []]} authors={@post.authors} />
            </div>

            <img
              :if={@cover}
              src={@cover}
              alt=""
              decoding="async"
              class="w-full rounded-2xl border border-base-300"
            />
          </div>

          <article class="markdown-content">{raw(@html)}</article>

          <%!-- `Content.blog_neighbours/1` walks a newest-first list, so `prev`
                is the NEWER post and `next` the older one. --%>
          <div class="grid gap-4 border-t border-base-300 pt-6 md:grid-cols-2">
            <div>
              <.link
                :if={@prev}
                navigate={~p"/blog/#{@prev.slug}"}
                class="group flex h-full flex-col rounded-2xl border border-base-300 bg-base-100/90 p-4 transition hover:-translate-y-0.5 hover:border-primary/30 hover:shadow-md"
              >
                <span class="text-xs uppercase tracking-[0.2em] text-base-content/70">
                  {gettext("Newer")}
                </span>
                <span class="mt-2 text-lg font-semibold text-base-content/90 group-hover:text-primary">
                  {@prev.title}
                </span>
              </.link>
            </div>
            <div>
              <.link
                :if={@next}
                navigate={~p"/blog/#{@next.slug}"}
                class="group flex h-full flex-col rounded-2xl border border-base-300 bg-base-100/90 p-4 text-right transition hover:-translate-y-0.5 hover:border-primary/30 hover:shadow-md"
              >
                <span class="text-xs uppercase tracking-[0.2em] text-base-content/70">
                  {gettext("Older")}
                </span>
                <span class="mt-2 text-lg font-semibold text-base-content/90 group-hover:text-primary">
                  {@next.title}
                </span>
              </.link>
            </div>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  The picture to show above a post, or nil. The frontmatter `image` is the
  card's and the link preview's; a post that also shows it in its body, as
  the same file or the same name in another format (`x.webp` for `x.png`),
  would show it twice, so the page leaves it to the body.
  """
  @spec cover(map(), String.t() | nil) :: String.t() | nil
  def cover(post, html) do
    case post[:image] do
      image when is_binary(image) and image != "" ->
        shown = for [_, src] <- Regex.scan(~r/<img[^>]+src="([^"]+)"/, html || ""), do: stem(src)
        if stem(image) in shown, do: nil, else: image

      _ ->
        nil
    end
  end

  defp stem(src), do: src |> String.split(["?", "#"]) |> hd() |> Path.rootname()

  attr :authors, :list, required: true
  attr :links?, :boolean, default: true

  # Who wrote it: a name, its role when the author file gives one, an avatar
  # when it gives that, and a link when it gives a URL. A post's `authors:`
  # keys that have no file still show as names. On an index card the whole
  # card is already a link, and a link inside a link is not HTML: the parser
  # closes the card's early and the text falls out of it. So `links?: false`
  # there, and the name links from the post itself.
  defp post_authors(assigns) do
    ~H"""
    <ul class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
      <li :for={author <- @authors} class="flex items-center gap-2">
        <img
          :if={author[:image]}
          src={author.image}
          alt=""
          loading="lazy"
          class="size-7 rounded-full border border-base-300"
        />
        <span class="flex flex-col leading-tight">
          <a
            :if={@links? and author[:url]}
            href={author.url}
            class="font-medium link link-hover"
            rel="noopener"
          >
            {author.name}
          </a>
          <span :if={!(@links? and author[:url])} class="font-medium">{author.name}</span>
          <span :if={author[:title]} class="text-xs text-base-content/70">{author.title}</span>
        </span>
      </li>
    </ul>
    """
  end

  attr :year, :integer, required: true
  attr :month, :integer, required: true

  # The month in the reader's language. This used to pass `Calendar.strftime`'s
  # English name through `dgettext` — but no catalog carries month names, so it
  # always came back in English while its comment said otherwise. The browser's
  # `Intl` already knows every locale's months: `local_time.js` translates this
  # with the zone pinned to UTC. Without JS the English name stands.
  defp month_heading(assigns) do
    assigns =
      assign(assigns,
        iso: "#{assigns.year}-#{String.pad_leading(to_string(assigns.month), 2, "0")}",
        english: Calendar.strftime(Date.new!(assigns.year, assigns.month, 1), "%B")
      )

    ~H"""
    <time datetime={@iso} data-local-time="calendar-month">{@english}</time>
    """
  end
end
