defmodule Gamend.Chat.Moderation do
  @moduledoc """
  Chat word filter and mutes.

  The enforcement side of chat moderation: an admin-managed blocklist checked
  against every outgoing message, and mutes that silence a sender globally or
  in one lobby/group/party. Both are checked in `Gamend.Chat.send_message/2`
  before the message is persisted, so nothing unmoderated reaches the database
  or PubSub.

  Reports live in `Gamend.Chat.Reports`.

  Writes go to the database first and are then mirrored into
  `Gamend.Chat.Moderation.Cache` (ETS + PubSub), which is what the per-message
  path actually reads.
  """

  import Ecto.Query

  alias Gamend.Chat.FilterWord
  alias Gamend.Chat.Moderation.Cache
  alias Gamend.Chat.Moderation.Normalizer
  alias Gamend.Chat.Mute
  alias Gamend.Repo

  @bundled_dir "chat_filter"

  # ── Word filter: matching ──────────────────────────────────────────────────

  @doc """
  Run `content` through the blocklist.

  Returns `{:error, :blocked_content}` when a `block` word matches,
  `{:ok, content, flagged_words}` otherwise — `content` has any `mask` hits
  replaced with `***`, and `flagged_words` is non-empty when a `flag` word
  matched (the caller files a report once the message is persisted).

  Masking works on whole whitespace-separated tokens, because a hit is found in
  the normalized form and its offsets do not map back onto the original text.
  If a masked message still matches (a multi-word phrase that no single token
  covers) it is blocked rather than sent through half-masked.
  """
  @spec check_content(String.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, :blocked_content}
  def check_content(content) when is_binary(content) do
    case hits(content) do
      [] ->
        {:ok, content, []}

      hits ->
        if Enum.any?(hits, &(elem(&1, 1) == "block")) do
          {:error, :blocked_content}
        else
          resolve_non_blocking(content, hits)
        end
    end
  end

  def check_content(content), do: {:ok, content, []}

  defp resolve_non_blocking(content, hits) do
    flagged = for {word, "flag", _mode} <- hits, do: word
    mask_words = for {word, "mask", _mode} <- hits, do: word

    case mask_words do
      [] ->
        {:ok, content, flagged}

      mask_words ->
        masked = mask_tokens(content, mask_words)

        if Enum.any?(hits(masked), &(elem(&1, 1) == "mask")) do
          {:error, :blocked_content}
        else
          {:ok, masked, flagged}
        end
    end
  end

  @doc """
  Every blocklist entry matching `content`, as `[{word, severity, match_mode}]`.

  Exposed for the admin "test a phrase" box so it reports exactly what the
  runtime path would do.
  """
  @spec hits(String.t()) :: [{String.t(), String.t(), String.t()}]
  def hits(content) when is_binary(content) do
    normalized = Normalizer.normalize(content)

    (exact_hits(normalized) ++ substring_hits(normalized))
    |> Enum.uniq_by(&elem(&1, 0))
  end

  def hits(_content), do: []

  defp exact_hits(""), do: []

  defp exact_hits(normalized) do
    normalized
    |> String.split(" ", trim: true)
    |> Enum.uniq()
    |> Enum.flat_map(fn token ->
      case Cache.lookup_word(token) do
        {severity, "exact" = mode} -> [{token, severity, mode}]
        _ -> []
      end
    end)
  end

  defp substring_hits(""), do: []

  defp substring_hits(normalized) do
    case Cache.substring_pattern() do
      nil ->
        []

      pattern ->
        normalized
        |> :binary.matches(pattern)
        |> Enum.map(fn {pos, len} -> :binary.part(normalized, pos, len) end)
        |> Enum.uniq()
        |> Enum.flat_map(fn word ->
          case Cache.lookup_word(word) do
            {severity, mode} -> [{word, severity, mode}]
            nil -> []
          end
        end)
    end
  end

  defp mask_tokens(content, mask_words) do
    content
    |> String.split(~r/(\s+)/u, include_captures: true)
    |> Enum.map_join(fn token ->
      normalized = Normalizer.normalize(token)

      if normalized != "" and Enum.any?(mask_words, &String.contains?(normalized, &1)) do
        "***"
      else
        token
      end
    end)
  end

  # ── Word filter: CRUD ──────────────────────────────────────────────────────

  @doc "List blocklist entries. Filters: `:word`, `:severity`, `:lang`."
  @spec list_filter_words(map(), keyword()) :: [FilterWord.t()]
  def list_filter_words(filters \\ %{}, opts \\ []) do
    filters
    |> filter_words_query()
    |> order_by([w], asc: w.word)
    |> Gamend.Query.page(opts)
    |> Repo.all()
  end

  @doc "Count blocklist entries matching `filters`."
  @spec count_filter_words(map()) :: non_neg_integer()
  def count_filter_words(filters \\ %{}) do
    filters |> filter_words_query() |> Repo.aggregate(:count, :id)
  end

  @doc "Fetch one blocklist entry."
  @spec get_filter_word(Ecto.UUID.t()) :: FilterWord.t() | nil
  def get_filter_word(id), do: Repo.get(FilterWord, id)

  @doc """
  Add a word to the blocklist.

  Rejected with `{:error, :too_many_filter_words}` once
  `max_chat_filter_words` is reached.
  """
  @spec create_filter_word(map()) :: {:ok, FilterWord.t()} | {:error, term()}
  def create_filter_word(attrs) do
    with :ok <- check_word_capacity(1) do
      %FilterWord{}
      |> FilterWord.changeset(attrs)
      |> Repo.insert()
      |> tap_ok(&Cache.put_word/1)
    end
  end

  @doc "Update a blocklist entry."
  @spec update_filter_word(FilterWord.t(), map()) :: {:ok, FilterWord.t()} | {:error, term()}
  def update_filter_word(%FilterWord{} = word, attrs) do
    previous = word.word

    word
    |> FilterWord.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn updated ->
      if previous != updated.word, do: Cache.delete_word(previous)
      Cache.put_word(updated)
    end)
  end

  @doc "Remove a blocklist entry."
  @spec delete_filter_word(FilterWord.t()) :: {:ok, FilterWord.t()} | {:error, term()}
  def delete_filter_word(%FilterWord{} = word) do
    word
    |> Repo.delete()
    |> tap_ok(fn deleted -> Cache.delete_word(deleted.word) end)
  end

  @doc "Delete every blocklist entry with the given `lang` tag. Returns the count."
  @spec delete_filter_words_by_lang(String.t()) :: non_neg_integer()
  def delete_filter_words_by_lang(lang) when is_binary(lang) do
    {count, _} = Repo.delete_all(from(w in FilterWord, where: w.lang == ^lang))
    Cache.reload_words()
    count
  end

  defp filter_words_query(filters) do
    query = from(w in FilterWord)

    query =
      case Gamend.Parse.blank_to_nil(Map.get(filters, :word) || Map.get(filters, "word")) do
        nil ->
          query

        value ->
          pattern = "%#{Repo.escape_like(Normalizer.normalize(value))}%"
          where(query, [w], fragment("? LIKE ? ESCAPE '\\'", w.word, ^pattern))
      end

    query =
      case Gamend.Parse.blank_to_nil(Map.get(filters, :severity) || Map.get(filters, "severity")) do
        nil -> query
        value -> where(query, [w], w.severity == ^value)
      end

    case Gamend.Parse.blank_to_nil(Map.get(filters, :lang) || Map.get(filters, "lang")) do
      nil -> query
      value -> where(query, [w], w.lang == ^value)
    end
  end

  defp check_word_capacity(adding) do
    cap = Gamend.Limits.get(:max_chat_filter_words)

    if cap > 0 and count_filter_words() + adding > cap do
      {:error, :too_many_filter_words}
    else
      :ok
    end
  end

  # ── Word filter: bundled lists ─────────────────────────────────────────────

  @doc """
  Languages with a bundled word list available to import.

  The lists are vendored under `priv/chat_filter/<lang>.txt`; nothing is loaded
  until an admin imports it.
  """
  @spec bundled_languages() :: [String.t()]
  def bundled_languages do
    case File.ls(bundled_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".txt"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Import the bundled list for `lang`.

  Every word goes through the normal changeset, so `max_chat_filter_word_len`
  applies and duplicates are skipped. Returns `{:ok, imported_count}` or
  `{:error, :unknown_language | :too_many_filter_words}`.
  """
  @spec import_bundled_list(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def import_bundled_list(lang, severity \\ "block") do
    path = Path.join(bundled_dir(), "#{lang}.txt")

    with true <- lang in bundled_languages() and File.exists?(path),
         {:ok, contents} <- File.read(path) do
      words =
        contents
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

      case check_word_capacity(length(words)) do
        :ok -> {:ok, insert_bundled(words, lang, severity)}
        error -> error
      end
    else
      false -> {:error, :unknown_language}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_bundled(words, lang, severity) do
    rows =
      words
      |> Enum.map(fn word ->
        %FilterWord{}
        |> FilterWord.changeset(%{
          "word" => word,
          "lang" => lang,
          "severity" => severity,
          "match_mode" => "substring"
        })
      end)
      |> Enum.filter(& &1.valid?)
      |> Enum.map(fn changeset ->
        now = DateTime.utc_now(:second)

        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.take([:word, :severity, :match_mode, :lang])
        |> Map.merge(%{id: Gamend.UUIDv7.generate(), inserted_at: now, updated_at: now})
      end)
      |> Enum.uniq_by(& &1.word)

    {count, _} = Repo.insert_all(FilterWord, rows, on_conflict: :nothing, conflict_target: :word)

    # One rebuild for the whole import rather than one per word.
    Cache.reload_words()
    count
  end

  defp bundled_dir do
    Application.app_dir(:gamend_core, ["priv", @bundled_dir])
  end

  # ── Mutes ──────────────────────────────────────────────────────────────────

  @doc """
  Whether `user_id` is currently muted for the given chat (ETS read).
  """
  @spec muted?(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) :: boolean()
  defdelegate muted?(user_id, chat_type, chat_ref_id), to: Cache

  @doc """
  Mute `user_id`.

  `scope` is `"global"` (every chat, `scope_ref_id` nil) or one of `"lobby"`,
  `"group"`, `"party"` with the room id as `scope_ref_id`. `attrs` may carry
  `expires_at` (nil means permanent), `reason` and `muted_by`.

  Re-muting an already-muted user replaces the existing mute, so a moderator
  can extend or shorten one without unmuting first.
  """
  @spec mute_user(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil, map()) ::
          {:ok, Mute.t()} | {:error, term()}
  def mute_user(user_id, scope, scope_ref_id, attrs \\ %{}) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{
        "user_id" => user_id,
        "scope" => scope,
        "scope_ref_id" => scope_ref_id
      })

    %Mute{}
    |> Mute.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:expires_at, :reason, :muted_by, :updated_at]},
      conflict_target: conflict_target(scope_ref_id)
    )
    |> tap_ok(fn mute ->
      Cache.put_mute(mute)
      notify_user(mute.user_id, {:chat_muted, mute})
      dispatch(:after_user_muted, [mute])
    end)
  end

  # The composite index does not constrain global mutes (NULL never equals
  # NULL), so those upsert against the partial index instead.
  defp conflict_target(nil), do: {:unsafe_fragment, "(user_id, scope) WHERE scope_ref_id IS NULL"}
  defp conflict_target(_ref), do: [:user_id, :scope, :scope_ref_id]

  @doc "Remove a mute. Returns `{:ok, count}` — 0 when the user was not muted."
  @spec unmute_user(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) :: {:ok, non_neg_integer()}
  def unmute_user(user_id, scope, scope_ref_id \\ nil) do
    {count, _} =
      Repo.delete_all(
        from(m in Mute,
          where: m.user_id == ^user_id and m.scope == ^scope,
          where: ^scope_ref_match(scope_ref_id)
        )
      )

    Cache.delete_mute(user_id, scope, scope_ref_id)

    if count > 0 do
      notify_user(
        user_id,
        {:chat_unmuted, %{user_id: user_id, scope: scope, scope_ref_id: scope_ref_id}}
      )
    end

    {:ok, count}
  end

  defp scope_ref_match(nil), do: dynamic([m], is_nil(m.scope_ref_id))
  defp scope_ref_match(ref), do: dynamic([m], m.scope_ref_id == ^ref)

  @doc "Fetch one mute."
  @spec get_mute(Ecto.UUID.t()) :: Mute.t() | nil
  def get_mute(id), do: Repo.get(Mute, id) |> Repo.preload([:user, :muted_by_user])

  @doc """
  List mutes. Filters: `:user_id`, `:scope`, `:scope_ref_id`, `:active` (when
  true, only unexpired mutes).
  """
  @spec list_mutes(map(), keyword()) :: [Mute.t()]
  def list_mutes(filters \\ %{}, opts \\ []) do
    filters
    |> mutes_query()
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> Gamend.Query.page(opts)
    |> preload([:user, :muted_by_user])
    |> Repo.all()
  end

  @doc "Count mutes matching `filters`."
  @spec count_mutes(map()) :: non_neg_integer()
  def count_mutes(filters \\ %{}) do
    filters |> mutes_query() |> Repo.aggregate(:count, :id)
  end

  @doc "Every unexpired mute, for the boot load."
  @spec list_active_mutes() :: [Mute.t()]
  def list_active_mutes do
    now = DateTime.utc_now()
    Repo.all(from(m in Mute, where: is_nil(m.expires_at) or m.expires_at > ^now))
  end

  @doc """
  Delete mutes whose `expires_at` has passed. Returns the number removed.

  Hygiene only — `muted?/3` already ignores expired entries, so a missed sweep
  never lets a mute outlive its expiry.
  """
  @spec purge_expired_mutes() :: non_neg_integer()
  def purge_expired_mutes do
    now = DateTime.utc_now()

    {count, _} =
      Repo.delete_all(from(m in Mute, where: not is_nil(m.expires_at) and m.expires_at <= ^now))

    # No cache work: `muted?/3` drops expired entries as it reads them.
    count
  end

  defp mutes_query(filters) do
    query = from(m in Mute)

    query =
      case Gamend.Parse.blank_to_nil(Map.get(filters, :user_id) || Map.get(filters, "user_id")) do
        nil -> query
        value -> where(query, [m], m.user_id == ^to_string(value))
      end

    query =
      case Gamend.Parse.blank_to_nil(Map.get(filters, :scope) || Map.get(filters, "scope")) do
        nil -> query
        value -> where(query, [m], m.scope == ^value)
      end

    query =
      case Gamend.Parse.blank_to_nil(
             Map.get(filters, :scope_ref_id) || Map.get(filters, "scope_ref_id")
           ) do
        nil -> query
        value -> where(query, [m], m.scope_ref_id == ^to_string(value))
      end

    if Map.get(filters, :active) || Map.get(filters, "active") do
      now = DateTime.utc_now()
      where(query, [m], is_nil(m.expires_at) or m.expires_at > ^now)
    else
      query
    end
  end

  # ── Shared helpers ─────────────────────────────────────────────────────────

  @doc false
  def normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result

  # The muted player's own socket, so the client can grey out its chat input.
  # Best-effort for the same reason the cache broadcast is.
  defp notify_user(user_id, event), do: Gamend.Broadcast.best_effort("user:#{user_id}", event)

  # Hooks never run inside the write — they are queued and flushed after it.
  defp dispatch(hook, args) do
    Gamend.Async.run(fn -> Gamend.Hooks.internal_call(hook, args) end)
    :ok
  end
end
