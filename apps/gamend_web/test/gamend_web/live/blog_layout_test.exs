defmodule GamendWeb.BlogLayoutTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GamendWeb.BlogLive
  alias GamendWeb.ContentPages

  @posts [
    {2026,
     [
       {9,
        [
          %{
            slug: "one",
            title: "One",
            date: ~D[2026-09-02],
            excerpt: "The first.",
            image: "/img/one.png"
          },
          %{
            slug: "two",
            title: "Two",
            date: ~D[2026-09-01],
            excerpt: "The second.",
            authors: [%{name: "Dragos", url: "https://github.com/Ughuuu"}]
          }
        ]}
     ]}
  ]

  describe "layout/1" do
    test "the theme's blog layout picks the grid" do
      assert BlogLive.layout(%{"blog" => %{"layout" => "grid"}}) == :grid
    end

    test "anything else is the list" do
      assert BlogLive.layout(%{}) == :list
      assert BlogLive.layout(%{"blog" => %{"layout" => "columns"}}) == :list
      assert BlogLive.layout(%{"blog" => "grid"}) == :list
    end
  end

  describe "the index" do
    test "the grid puts cards in columns, the picture above the text" do
      html = render_index(true)

      assert html =~ "sm:grid-cols-2 lg:grid-cols-3"
      assert html =~ "mx-auto px-4 py-8 sm:px-6 max-w-6xl"
      refute html =~ "sm:w-64"
    end

    test "the list keeps one card to a row, the picture beside the text" do
      html = render_index(false)

      refute html =~ "sm:grid-cols-2 lg:grid-cols-3"
      assert html =~ "mx-auto px-4 py-8 sm:px-6 max-w-4xl"
      assert html =~ "sm:w-64"
    end
  end

  # The card is a link; an author's link inside it would split it in two.
  test "an index card holds no link but its own" do
    html = render_index(true)

    assert html =~ "Dragos"
    refute html =~ ~s(href="https://github.com/Ughuuu")
  end

  describe "cover/2" do
    test "a cover the body already shows is not shown again" do
      post = %{image: "/img/blog/cloth.png"}

      assert ContentPages.cover(post, ~s(<p>x</p><img src="/img/blog/cloth.webp?v=1" alt="">)) ==
               nil
    end

    test "a cover the body does not show stays" do
      post = %{image: "/img/blog/cloth.png"}

      assert ContentPages.cover(post, ~s(<img src="/img/blog/jelly.webp">)) ==
               "/img/blog/cloth.png"

      assert ContentPages.cover(post, nil) == "/img/blog/cloth.png"
      assert ContentPages.cover(%{}, "<p>x</p>") == nil
    end
  end

  defp render_index(grid?) do
    render_component(&ContentPages.blog_index/1,
      flash: %{},
      blog_available?: true,
      grouped_posts: @posts,
      grid?: grid?
    )
  end
end
