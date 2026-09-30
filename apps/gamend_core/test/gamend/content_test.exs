defmodule Gamend.ContentTest do
  use ExUnit.Case, async: false

  alias Gamend.Content

  test "asset_path rejects sibling directory traversal with shared prefix" do
    root =
      Path.join(System.tmp_dir!(), "gamend_content_#{System.unique_integer([:positive])}")

    base = Path.join(root, "blog")
    sibling = Path.join(root, "blog_secret")
    name = "content_test_#{System.unique_integer([:positive])}"

    File.mkdir_p!(base)
    File.mkdir_p!(sibling)
    File.write!(Path.join(base, "image.png"), "ok")
    File.write!(Path.join(sibling, "secret.txt"), "secret")

    on_exit(fn -> File.rm_rf(root) end)

    Content.register_path(name, kind: :dir, path: base, asset_root: :self)

    assert Content.asset_path(name, "image.png") == Path.join(base, "image.png")
    assert Content.asset_path(name, "../blog_secret/secret.txt") == nil
  end

  test "markdown rendering strips unsafe HTML and link attributes" do
    root =
      Path.join(System.tmp_dir!(), "gamend_content_#{System.unique_integer([:positive])}")

    path = Path.join(root, "CHANGELOG.md")
    original_changelog_path = Content.path(:changelog) || "CHANGELOG.md"

    File.mkdir_p!(root)

    File.write!(path, """
    # Changelog

    [click](http://example.com/?a=x " onerror="alert(1))

    <script>alert(2)</script>
    """)

    on_exit(fn ->
      Content.register_path(:changelog, kind: :file, path: original_changelog_path)
      File.rm_rf(root)
    end)

    Content.register_path(:changelog, kind: :file, path: path)

    html = Content.changelog_html()

    assert html =~ "Click"
    refute html =~ ~r/<[^>]+onerror/i
    refute html =~ "<script"
    refute html =~ ~r/<[^>]+alert/i
  end

  describe "relabel_pills/2" do
    # This is the documented seam for translated pills: `apply_changelog_pills/1`
    # runs inside the cache with English labels, so the only place a host can
    # translate is on the way out. gamend_polyglot re-labels the roadmap's pills
    # in the reader's language through this.
    test "re-labels a pill the cache rendered as neutral other" do
      cached = Content.apply_changelog_pills("[Beta] shipping")
      assert cached =~ Content.pill("other", "Beta")

      relabelled = Content.relabel_pills(cached, %{"Beta" => {"info", "Beta-versión"}})

      assert relabelled =~ Content.pill("info", "Beta-versión")
      refute relabelled =~ Content.pill("other", "Beta")
    end

    test "also re-labels a raw marker that never reached the cache" do
      # The roadmap has carried both spellings; handling only the cached one
      # left "[Beta]" printed verbatim mid-heading.
      relabelled = Content.relabel_pills("<h2>[Beta] thing</h2>", %{"Beta" => {"info", "Bêta"}})

      assert relabelled =~ Content.pill("info", "Bêta")
      refute relabelled =~ "[Beta]"
    end

    test "leaves tags it was not given alone, and passes nil through" do
      cached = Content.apply_changelog_pills("[Beta] and [Alpha]")
      relabelled = Content.relabel_pills(cached, %{"Beta" => {"info", "Bêta"}})

      assert relabelled =~ Content.pill("info", "Bêta")
      assert relabelled =~ Content.pill("other", "Alpha")

      assert Content.relabel_pills(nil, %{"Beta" => {"info", "Bêta"}}) == nil
    end
  end
end
