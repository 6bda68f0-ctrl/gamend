defmodule GamendWeb.Schemas.PageMeta do
  @moduledoc """
  The `meta` block of every paginated list, as `GamendWeb.Pagination.meta/4`
  writes it. All six keys, always.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PageMeta",
    description: "Pagination for a list response",
    type: :object,
    properties: %{
      page: %Schema{type: :integer, description: "This page, 1-based"},
      page_size: %Schema{type: :integer, description: "Rows asked for per page"},
      count: %Schema{type: :integer, description: "Rows on this page"},
      total_count: %Schema{type: :integer, description: "Rows across every page"},
      total_pages: %Schema{type: :integer, description: "Pages at this page size"},
      has_more: %Schema{type: :boolean, description: "Whether a later page exists"}
    },
    required: [:page, :page_size, :count, :total_count, :total_pages, :has_more],
    example: %{
      page: 1,
      page_size: 25,
      count: 25,
      total_count: 130,
      total_pages: 6,
      has_more: true
    }
  })
end
