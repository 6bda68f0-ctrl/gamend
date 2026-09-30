defmodule GamendWeb.QuestGroupSelector do
  @moduledoc """
  A host's selector over quest groups on the quests page.

  Quests sharing a `group_key` collapse to one card each, which reads fine for
  three groups and is a wall for fifty. A host with one group per language
  registers a module here — `config :gamend_web, :quest_group_selector,
  MyApp.QuestLanguages` — and `GamendWeb.QuestsLive` draws its control instead
  of the plain select, lists ONE picked group at a time, and keeps every group
  the selector does not cover as the collapsed card it always was.

  Behind a registered selector, nothing picked lists NO covered group: the
  selector is the way in, and the wall of cards is what it exists to replace.
  So `c:default_group/1` matters — the language a player is learning, say.
  """

  @doc "Whether the selector covers this group. The rest stay collapsed cards."
  @callback selectable?(group :: %{key: String.t(), title: String.t()}) :: boolean()

  @doc "The group to open on for this user (nil for a visitor), or nil for none."
  @callback default_group(user_id :: String.t() | nil) :: String.t() | nil

  @doc """
  The control, as a function component. `groups` are the covered groups as
  `%{key, title}` (titles as stored), `selected` the picked key or nil. It has
  to send the `"group"` event with a `group` param — a
  `<form phx-change="group">` around a `<select name="group">` is the whole
  contract.
  """
  @callback selector(assigns :: map()) :: Phoenix.LiveView.Rendered.t()
end
