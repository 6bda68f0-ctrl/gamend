defmodule GamendWeb.PresenceIndicator do
  @moduledoc """
  The online / idle / offline dot, shared by every surface that lists a user.

  Before this the web had exactly one presence indicator — a two-state pip on
  one host's world map — and none at all in chat, friends or groups. Two
  states meant someone who closed the tab a minute ago rendered the same as
  someone last seen a week back; `:recent` is the state that distinguishes them.

  Colours mirror the Godot client's `COLOR_ONLINE` / `COLOR_RECENT` /
  `COLOR_OFFLINE` exactly, so the same person shows the same colour in the game
  and on the site. Change them together or not at all.
  """
  use Phoenix.Component
  use Gettext, backend: GamendWeb.Gettext

  alias Gamend.Accounts.PresenceStatus

  # rgb(140,184,140) / rgb(255,217,51) / rgb(140,140,140) — the client's
  # Color(0.55,0.72,0.55), Color(1,0.85,0.2), Color(0.55,0.55,0.55).
  @colors %{
    online: "rgb(140, 184, 140)",
    recent: "rgb(255, 217, 51)",
    offline: "rgb(140, 140, 140)"
  }

  @doc "Colour for a status, for callers that draw their own mark (SVG, canvas)."
  @spec color(PresenceStatus.t()) :: String.t()
  def color(status), do: Map.get(@colors, status, @colors.offline)

  @doc "Screen-reader label; also the dot's tooltip."
  @spec label(PresenceStatus.t()) :: String.t()
  def label(:online), do: gettext("Online")
  def label(:recent), do: gettext("Recently online")
  def label(_), do: gettext("Offline")

  attr :status, :atom,
    default: :offline,
    values: [:online, :recent, :offline],
    doc: "from Gamend.Accounts.PresenceStatus.status/1"

  attr :size, :string, default: "0.55rem"
  attr :class, :string, default: nil

  @doc """
  A presence dot.

      <.presence_dot status={PresenceStatus.status(user)} />

  Offline stays visible in grey rather than disappearing: a missing dot reads as
  "no information", and the point is to say the person is away.
  """
  def presence_dot(assigns) do
    assigns =
      assigns
      |> assign(:dot_color, color(assigns.status))
      |> assign(:dot_label, label(assigns.status))

    ~H"""
    <span
      class={["inline-block shrink-0 rounded-full", @class]}
      style={"width: #{@size}; height: #{@size}; background-color: #{@dot_color};"}
      title={@dot_label}
      aria-label={@dot_label}
      role="img"
    ></span>
    """
  end
end
