defmodule Gamend.Notifications.Notification do
  @moduledoc """
  Ecto schema representing a notification sent from one user to another.

  Notifications are persisted in the database and remain until the recipient
  explicitly deletes them. Fields:

  - `sender_id` – the user who sent the notification (must be a friend)
  - `recipient_id` – the user who receives the notification
  - `title` – required short summary
  - `content` – optional longer body text
  - `metadata` – optional arbitrary key/value map
  - `icon_url` – optional icon; `nil` means clients show their default
    notification icon
  """
  use Gamend.Schema
  import Ecto.Changeset

  alias Gamend.Accounts.User
  alias Gamend.Notifications.Types

  schema "notifications" do
    belongs_to :sender, User
    belongs_to :recipient, User

    field :title, :string
    field :content, :string, default: ""
    field :metadata, :map, default: %{}
    field :icon_url, :string
    field :read, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @typedoc "A notification record."
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          sender_id: Ecto.UUID.t() | nil,
          recipient_id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          content: String.t() | nil,
          metadata: map(),
          icon_url: String.t() | nil,
          read: boolean(),
          inserted_at: DateTime.t() | nil
        }

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:title, :content, :metadata, :icon_url])
    |> validate_required([:title])
    |> validate_length(:icon_url, max: Gamend.Limits.get(:max_profile_url))
    |> validate_length(:title, min: 1, max: Gamend.Limits.get(:max_notification_title))
    |> validate_length(:content, max: Gamend.Limits.get(:max_notification_content))
    |> unique_constraint([:sender_id, :recipient_id, :title],
      name: :notifications_sender_id_recipient_id_title_index
    )
    |> Gamend.Limits.validate_metadata_size(:metadata)
    |> validate_notification_type()
  end

  # A notification's type is a client contract: the server never reads it, so
  # an unregistered code would be delivered and silently ignored by every
  # client. Reject it at write time instead. See Gamend.Notifications.Types.
  #
  # `:map` casts keep atom keys, which the JSON column turns into strings, so
  # `%{type: "x"}` stores the same `"type"` a client routes on. Check both.
  defp validate_notification_type(changeset) do
    case type_of(get_field(changeset, :metadata)) do
      nil ->
        changeset

      type ->
        if Types.known?(type) do
          changeset
        else
          add_error(changeset, :metadata, "unknown notification type #{inspect(type)}")
        end
    end
  end

  defp type_of(%{"type" => type}), do: type
  defp type_of(%{type: type}), do: type
  defp type_of(_metadata), do: nil
end

# Hand-written rather than @derive so nil strings encode as "" (see
# Gamend.SchemaJSON — game clients choke on null).
defimpl Jason.Encoder, for: Gamend.Notifications.Notification do
  def encode(notification, opts) do
    Gamend.SchemaJSON.encode(
      notification,
      [
        :id,
        :sender_id,
        :recipient_id,
        :title,
        :content,
        :metadata,
        :icon_url,
        :read,
        :inserted_at
      ],
      opts
    )
  end
end
