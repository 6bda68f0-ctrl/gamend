defmodule Gamend.Repo.Migrations.AddPreferencesToUsers do
  @moduledoc """
  `users.preferences`: a user's own settings that no other player may see —
  notification choices per group and channel, and their time zone
  (`Gamend.Accounts.Preferences`). Not `metadata`: that map is sent to
  friends, lobby and party members, and every host decides what it holds.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :preferences, :map, default: %{}
    end
  end
end
