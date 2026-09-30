defmodule GamendWeb.LobbiesChannel do
  @moduledoc """
  Channel for broadcasting global lobby list events.

  Topic: "lobbies"

  Clients may join this topic to receive real-time notifications when lobbies
  are created/updated/deleted or when membership changes occur across lobbies.
  """

  use Phoenix.Channel

  import GamendWeb.ChannelPush

  alias GamendWeb.ChannelEvents
  alias GamendWeb.ChannelUpdates
  alias GamendWeb.Plugs.FeatureGate
  alias GamendWeb.Serializers

  @impl true
  def join("lobbies", _payload, socket) do
    # Same flag as GET /api/v1/lobbies — the feed must not outlive the API.
    if FeatureGate.enabled?(:list_lobbies) do
      GamendWeb.ConnectionTracker.register(:lobbies_channel)
      {:ok, socket}
    else
      {:error, %{reason: "listing_disabled"}}
    end
  end

  @impl true
  # Answer and stay up — see LobbyChannel: stopping the channel over one
  # unrecognised event took every broadcast it carried with it, and a client
  # cannot tell a dead channel from a quiet one.
  def handle_in(event, _payload, socket), do: ChannelEvents.unknown(event, socket)

  @impl true
  def handle_info({:lobby_created, lobby}, socket) do
    payload = Serializers.serialize_lobby(lobby, include_passworded: true)
    push_event(socket, "lobby_created", payload)
    # The create doubles as the first update; remembering it suppresses an
    # identical lobby_updated immediately afterwards.
    {:noreply, ChannelUpdates.remember(socket, "lobby_updated", payload.id, payload)}
  end

  @impl true
  def handle_info({:lobby_updated, lobby}, socket) do
    payload = Serializers.serialize_lobby(lobby, include_passworded: true)
    {:noreply, ChannelUpdates.push(socket, "lobby_updated", payload.id, payload)}
  end

  @impl true
  def handle_info({:lobby_deleted, lobby_id}, socket) do
    push_event(socket, "lobby_deleted", %{id: lobby_id})
    # Prune, so a long-lived list socket doesn't accumulate an entry for every
    # lobby it has ever seen.
    {:noreply, ChannelUpdates.forget(socket, "lobby_updated", lobby_id)}
  end

  @impl true
  def handle_info({:lobby_membership_changed, lobby_id}, socket) do
    push_event(socket, "lobby_membership_changed", %{id: lobby_id})
    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket), do: {:noreply, ChannelEvents.other_info(msg, socket)}
end
