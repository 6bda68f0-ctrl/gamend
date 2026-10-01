defmodule Gamend.Accounts.Preferences do
  @moduledoc """
  A user's private settings (`users.preferences`): what only they see and
  change — notification choices (`Gamend.Notifications.Preferences`), their
  time zone (`Gamend.Accounts.TimeZone`) and the site language they last used
  (`locale/1`, for email written to them).

  Kept out of `metadata` on purpose: metadata is sent to friends, lobby and
  party members (`User.serialize_brief/1`), and a user's time zone or email
  choices are nobody else's business. Every user serializer lists its fields,
  and this one is in none of them.

  Writes are serialized per user (`Gamend.Lock`) and re-read the row, so two
  settings changed at once cannot lose each other.
  """

  alias Gamend.Accounts
  alias Gamend.Accounts.User
  alias Gamend.Repo

  @doc "A user's preferences map (string keys), empty when none are set."
  @spec get(User.t() | nil) :: map()
  def get(%User{preferences: %{} = prefs}), do: prefs
  def get(_user), do: %{}

  @doc "The site language the user last read in (a locale code), or nil."
  @spec locale(User.t() | nil) :: String.t() | nil
  def locale(user) do
    case get(user)["locale"] do
      locale when is_binary(locale) -> locale
      _ -> nil
    end
  end

  @doc """
  Change a user's preferences: `fun` gets the current map and returns the
  new one. `{:ok, user}` with the saved user.
  """
  @spec update(User.t(), (map() -> map())) :: {:ok, User.t()} | {:error, term()}
  def update(%User{id: id}, fun) when is_function(fun, 1) do
    result =
      Gamend.Lock.serialize("user_preferences", id, fn ->
        case Repo.get(User, id) do
          nil ->
            {:error, :not_found}

          current ->
            current
            |> Ecto.Changeset.change(preferences: fun.(current.preferences || %{}))
            |> Repo.update()
        end
      end)

    case result do
      {:ok, {:ok, updated}} ->
        Accounts.invalidate_user_cache(updated)
        {:ok, updated}

      {:ok, other} ->
        other

      {:error, reason} ->
        {:error, reason}
    end
  end
end
