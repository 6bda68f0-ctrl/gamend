defmodule GamendWeb.MarkdownPageTest do
  @moduledoc """
  A markdown file in the `:pages` collection answers its path through the
  configured-page fallback, with nothing routed for it.
  """
  use GamendWeb.ConnCase, async: false

  alias Gamend.Content

  setup do
    root = Path.join(System.tmp_dir!(), "gamend_pages_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "help"))

    File.write!(Path.join(root, "faq.md"), """
    ---
    title: Questions & answers
    description: What people ask.
    ---

    ## Is it free?

    Yes.
    """)

    File.write!(Path.join(root, "help/install.md"), "# Installing\n\nSteps.\n")
    File.write!(Path.join(root, "wide.md"), "---\ntitle: Wide\nlayout: wide\n---\n\nRoom.\n")

    Content.register_path(:pages, kind: :dir, path: root, nesting: :tree, base_path: "/")

    on_exit(fn ->
      Content.unregister_path(:pages)
      File.rm_rf(root)
    end)

    :ok
  end

  test "a top-level page renders with its title and body", %{conn: conn} do
    html = conn |> get("/faq") |> html_response(200)

    assert Regex.match?(~r/<title[^>]*>Questions &amp; answers/, html)
    assert html =~ "What people ask."
    assert html =~ ~s(<h2 id="is-it-free">)
    assert html =~ "<p>Yes.</p>"
  end

  test "a nested page answers its nested path", %{conn: conn} do
    assert conn |> get("/help/install") |> html_response(200) =~ "Installing"
  end

  test "`layout: wide` widens the frame", %{conn: conn} do
    assert conn |> get("/wide") |> html_response(200) =~ "2xl:max-w-screen-2xl"
    refute conn |> get("/faq") |> html_response(200) =~ "2xl:max-w-screen-2xl"
  end

  test "a path with no page is still a 404", %{conn: conn} do
    assert conn |> get("/nothing-here") |> response(404)
  end
end
