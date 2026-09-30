defmodule Gamend.Repo.Migrations.AddGithubIdToUsers do
  @moduledoc """
  Add `github_id` to `users` for "Log in with GitHub".

  The unique index is partial, like the other provider columns since
  `20260819150000_partial_user_provider_indexes`: a player signs in one way,
  so this column is NULL for everyone else and a plain unique index would
  store an entry per row that can never match anything.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :github_id, :string
    end

    create unique_index(:users, [:github_id], where: "github_id IS NOT NULL")
  end

  def down do
    drop index(:users, [:github_id])

    alter table(:users) do
      remove :github_id
    end
  end
end
