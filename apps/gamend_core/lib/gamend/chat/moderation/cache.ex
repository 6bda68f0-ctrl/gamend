defmodule Gamend.Chat.Moderation.Cache do
  @moduledoc """
  Node-local hot path for chat moderation: the word blocklist and active mutes.

  Mirrors the shape of `GamendWeb.Plugs.IpBan` — the database is the source of
  truth, ETS is the per-message read path, and PubSub carries changes to the
  other instances (applied by `Gamend.Chat.Moderation.Sync`, which also loads
  both tables at boot).

  It lives in core rather than beside the IP-ban table in the web app because
  the check runs inside `Gamend.Chat.send_message/2`, before anything web-facing
  is involved.

  Substring matching goes through a compiled binary pattern (Aho-Corasick), kept
  in `:persistent_term` so a 10k-word list costs one pass over the message
  instead of 10k comparisons. It is rebuilt whole on every change, so bulk
  imports must insert their rows and call `reload_words/0` once rather than
  going through `put_word/1` per row.
  """

  alias Gamend.Chat.FilterWord
  alias Gamend.Chat.Moderation
  alias Gamend.Chat.Moderation.Normalizer
  alias Gamend.Chat.Mute

  @words_table :chat_filter_words
  @mutes_table :chat_mutes
  @pattern_key {__MODULE__, :substring_pattern}
  @topic "chat_moderation"

  @doc "PubSub topic on which moderation changes are broadcast."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Ensure the ETS tables exist (called once at app startup)."
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@words_table) == :undefined do
      :ets.new(@words_table, [:set, :public, :named_table, read_concurrency: true])
    end

    if :ets.whereis(@mutes_table) == :undefined do
      :ets.new(@mutes_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  # ── Word blocklist ─────────────────────────────────────────────────────────

  @doc """
  Look up the severity and match mode of `word` (already normalized).

  Returns `nil` when the word is not on the blocklist.
  """
  @spec lookup_word(String.t()) :: {String.t(), String.t()} | nil
  def lookup_word(word) do
    init_table()

    case :ets.lookup(@words_table, word) do
      [{^word, severity, match_mode}] -> {severity, match_mode}
      [] -> nil
    end
  end

  @doc "The compiled pattern of every `substring` word, or `nil` when there are none."
  @spec substring_pattern() :: :binary.cp() | nil
  def substring_pattern, do: :persistent_term.get(@pattern_key, nil)

  @doc "Number of words currently loaded on this node."
  @spec word_count() :: non_neg_integer()
  def word_count do
    init_table()
    :ets.info(@words_table, :size) || 0
  end

  @doc "Mirror a single blocklist entry locally and on the other instances."
  @spec put_word(FilterWord.t()) :: :ok
  def put_word(%FilterWord{} = word) do
    apply_word_put(word.word, word.severity, word.match_mode)

    broadcast(
      {:chat_moderation, :word_put, {word.word, word.severity, word.match_mode}, Node.self()}
    )
  end

  @doc "Remove a blocklist entry locally and on the other instances."
  @spec delete_word(String.t()) :: :ok
  def delete_word(word) when is_binary(word) do
    apply_word_delete(word)
    broadcast({:chat_moderation, :word_deleted, word, Node.self()})
  end

  @doc """
  Reload the whole blocklist from the database.

  Used after a bulk import or delete, and by `Sync` at boot. Broadcasts so the
  other instances reload too — the alternative is one message per word.
  """
  @spec reload_words() :: :ok
  def reload_words do
    apply_words_reload()
    broadcast({:chat_moderation, :words_reloaded, nil, Node.self()})
  end

  # ── Mutes ──────────────────────────────────────────────────────────────────

  @doc """
  Whether `user_id` is currently muted for the given chat.

  A `"global"` mute covers every chat type including friend DMs; a scoped mute
  only covers its own room. Expired entries are dropped on read, so enforcement
  never depends on the sweep having run.
  """
  @spec muted?(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) :: boolean()
  def muted?(user_id, chat_type, chat_ref_id) do
    init_table()

    active?({user_id, "global", nil}) or
      (chat_type in ["lobby", "group", "party"] and chat_ref_id != nil and
         active?({user_id, chat_type, chat_ref_id}))
  end

  @doc "Mirror a mute locally and on the other instances."
  @spec put_mute(Mute.t()) :: :ok
  def put_mute(%Mute{} = mute) do
    key = {mute.user_id, mute.scope, mute.scope_ref_id}
    apply_mute_put(key, mute.expires_at)
    broadcast({:chat_moderation, :mute_put, {key, mute.expires_at}, Node.self()})
  end

  @doc "Remove a mute locally and on the other instances."
  @spec delete_mute(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) :: :ok
  def delete_mute(user_id, scope, scope_ref_id) do
    key = {user_id, scope, scope_ref_id}
    apply_mute_delete(key)
    broadcast({:chat_moderation, :mute_deleted, key, Node.self()})
  end

  @doc "Number of active mutes loaded on this node."
  @spec mute_count() :: non_neg_integer()
  def mute_count do
    init_table()
    :ets.info(@mutes_table, :size) || 0
  end

  # ── Boot load ──────────────────────────────────────────────────────────────

  @doc """
  Load the blocklist and every unexpired mute from the database into ETS.

  Called at boot by `Gamend.Chat.Moderation.Sync`.
  """
  @spec load_persisted() :: :ok
  def load_persisted do
    apply_words_reload()
    apply_mutes_reload()
    :ok
  end

  @doc """
  Apply a change that originated on another instance.

  Only touches ETS — the originating instance already persisted it.
  """
  @spec apply_remote(atom(), term()) :: :ok
  def apply_remote(:word_put, {word, severity, match_mode}),
    do: apply_word_put(word, severity, match_mode)

  def apply_remote(:word_deleted, word), do: apply_word_delete(word)
  def apply_remote(:words_reloaded, _payload), do: apply_words_reload()
  def apply_remote(:mute_put, {key, expires_at}), do: apply_mute_put(key, expires_at)
  def apply_remote(:mute_deleted, key), do: apply_mute_delete(key)
  def apply_remote(_event, _payload), do: :ok

  # ── ETS writes (no broadcast) ──────────────────────────────────────────────

  defp apply_word_put(word, severity, match_mode) do
    init_table()
    :ets.insert(@words_table, {word, severity, match_mode})
    rebuild_pattern()
    :ok
  end

  defp apply_word_delete(word) do
    init_table()
    :ets.delete(@words_table, word)
    rebuild_pattern()
    :ok
  end

  defp apply_words_reload do
    init_table()
    rows = Gamend.Repo.all(FilterWord)

    :ets.delete_all_objects(@words_table)

    Enum.each(rows, fn row ->
      :ets.insert(@words_table, {row.word, row.severity, row.match_mode})
    end)

    rebuild_pattern()
    :ok
  end

  defp apply_mute_put(key, expires_at) do
    init_table()
    :ets.insert(@mutes_table, {key, expires_at || :infinity})
    :ok
  end

  defp apply_mute_delete(key) do
    init_table()
    :ets.delete(@mutes_table, key)
    :ok
  end

  defp apply_mutes_reload do
    init_table()
    :ets.delete_all_objects(@mutes_table)

    Enum.each(Moderation.list_active_mutes(), fn mute ->
      apply_mute_put({mute.user_id, mute.scope, mute.scope_ref_id}, mute.expires_at)
    end)

    :ok
  end

  defp rebuild_pattern do
    words =
      @words_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_word, _severity, match_mode} -> match_mode == "substring" end)
      |> Enum.map(fn {word, _severity, _match_mode} -> word end)
      |> Enum.reject(&(&1 in [nil, ""]))

    case words do
      [] -> :persistent_term.erase(@pattern_key)
      words -> :persistent_term.put(@pattern_key, :binary.compile_pattern(words))
    end

    :ok
  end

  defp active?(key) do
    case :ets.lookup(@mutes_table, key) do
      [{^key, :infinity}] ->
        true

      [{^key, %DateTime{} = expires_at}] ->
        if DateTime.after?(expires_at, DateTime.utc_now()) do
          true
        else
          :ets.delete(@mutes_table, key)
          false
        end

      _ ->
        false
    end
  end

  # Best-effort: a mute must still apply locally when PubSub is unavailable.
  defp broadcast(message), do: Gamend.Broadcast.best_effort(@topic, message, "chat moderation")

  @doc """
  Normalized form of `text`, for callers that only have the cache aliased.
  """
  @spec normalize(term()) :: String.t()
  defdelegate normalize(text), to: Normalizer
end
