defmodule Gamend.Content.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Gamend.Content.Frontmatter

  test "reads scalars, quoted strings, numbers and booleans" do
    {meta, body} =
      Frontmatter.parse("""
      ---
      title: Scenes and nodes
      sidebar_label: "Scenes"
      description: 'How a scene is a tree, and why.'
      position: 3
      collapsed: false
      empty:
      nothing: null
      ---

      # Scenes
      """)

    assert meta["title"] == "Scenes and nodes"
    assert meta["sidebar_label"] == "Scenes"
    assert meta["description"] == "How a scene is a tree, and why."
    assert meta["position"] == 3
    assert meta["collapsed"] == false
    assert meta["empty"] == nil
    assert meta["nothing"] == nil
    assert body == "# Scenes\n"
  end

  test "reads flow and block lists" do
    {meta, _} =
      Frontmatter.parse("""
      ---
      keywords: [game engine, "rust, deterministic", 'hot reload']
      authors: [dragos]
      tags:
        - balaur
        - "release notes"
      ---
      body
      """)

    assert meta["keywords"] == ["game engine", "rust, deterministic", "hot reload"]
    assert meta["authors"] == ["dragos"]
    assert meta["tags"] == ["balaur", "release notes"]
  end

  test "a value with a colon in it keeps the colon" do
    {meta, _} = Frontmatter.parse("---\nurl: https://example.com/x\n---\n")

    assert meta["url"] == "https://example.com/x"
  end

  test "only a block on the very first line counts" do
    assert Frontmatter.parse("intro\n---\ntitle: x\n---\n") ==
             {%{}, "intro\n---\ntitle: x\n---\n"}

    assert Frontmatter.parse("plain") == {%{}, "plain"}
  end

  test "an unterminated block is body" do
    assert Frontmatter.parse("---\ntitle: x\nno end") == {%{}, "---\ntitle: x\nno end"}
  end

  test "Windows line endings and comments are tolerated" do
    {meta, body} = Frontmatter.parse("---\r\n# a comment\r\ntitle: x\r\n---\r\nhello")

    assert meta == %{"title" => "x"}
    assert body == "hello"
  end

  test "list/1 normalises however a list was written" do
    assert Frontmatter.list(nil) == []
    assert Frontmatter.list(["a", "b"]) == ["a", "b"]
    assert Frontmatter.list("a, b ,c") == ["a", "b", "c"]
    assert Frontmatter.list("one") == ["one"]
    assert Frontmatter.list(3) == ["3"]
  end

  test "integer/1 reads a number written either way" do
    assert Frontmatter.integer(4) == 4
    assert Frontmatter.integer("12") == 12
    assert Frontmatter.integer("twelve") == nil
    assert Frontmatter.integer(nil) == nil
  end
end
