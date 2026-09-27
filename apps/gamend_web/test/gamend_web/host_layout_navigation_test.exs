defmodule GamendWeb.NavTestProvider do
  @moduledoc false
  # Dynamic nav-label value provider used by the token-resolution test.
  def coins(_scope), do: "1234"
  def boom(_scope), do: raise("nope")
end

defmodule GamendWeb.HostLayoutNavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GamendWeb.HostLayoutNavigation

  defp base_assigns(primary_links) do
    %{
      current_scope: nil,
      current_path: "/",
      current_query: "",
      navigation: %{"primary_links" => primary_links},
      notif_unread_count: 0,
      locale: "en",
      known_locales: []
    }
  end

  test "per-item color class is applied to the icon" do
    html =
      render_component(
        &HostLayoutNavigation.desktop_nav/1,
        base_assigns([
          %{
            "label" => "Shop",
            "href" => "/shop",
            "icon" => "hero-star",
            "color" => "text-warning"
          }
        ])
      )

    assert html =~ "text-warning"
    assert html =~ "hero-star"
  end

  test "{Module.func} label tokens resolve via the named function" do
    html =
      render_component(
        &HostLayoutNavigation.desktop_nav/1,
        base_assigns([
          %{"label" => "{GamendWeb.NavTestProvider.coins}", "href" => "/shop"}
        ])
      )

    assert html =~ "1234"
    refute html =~ "{GamendWeb.NavTestProvider"
  end

  test "unknown or failing tokens render empty, never crash" do
    html =
      render_component(
        &HostLayoutNavigation.desktop_nav/1,
        base_assigns([
          %{"label" => "{Does.Not.Exist}", "href" => "/a"},
          %{"label" => "{GamendWeb.NavTestProvider.boom}", "href" => "/b"}
        ])
      )

    refute html =~ "Does.Not.Exist"
    refute html =~ "boom"
  end

  test "readonly items render as a non-link badge (no href, not clickable)" do
    html =
      render_component(
        &HostLayoutNavigation.desktop_nav/1,
        base_assigns([
          %{
            "label" => "{GamendWeb.NavTestProvider.coins}",
            "icon" => "hero-star",
            "color" => "text-warning",
            "readonly" => true
          }
        ])
      )

    assert html =~ "1234"
    assert html =~ "text-warning"
    # non-interactive markers only the readonly item emits
    assert html =~ "pointer-events-none"
    assert html =~ ~s(aria-disabled="true")
  end

  test "desktop dropdown highlights the active sub-item with daisyUI menu-active" do
    nav = [
      %{
        "label" => "Social",
        "items" => [
          %{"label" => "Leaderboards", "href" => "/leaderboards", "match" => "prefix"}
        ]
      }
    ]

    assigns = %{base_assigns(nav) | current_path: "/leaderboards"}
    html = render_component(&HostLayoutNavigation.desktop_nav/1, assigns)

    # daisyUI 5 styles the active menu item via .menu-active (not .active)
    assert html =~ "menu-active"
  end

  # `/docs` and `/docs/reference` both start the page's path; only the more
  # specific one is where the reader is.
  test "only the most specific sibling is active, on desktop and mobile" do
    nav = [
      %{
        "label" => "Docs",
        "items" => [
          %{"label" => "Documentation", "href" => "/docs"},
          %{"label" => "Reference", "href" => "/docs/reference"}
        ]
      }
    ]

    assigns = %{base_assigns(nav) | current_path: "/docs/reference/components/body2d"}

    desktop = render_component(&HostLayoutNavigation.desktop_nav/1, assigns)
    assert [_one] = Regex.scan(~r/menu-active/, desktop)
    assert desktop =~ ~r{href="/docs/reference"\s+class="menu-active"}

    mobile = render_component(&HostLayoutNavigation.mobile_nav/1, assigns)
    refute mobile =~ ~r{href="/docs"\s+class="btn w-full btn-primary"}
    assert mobile =~ ~r{href="/docs/reference"\s+class="btn w-full btn-primary"}

    # A page only the broad link matches still lights it.
    guide = %{assigns | current_path: "/docs/manual/scenes"}

    assert render_component(&HostLayoutNavigation.desktop_nav/1, guide) =~
             ~r{href="/docs"\s+class="menu-active"}
  end

  test "mobile hamburger is a <details> toggle (native open/close, focus-independent)" do
    html =
      render_component(
        &HostLayoutNavigation.mobile_nav/1,
        base_assigns([
          %{"label" => "Play", "href" => "/play"}
        ])
      )

    # A <details data-navbar-dropdown> with a <summary> trigger — not a
    # tabindex/focus dropdown (which gets stuck when focus is lost on alt-tab).
    assert html =~ ~r/<details[^>]*data-navbar-dropdown/
    assert html =~ ~r/<summary[^>]*aria-label/
    refute html =~ ~s(<button\n)
    refute html =~ ~s(tabindex="0")
  end

  test "mobile: pinned items render inline (outside the dropdown menu)" do
    html =
      render_component(
        &HostLayoutNavigation.mobile_nav/1,
        base_assigns([
          %{"label" => "Coins", "href" => "/shop", "icon" => "hero-star", "mobile" => "pinned"},
          %{"label" => "Play", "href" => "/play"}
        ])
      )

    # Pinned link is present, and it sits before the dropdown menu markup.
    assert html =~ ~s(href="/shop")
    [before_menu, _menu] = String.split(html, "dropdown-content", parts: 2)
    assert before_menu =~ ~s(href="/shop")
    refute before_menu =~ ~s(href="/play")
  end
end
