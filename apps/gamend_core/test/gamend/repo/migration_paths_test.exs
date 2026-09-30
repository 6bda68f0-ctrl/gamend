defmodule Gamend.Repo.MigrationPathsTest do
  # Touches no database and no global state.
  use ExUnit.Case, async: true

  alias Gamend.Repo.MigrationPaths

  describe "all/1 under Mix" do
    test "returns existing, absolute, de-duplicated directories" do
      paths = MigrationPaths.all()

      refute paths == []

      for path <- paths do
        assert Path.type(path) == :absolute
        assert File.dir?(path)
      end

      assert paths == Enum.uniq(paths)
    end

    test "includes core's migrations, not only the host's" do
      # The whole point of this module: a host runs core's migrations plus its
      # own. A regression that dropped core would still return a non-empty
      # list, so assert on the core entry specifically.
      assert Enum.any?(MigrationPaths.all(), &(&1 =~ "gamend_core"))
    end

    test "ensure_host creates the host directory so Ecto does not fail on it" do
      host_migrations = Path.expand("priv/repo/migrations")
      existed? = File.dir?(host_migrations)

      assert host_migrations in MigrationPaths.all(ensure_host: true)

      # Leave the tree as we found it in a checkout that had no host migrations.
      if not existed?, do: File.rmdir(host_migrations)
    end
  end

  describe "as_args/1" do
    test "interleaves --migrations-path before every directory" do
      args = MigrationPaths.as_args()
      paths = MigrationPaths.all()

      assert length(args) == length(paths) * 2

      args
      |> Enum.chunk_every(2)
      |> Enum.each(fn [flag, path] ->
        assert flag == "--migrations-path"
        assert path in paths
      end)
    end
  end

  describe "the release branch's target" do
    test "core's migrations are where a release will look for them" do
      # In a release, all/1 stops walking the project tree and asks the code
      # server instead. Nothing under Mix exercises that branch, so this
      # asserts the destination it resolves to is real: if core's migrations
      # move, the Mix branch keeps working from its relative candidates while
      # the release branch silently returns nothing and migrations no-op.
      lib_dir = :gamend_core |> :code.lib_dir() |> List.to_string()

      assert File.dir?(Path.join([lib_dir, "priv", "repo", "migrations"]))
    end
  end
end
