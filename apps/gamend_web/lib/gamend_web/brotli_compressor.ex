defmodule GamendWeb.BrotliCompressor do
  @moduledoc """
  A `Phoenix.Digester.Compressor` that shells out to `brotli`.

  Add it beside the gzip one and `mix phx.digest` writes a `.br` next to every
  `.gz`; `GamendWeb.Endpoint` serves them when `:brotli_static` is on.

      config :phoenix, :static_compressors, [
        Phoenix.Digester.Gzip,
        GamendWeb.BrotliCompressor
      ]

  Which files are compressed is `:phoenix, :gzippable_exts` — one list, so a
  host that adds an extension (a Godot web export's `.wasm`, say) gets both
  encodings from the one setting rather than two lists that drift.

  ## Shelling out

  Quality 11 is a build-time cost paid once per asset, and the `brotli` CLI is
  present in the Docker image. There is no NIF here on purpose: an Elixir
  brotli dependency would need a compiler on every machine that builds assets,
  to save a `System.cmd` that runs a few dozen times in a release build.

  Every failure mode returns `:error`, which makes the digester skip the file
  and keep the gzip: no `brotli` on `PATH`, a non-zero exit, or output that
  came out no smaller than the input — the last of which is why the size check
  is in the match rather than an `if` after it.
  """

  @behaviour Phoenix.Digester.Compressor

  @impl true
  def compress_file(file_path, content) do
    # `System.cmd/3` raises rather than returning when the command is not on
    # `PATH`, so the lookup comes first; the absolute path it answers is what
    # runs.
    with true <- compressible?(file_path),
         brotli when is_binary(brotli) <- System.find_executable("brotli") do
      compress(brotli, content)
    else
      _ -> :error
    end
  end

  @impl true
  def file_extensions, do: [".br"]

  defp compress(brotli, content) do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "gamend_brotli_#{System.unique_integer([:positive])}"
      )

    try do
      File.write!(tmp_path, content)

      case System.cmd(brotli, ["-q", "11", "-c", tmp_path], stderr_to_stdout: true) do
        {compressed_content, 0} when byte_size(compressed_content) < byte_size(content) ->
          {:ok, compressed_content}

        {_output, _status} ->
          :error
      end
    after
      File.rm(tmp_path)
    end
  end

  defp compressible?(file_path) do
    Path.extname(file_path) in Application.fetch_env!(:phoenix, :gzippable_exts)
  end
end
