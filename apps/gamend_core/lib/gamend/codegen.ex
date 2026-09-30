defmodule Gamend.Codegen do
  @moduledoc """
  Support for the `mix` tasks that write generated files into the repo.

  Four of them — `gamend.settings.guide`, `gamend.settings.env_example`,
  `gamend.content.extract`, `gamend.theme.extract` — follow the same shape:
  render the file from the source of truth, write it in the normal run, and in
  `--check` mode fail if what is on disk differs. They each had their own copy
  of the comparison, identical but for the task name in the message, and two of
  them carried the same PO quoting rules.
  """

  @doc """
  Fails the task unless `path` already holds exactly `generated`.

  `task` is named in the failure so the reader is told how to fix it.
  """
  @spec check!(Path.t(), iodata(), String.t()) :: :ok
  def check!(path, generated, task) do
    generated = IO.iodata_to_binary(generated)

    case File.read(path) do
      {:ok, ^generated} ->
        Mix.shell().info("#{path} is up to date")
        :ok

      {:ok, _stale} ->
        Mix.raise("#{path} is out of date. Run: mix #{task}")

      {:error, _reason} ->
        Mix.raise("#{path} does not exist. Run: mix #{task}")
    end
  end

  @doc ~S'''
  Quotes a string as a PO `msgid`/`msgstr` value.

  A value with no newline is one quoted string. A multi-line one becomes the
  empty string followed by one quoted line each, with `\n` at the end of every
  line but the last — the form gettext tools write, and the only form some of
  them will read back.
  '''
  @spec quote_po(String.t()) :: String.t()
  def quote_po(string) do
    escaped = string |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

    case String.split(escaped, "\n") do
      [single] ->
        ~s("#{single}")

      lines ->
        body =
          lines
          |> Enum.with_index()
          |> Enum.map_join("\n", fn {line, index} ->
            suffix = if index == length(lines) - 1, do: "", else: "\\n"
            ~s("#{line}#{suffix}")
          end)

        ~s("") <> "\n" <> body
    end
  end
end
