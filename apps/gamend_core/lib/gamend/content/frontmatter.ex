defmodule Gamend.Content.Frontmatter do
  @moduledoc """
  The `---` block at the top of a markdown file.

  A subset of YAML, on purpose: scalars, flow lists (`[a, b]`) and block
  lists (`- a` lines), and nothing nested. That is what the files in the wild
  use — `title`, `description`, `position`, `keywords: [a, b]`,
  `authors: [dragos]` — and a YAML parser dependency to read four kinds of
  line would be its own liability, which is the argument the single-line
  reader here started from. What changed is that a list is a list rather
  than the string `"[a, b]"`, and a number is a number.
  """

  @type value :: String.t() | integer() | boolean() | nil | [String.t()]
  @type meta :: %{String.t() => value()}

  @doc "The block's keys and the body after it. `{%{}, content}` when there is none."
  @spec parse(String.t()) :: {meta(), String.t()}
  def parse(content) when is_binary(content) do
    case split(content) do
      {block, body} -> {parse_block(block), String.trim_leading(body)}
      nil -> {%{}, content}
    end
  end

  @doc "Only the keys."
  @spec meta(String.t()) :: meta()
  def meta(content), do: content |> parse() |> elem(0)

  @doc "Only the body."
  @spec body(String.t()) :: String.t()
  def body(content), do: content |> parse() |> elem(1)

  @doc """
  A value as a list of strings, however it was written: a flow or block
  list, a comma-separated string, one string, or nothing.
  """
  @spec list(value()) :: [String.t()]
  def list(nil), do: []

  def list(list) when is_list(list),
    do: list |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))

  def list(string) when is_binary(string) do
    string |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  def list(other), do: [to_string(other)]

  @doc "A value as an integer, or nil."
  @spec integer(value()) :: integer() | nil
  def integer(int) when is_integer(int), do: int

  def integer(string) when is_binary(string) do
    case Integer.parse(String.trim(string)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  def integer(_other), do: nil

  # The opening fence has to be the very first line; a `---` further down is
  # a horizontal rule, not a frontmatter block.
  defp split(content) do
    content = String.replace(content, "\r\n", "\n")

    case content do
      "---\n" <> rest ->
        case String.split(rest, ~r/^---[ \t]*$/m, parts: 2) do
          [block, body] -> {block, body}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_block(block) do
    block
    |> String.split("\n")
    |> parse_lines(%{}, nil)
  end

  # `pending` is the key whose block list is being collected, if any. Its
  # items are prepended as they come and put in order when the list ends —
  # at the next key, or at the end of the block.
  defp parse_lines([], acc, pending), do: finish(acc, pending)

  defp parse_lines([line | rest], acc, pending) do
    cond do
      String.trim(line) == "" or String.starts_with?(String.trim_leading(line), "#") ->
        parse_lines(rest, acc, pending)

      pending && Regex.match?(~r/^\s+-\s*/, line) ->
        item = line |> String.replace(~r/^\s+-\s*/, "") |> scalar()

        # The key was recorded as nil when its line had no value; the first
        # item turns it into a list.
        parse_lines(
          rest,
          Map.update(acc, pending, [item], fn
            list when is_list(list) -> [item | list]
            _nil -> [item]
          end),
          pending
        )

      true ->
        acc = finish(acc, pending)

        case String.split(line, ":", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value)

            cond do
              key == "" or String.contains?(key, " ") ->
                parse_lines(rest, acc, nil)

              value == "" ->
                # Either a block list follows or the value is empty; the list
                # branch above fills it in, and an empty key stays nil.
                parse_lines(rest, Map.put_new(acc, key, nil), key)

              String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
                parse_lines(rest, Map.put(acc, key, flow_list(value)), nil)

              true ->
                parse_lines(rest, Map.put(acc, key, scalar(value)), nil)
            end

          _ ->
            parse_lines(rest, acc, nil)
        end
    end
  end

  defp finish(acc, nil), do: acc

  defp finish(acc, pending) do
    Map.update(acc, pending, nil, fn
      list when is_list(list) -> Enum.reverse(list)
      other -> other
    end)
  end

  defp flow_list(value) do
    value
    |> String.slice(1..-2//1)
    |> split_items()
    |> Enum.map(&scalar/1)
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.map(&to_string/1)
  end

  # Commas inside quotes do not separate items: `["a, b", c]` is two.
  defp split_items(inner) do
    inner
    |> String.graphemes()
    |> Enum.reduce({[], "", nil}, fn char, {items, current, quote} ->
      cond do
        quote && char == quote -> {items, current <> char, nil}
        quote -> {items, current <> char, quote}
        char in ["\"", "'"] -> {items, current <> char, char}
        char == "," -> {[current | items], "", nil}
        true -> {items, current <> char, nil}
      end
    end)
    |> then(fn {items, current, _} -> Enum.reverse([current | items]) end)
    |> Enum.map(&String.trim/1)
  end

  defp scalar(value) do
    value = String.trim(value)

    cond do
      value == "" -> ""
      value in ["null", "~"] -> nil
      value == "true" -> true
      value == "false" -> false
      quoted?(value) -> String.slice(value, 1..-2//1)
      integer?(value) -> String.to_integer(value)
      true -> value
    end
  end

  defp quoted?(value) do
    String.length(value) >= 2 and
      ((String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
         (String.starts_with?(value, "'") and String.ends_with?(value, "'")))
  end

  defp integer?(value), do: Regex.match?(~r/^-?\d+$/, value)
end
