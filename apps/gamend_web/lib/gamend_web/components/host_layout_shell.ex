defmodule GamendWeb.HostLayoutShell do
  @moduledoc false

  use GamendWeb, :html

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :current_path, :string, default: nil
  attr :current_query, :string, default: ""
  attr :flush, :boolean, default: false
  attr :wide, :boolean, default: false
  attr :theme, :map, required: true
  attr :navigation, :map, default: %{}
  attr :footer, :map, default: %{}
  attr :background_icons, :list, default: []
  attr :notif_unread_count, :integer, default: 0
  attr :locale, :string, required: true
  attr :known_locales, :list, default: []
  attr :breadcrumbs, :list, default: []
  attr :search, :map, default: %{enabled: false, index_url: nil, query_url: nil}

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!-- First focusable element on every page: invisible until it receives
          keyboard focus, then lets the reader jump past the navbar straight
          to the main landmark. --%>
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:fixed focus:start-4 focus:top-4 focus:z-[200] focus:rounded-lg focus:bg-primary focus:px-4 focus:py-2 focus:font-semibold focus:text-primary-content focus:shadow-lg"
    >
      {GamendWeb.HostLayouts.translate("Skip to content")}
    </a>
    <.background_icons background_icons={@background_icons} />
    <div class={["flex flex-col", if(@flush, do: "h-dvh overflow-hidden relative", else: "min-h-dvh")]}>
      <div
        :if={@flush}
        id="navbar-autohide"
        phx-hook="NavbarAutohide"
        data-target="main-navbar"
        class="hidden"
      />
      <header
        id="main-navbar"
        phx-hook="NavbarDropdowns"
        class={[
          "navbar z-50",
          if(@flush,
            do: "absolute top-0 start-0 end-0 ps-4 sm:ps-6 lg:ps-8 pe-14",
            else: "sticky top-0 shrink-0 px-4 sm:px-6 lg:px-8"
          ),
          if(@flush,
            do: "bg-base-100/90 backdrop-blur-md",
            else: "bg-transparent backdrop-blur-md border-base-200/20"
          )
        ]}
      >
        <%!-- Read straight off `@theme` rather than through `<% var = ... %>`
              bindings: a variable defined in a template is opaque to change
              tracking, so the three of them re-rendered — and re-sent the
              logo's URL — on every diff the page sent, long after the theme
              stopped moving. --%>
        <div class="flex-1">
          <a
            href={GamendWeb.HostLayouts.localized_href(~p"/", @locale)}
            class="flex-1 flex w-fit items-center gap-2"
          >
            <%!-- Same rule as `CoreComponents.flag/1`: this is on screen at
                  load on every page, so it is fetched with the HTML, decoded
                  with the first frame and prioritised over the ~45 flags the
                  locale dropdown queues behind it. Left async it painted a
                  beat after the title beside it on every refresh.

                  `alt=""` because it is decorative: the site name is the text
                  right beside it, so an alt repeating it makes a screen reader
                  say it twice — `image-redundant-alt`. The link is named by
                  that text. --%>
            <img
              src={theme_logo(@theme)}
              width="36"
              height="36"
              alt=""
              loading="eager"
              decoding="sync"
              fetchpriority="high"
              class={theme_logo_dark(@theme) && "[[data-theme=dark]_&]:hidden"}
            />
            <%!-- A mark drawn for a light page can vanish on a dark one. The
                  theme's `logo_dark` takes its place, swapped by the same
                  attribute the presentation images follow, so no script picks
                  one and the two never both show. --%>
            <img
              :if={theme_logo_dark(@theme)}
              src={theme_logo_dark(@theme)}
              width="36"
              height="36"
              alt=""
              loading="eager"
              decoding="sync"
              class="hidden [[data-theme=dark]_&]:block"
            />
            <span class="text-lg font-bold">{Map.get(@theme, "title")}</span>
            <span
              :if={theme_tagline(@theme)}
              class="text-sm opacity-80 ms-1 hidden xl:inline"
            >
              {theme_tagline(@theme)}
            </span>
          </a>
        </div>
        <%!-- The language picker sits outside both navs: one button in the bar
              at every width, rather than a dropdown up here and a different
              control buried in the phone menu. --%>
        <div class="flex-none flex items-center gap-2">
          <GamendWeb.HostLayoutNavigation.desktop_nav
            current_scope={@current_scope}
            current_path={@current_path}
            current_query={@current_query}
            navigation={@navigation}
            notif_unread_count={@notif_unread_count}
            locale={@locale}
            known_locales={@known_locales}
          />

          <%!-- One button at every width, like the language picker beside it:
                below `xl` the whole nav is a hamburger, so an input in the bar
                would be a desktop-only feature. The label is on `aria-label`
                and `title` rather than on screen — `title` and not a daisyUI
                `tooltip`, which hosts exclude from their stylesheet. --%>
          <button
            :if={@search.enabled}
            type="button"
            data-gamend-search-open
            aria-haspopup="dialog"
            aria-controls="gamend-search"
            aria-label={GamendWeb.HostLayouts.translate("Search")}
            title={GamendWeb.HostLayouts.translate("Search")}
            class="btn btn-ghost btn-circle"
          >
            <.icon name="hero-magnifying-glass-solid" class="w-5 h-5" />
          </button>

          <GamendWeb.HostLayoutNavigation.language_dropdown
            :if={length(@known_locales) > 1}
            locale={@locale}
            current_path={@current_path}
            current_query={@current_query}
            known_locales={@known_locales}
          />

          <GamendWeb.HostLayoutNavigation.mobile_nav
            current_scope={@current_scope}
            current_path={@current_path}
            current_query={@current_query}
            navigation={@navigation}
            notif_unread_count={@notif_unread_count}
            locale={@locale}
            known_locales={@known_locales}
          />
        </div>
      </header>

      <%!-- Outside `<header>` on purpose: the sheet is `position: fixed`, and
            the header's `backdrop-blur` makes it a containing block for fixed
            descendants — inside it, the sheet pins to the header's box and
            opens above the fold instead of along the bottom of the screen. --%>
      <GamendWeb.HostLayoutNavigation.language_modal
        :if={length(@known_locales) > 1}
        locale={@locale}
        current_path={@current_path}
        current_query={@current_query}
        known_locales={@known_locales}
      />

      <.search_dialog
        :if={@search.enabled}
        index_url={@search.index_url}
        query_url={@search[:query_url]}
      />

      <%= if @flush do %>
        <div id="main-content" class="flex-1 min-h-0 relative">
          {render_slot(@inner_block)}
        </div>
        <GamendWeb.HostLayouts.flash_group flash={@flash} />
      <% else %>
        <main id="main-content" class="relative z-[2] px-4 py-4 sm:px-6 lg:px-8 flex-1">
          <%!-- The trail sits above the content and pushes it down, which
                knocks a full-height hero off centre. `--breadcrumb-offset` is
                the trail's own height plus the stack gap; a hero subtracts it
                from `100dvh` so its first screen still ends at the fold. --%>
          <%!-- Reading width by default. A `wide` page brings its own side
                columns — a docs sidebar, a table of contents — and the article
                between them is what should keep the reading width, so the
                frame lets it out to the screen. --%>
          <div
            class={[
              "mx-auto space-y-4",
              if(@wide,
                do: "max-w-2xl md:max-w-3xl lg:max-w-5xl xl:max-w-7xl 2xl:max-w-screen-2xl",
                else: "max-w-2xl md:max-w-3xl lg:max-w-4xl xl:max-w-6xl"
              )
            ]}
            style={if length(@breadcrumbs) > 1, do: "--breadcrumb-offset: 2.25rem"}
          >
            <.breadcrumbs trail={@breadcrumbs} />
            <%!-- The page's own frame, applied here so no page has to know it:
                  one gap between blocks and one landing before the footer,
                  whichever repo wrote the page. A page that set its own `py-6`
                  used to sit lower than the page beside it in the nav, and
                  `pb-10` was on six pages and off the rest. `page-stack` is the
                  hook a host restyles; the utilities are the default. --%>
            <div class="page-stack space-y-6 pb-10">
              {render_slot(@inner_block)}
            </div>
          </div>
        </main>

        <GamendWeb.HostLayouts.flash_group flash={@flash} />
        <footer class="px-4 py-8 sm:px-6 lg:px-8 text-sm text-base-content/70">
          <div class="mx-auto grid max-w-2xl gap-6 md:max-w-3xl md:grid-cols-2 lg:max-w-4xl xl:max-w-6xl xl:grid-cols-4">
            <%!-- The column label is a `<p>`, not an `<h2>`: these name link
                  groups, not document sections, and as headings they were half
                  of every page's H2s — an outline where "Privacy & Terms" ranks
                  beside the page's actual subject. `aria-label` keeps the
                  grouping announced, which is what the heading was really
                  doing. --%>
            <div :for={section <- footer_sections(@footer)} class="space-y-2">
              <p class="text-sm font-semibold text-base-content">
                {section["title"]}
              </p>
              <nav aria-label={section["title"]} class="flex flex-col gap-1.5">
                <a
                  :for={link <- visible_footer_links(section, @current_scope)}
                  href={link["href"]}
                  target={if(link["external"], do: "_blank", else: nil)}
                  rel={if(link["external"], do: "noopener noreferrer", else: nil)}
                  class="w-fit hover:text-base-content hover:underline"
                >
                  {link["label"]}
                </a>
              </nav>
            </div>
          </div>
        </footer>
      <% end %>
    </div>
    """
  end

  attr :index_url, :string, required: true

  attr :query_url, :string,
    default: nil,
    doc: "where to ask for rows the index cannot hold; absent when the host answers none"

  @doc """
  The site search palette.

  Server-rendered and empty: `search_palette.js` fills the list by cloning the
  two `<template>`s below. That split is deliberate — every class name stays
  in HEEx where Tailwind's scanner can see it (a class authored in a JS string
  is purged from the stylesheet), and the JS only ever sets `textContent`, so
  an entry's title cannot carry markup into the page.

  `phx-update="ignore"` because this lives inside the LiveView DOM: morphdom
  re-sends the layout on every diff and an open `<dialog>` has no `open`
  attribute in that markup, so the palette would close itself a second after
  opening on any page with a ticking clock. LiveView still syncs `data-*` on
  an ignored element, which is why the index URL travels as one and no client
  state does.
  """
  def search_dialog(assigns) do
    ~H"""
    <%!-- Outside `<header>` for the same reason the language sheet is, plus
          one of its own: on flush pages `NavbarAutohide` sets the header's
          `pointer-events: none`, and that inherits — a dialog inside it would
          be visible and unclickable. --%>
    <%!-- Not daisyUI's `.modal`: that centres its box in the viewport, and on a
          desktop the palette belongs under the button that opened it, not
          across the middle of the page. So the dialog positions itself —
          `search_palette.js` measures the button and writes `left`/`top`/
          `width` here — and these classes are the fallback it starts from and
          returns to on a narrow screen: a sheet along the top edge.

          `showModal()` still does the rest, which is why this stays a
          `<dialog>`: the top layer (no z-index to lose), Esc, the focus trap,
          and a real `::backdrop` whose clicks report the dialog itself as the
          target — which is how clicking outside closes it. --%>
    <dialog
      id="gamend-search"
      phx-update="ignore"
      data-gamend-search
      data-index-url={@index_url}
      data-query-url={@query_url}
      aria-labelledby="gamend-search-label"
      class="fixed inset-x-0 top-0 m-0 w-full max-w-none max-h-none border-0 bg-transparent p-2 backdrop:bg-base-300/50 sm:backdrop:bg-transparent"
    >
      <%!-- The panel, and the thing "outside" is measured against: a click
            that does not land inside it closes the palette. --%>
      <div
        data-gamend-search-panel
        class="mx-auto flex max-h-full w-full max-w-xl flex-col overflow-hidden rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
      >
        <h2 id="gamend-search-label" class="sr-only">
          {GamendWeb.HostLayouts.translate("Search")}
        </h2>

        <div class="relative">
          <%!-- `start`/`ps`, not `left`/`pl`: in Arabic a magnifier pinned to
                the physical left sits where the reader's text ends. --%>
          <.icon
            name="hero-magnifying-glass-solid"
            class="pointer-events-none absolute start-3 top-1/2 w-4 h-4 -translate-y-1/2 opacity-50"
          />
          <input
            id="gamend-search-input"
            data-gamend-search-input
            type="search"
            role="combobox"
            autocomplete="off"
            aria-expanded="false"
            aria-controls="gamend-search-results"
            aria-autocomplete="list"
            placeholder={GamendWeb.HostLayouts.translate("Search")}
            class="input input-bordered w-full ps-9 pe-10"
          />
          <button
            type="button"
            data-gamend-search-close
            aria-label={GamendWeb.HostLayouts.translate("Close")}
            class="btn btn-ghost btn-square btn-sm absolute end-1 top-1/2 -translate-y-1/2"
          >
            <.icon name="hero-x-mark-solid" class="w-4 h-4" />
          </button>
        </div>

        <%!-- `flex-nowrap`: daisyUI's `.menu` is `column wrap`, so a capped
              height wraps into a second column off to the side instead of
              scrolling.

              `w-full min-w-0`: `.menu` is also `width: fit-content`, which is
              right for a dropdown that hugs its items and wrong for a list
              inside a fixed-width panel — it grew to the widest row (1260px
              in a 576px box) and every row hung out over the right edge.
              `min-w-0` is what then lets a long title actually truncate
              instead of pushing the row back out again. --%>
        <ul
          id="gamend-search-results"
          data-gamend-search-results
          role="listbox"
          aria-label={GamendWeb.HostLayouts.translate("Search")}
          hidden
          class="menu menu-sm mt-2 max-h-[60vh] min-h-0 w-full min-w-0 flex-1 flex-nowrap overflow-y-auto overflow-x-hidden overscroll-contain p-0"
        >
        </ul>

        <p data-gamend-search-empty hidden class="px-3 py-4 text-sm text-base-content/60">
          {GamendWeb.HostLayouts.translate("No results.")}
        </p>

        <template data-gamend-search-group>
          <li class="menu-title px-3 pt-3 pb-1 text-xs uppercase tracking-wide">
            <span data-group-label></span>
          </li>
        </template>

        <template data-gamend-search-row>
          <li class="w-full min-w-0">
            <a
              role="option"
              class="flex w-full min-w-0 items-center justify-between gap-3 rounded-lg px-3 py-2"
            >
              <span data-row-title class="min-w-0 truncate font-semibold"></span>
              <span data-row-subtitle class="min-w-0 truncate text-xs opacity-60"></span>
            </a>
          </li>
        </template>
      </div>
    </dialog>
    """
  end

  attr :trail, :list, default: []

  @doc """
  The breadcrumb trail, as `{label, path}` pairs — the last one is the current
  page and carries a `nil` path.

  Renders nothing for a bare `[{"Home", nil}]`: a trail with no ancestors tells
  the reader nothing, and Google ignores a single-item `BreadcrumbList`.
  """
  def breadcrumbs(assigns) do
    ~H"""
    <nav
      :if={length(@trail) > 1}
      aria-label={GamendWeb.HostLayouts.translate("Breadcrumb")}
      class="text-sm text-base-content/60"
    >
      <ol class="flex flex-wrap items-center gap-2">
        <li :for={{{label, path}, index} <- Enum.with_index(@trail)} class="flex items-center gap-2">
          <span :if={index > 0} aria-hidden="true">/</span>
          <.link :if={path} href={path} class="hover:text-primary transition-colors">
            {label}
          </.link>
          <span :if={is_nil(path)} aria-current="page" class="text-base-content/90">{label}</span>
        </li>
      </ol>
    </nav>
    """
  end

  defp theme_logo(theme) do
    logo = Map.get(theme, "logo")
    GamendWeb.SRI.versioned_path(logo) || logo
  end

  defp theme_logo_dark(theme) do
    case Map.get(theme, "logo_dark") do
      logo when is_binary(logo) and logo != "" -> GamendWeb.SRI.versioned_path(logo) || logo
      _ -> nil
    end
  end

  defp theme_tagline(theme) do
    case Map.get(theme, "tagline") do
      tagline when is_binary(tagline) and tagline != "" -> tagline
      _ -> nil
    end
  end

  defp footer_sections(%{"sections" => sections}) when is_list(sections), do: sections
  defp footer_sections(_footer), do: []

  # A footer link obeys the same `"auth"` rule as the nav: /store is behind
  # `require_authenticated_user`, so advertising it to a signed-out visitor
  # just sends them to an error.
  defp visible_footer_links(section, current_scope) do
    section
    |> Map.get("links", [])
    |> Enum.filter(&GamendWeb.HostLayoutNavigation.entry_visible?(&1, current_scope))
  end

  attr :background_icons, :list, default: []

  @doc """
  The shell's decorative icon layer.

  Which pages get one is decided in `GamendWeb.HostLayouts`: it hands over an
  empty list for pages that paint their own.
  """
  def background_icons(assigns) do
    ~H"""
    <%= if @background_icons != [] do %>
      <div class="fixed inset-0 overflow-hidden pointer-events-none z-[1]" aria-hidden="true">
        <%= for placement <- GamendWeb.HostLayouts.icon_placements(@background_icons) do %>
          <div
            class={[
              "absolute text-base-content [[data-theme=dark]_&]:text-white opacity-[0.08] [[data-theme=dark]_&]:opacity-[0.10]",
              placement.size
            ]}
            style={"top: #{placement.top}%; #{if Map.has_key?(placement, :left), do: "left: #{placement.left}%", else: "right: #{placement.right}%"}; animation: float #{placement.dur}s ease-in-out infinite #{placement.delay}s;"}
          >
            <.dynamic_icon name={placement.name} class={placement.size} />
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end
end
