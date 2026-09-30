defmodule GamendHost.PageMeta do
  @moduledoc """
  Per-page SEO metadata, for `GamendWeb.Plugs.PageMeta`.

  A guide's title is its first heading and its description its opening
  paragraph, both already parsed by `Gamend.Content`; restating them here would
  be a second source of truth that drifts the first time someone edits the
  markdown. The mechanics are `GamendWeb.PageMeta`.
  """

  @behaviour GamendWeb.PageMeta.Provider

  import GamendWeb.PageMeta

  alias Gamend.Content

  @spec describe(String.t()) :: String.t() | nil
  def describe(path) when is_binary(path), do: path |> normalize() |> lookup()
  def describe(_path), do: nil

  defp lookup("/docs/setup"), do: nil

  defp lookup("/docs/" <> slug) do
    case Content.get_doc(slug) do
      nil -> nil
      guide -> guide.summary |> plain_text() |> truncate()
    end
  end

  defp lookup(_path), do: nil

  @doc """
  The `<title>` for `path`, or nil to fall back to the page's `:page_title`.

  Each guide already assigns its own heading, so only the hub needs one —
  "Documentation" is not something anyone searches for.
  """
  @spec title(String.t()) :: String.t() | nil
  def title(path) when is_binary(path), do: path |> normalize() |> page_title()
  def title(_path), do: nil

  # Not translated: the guides are English-only markdown, so a localized title
  # over English content would misdescribe the page.
  defp page_title("/docs/setup"), do: "Setup Guides: Deploy, Configure and Extend gamend"
  defp page_title(_path), do: nil

  @spec breadcrumbs(String.t()) :: [{String.t(), String.t() | nil}]
  def breadcrumbs(path) when is_binary(path), do: path |> normalize() |> trail()
  def breadcrumbs(_path), do: []

  defp trail("/docs/setup"), do: []

  defp trail("/docs/" <> slug) do
    case Content.get_doc(slug) do
      nil ->
        []

      guide ->
        tail =
          case section_name(slug) do
            nil -> [{guide.title, nil}]
            name -> [{name, nil}, {guide.title, nil}]
          end

        [{"Docs", "/docs/setup"} | tail]
    end
  end

  defp trail(_path), do: []

  @spec json_ld(String.t()) :: [map()]
  def json_ld(path) when is_binary(path), do: path |> normalize() |> schema()
  def json_ld(_path), do: []

  defp schema("/docs/setup"), do: []

  defp schema("/docs/" <> slug = path) do
    case Content.get_doc(slug) do
      nil ->
        []

      guide ->
        [
          %{
            "@context" => "https://schema.org",
            "@type" => "TechArticle",
            "headline" => guide.title,
            "description" => guide.summary |> plain_text() |> truncate(),
            "articleSection" => section_name(slug),
            "url" => url(path)
          },
          breadcrumb_list(breadcrumbs(path), path)
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp schema(_path), do: []

  # A guide's own `:category` is the folder ("10-setup"); the display title
  # ("Setup") lives on the category, which is found by membership.
  defp section_name(slug) do
    case Enum.find(Content.list_doc_categories(), fn category ->
           Enum.any?(category.guides, &(&1.slug == slug))
         end) do
      nil -> nil
      category -> category.category
    end
  end
end
