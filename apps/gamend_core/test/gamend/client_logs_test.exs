defmodule Gamend.ClientLogsTest do
  use Gamend.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Gamend.AccountsFixtures
  alias Gamend.ClientLogs
  alias Gamend.ClientLogs.SessionLobby
  alias Gamend.Repo
  alias Gamend.SettingsHelpers

  setup do
    SettingsHelpers.put(:gamend_core, ClientLogs, :enabled, true)
    on_exit(fn -> SettingsHelpers.delete(:gamend_core, ClientLogs, :enabled) end)
    :ok
  end

  defp session_id, do: "sess-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp entry(seq, opts \\ []) do
    %{
      "seq" => seq,
      "at" => DateTime.utc_now() |> DateTime.to_unix(),
      "level" => Keyword.get(opts, :level, "info"),
      "category" => Keyword.get(opts, :category, "game"),
      "message" => Keyword.get(opts, :message, "entry #{seq}"),
      "lobby_id" => Keyword.get(opts, :lobby_id, ""),
      "screen" => Keyword.get(opts, :screen, "")
    }
  end

  defp batch(sid, entries, session_overrides \\ %{}) do
    %{
      "session" =>
        Map.merge(%{"client_session_id" => sid, "platform" => "android"}, session_overrides),
      "entries" => entries
    }
  end

  defp ingest(payload, opts \\ []) do
    {result, _log} = with_log(fn -> ClientLogs.ingest(payload, opts) end)
    result
  end

  # This env runs Logger at :warning, where the primary filter drops client
  # info/debug lines before any handler sees them. Assertions about those lines
  # have to lower it; `async: false` is what makes that safe.
  defp capture_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  describe "enabled?/0" do
    test "off by default" do
      SettingsHelpers.delete(:gamend_core, ClientLogs, :enabled)
      refute ClientLogs.enabled?()
      assert {:error, :disabled} = ClientLogs.ingest(batch(session_id(), []))
    end
  end

  describe "ingest/2" do
    test "creates a session and counts entries by level" do
      sid = session_id()

      assert {:ok, summary} =
               ingest(
                 batch(sid, [
                   entry(1),
                   entry(2, level: "warn"),
                   entry(3, level: "error")
                 ])
               )

      assert summary.accepted == 3
      assert summary.errors == 1

      session = ClientLogs.get_session(sid)
      assert session.entry_count == 3
      assert session.warn_count == 1
      assert session.error_count == 1
      assert session.max_seq == 3
      assert session.platform == "android"
      # A session that errored is kept past the ordinary retention window
      # without anyone having to remember to mark it.
      assert session.flagged
    end

    test "accumulates across batches" do
      sid = session_id()
      assert {:ok, _} = ingest(batch(sid, [entry(1), entry(2)]))
      assert {:ok, _} = ingest(batch(sid, [entry(3), entry(4)]))

      session = ClientLogs.get_session(sid)
      assert session.entry_count == 4
      assert session.max_seq == 4
      assert session.dropped_count == 0
      refute session.flagged
    end

    test "a gap in the sequence counts as dropped entries" do
      sid = session_id()
      assert {:ok, _} = ingest(batch(sid, [entry(1), entry(2)]))
      # The client's ring buffer overran: 3..7 never made it.
      assert {:ok, summary} = ingest(batch(sid, [entry(8)]))

      assert summary.dropped == 5
      assert ClientLogs.get_session(sid).dropped_count == 5
    end

    test "an out-of-order batch does not wind the high-water mark backwards" do
      sid = session_id()
      assert {:ok, _} = ingest(batch(sid, [entry(10)]))
      assert {:ok, _} = ingest(batch(sid, [entry(5)]))

      assert ClientLogs.get_session(sid).max_seq == 10
    end

    test "emits one Logger line per entry, carrying the session id" do
      sid = session_id()

      log =
        capture_info(fn ->
          ClientLogs.ingest(batch(sid, [entry(1, message: "Game starting", lobby_id: "lob-1")]))
        end)

      assert log =~ "[client] session=#{sid}"
      assert log =~ "Game starting"
      assert log =~ "lobby=lob-1"
      assert log =~ "cat=game"
    end

    test "client debug entries survive as Logger.info" do
      # The point of the level mapping: a host purging Logger.debug at compile
      # time in production must not silently discard verbose capture.
      sid = session_id()

      log =
        capture_info(fn ->
          ClientLogs.ingest(batch(sid, [entry(1, level: "debug", message: "frame budget")]))
        end)

      assert log =~ "[info]"
      assert log =~ "level=debug"
      assert log =~ "frame budget"
    end

    test "redacts secrets that leaked into a message" do
      sid = session_id()
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"

      log =
        capture_info(fn ->
          ClientLogs.ingest(
            batch(sid, [
              entry(1, message: "refresh failed token=#{jwt}"),
              entry(2, message: "auth password: hunter2 done")
            ])
          )
        end)

      refute log =~ jwt
      refute log =~ "hunter2"
      assert log =~ "[redacted]"
    end

    test "folds a multi-line message onto one line" do
      # A newline would end the log line early, and whatever followed it would
      # carry no `[client]` prefix — a client forging a server line to anything
      # that reads the file line by line.
      sid = session_id()

      log =
        capture_info(fn ->
          ClientLogs.ingest(
            batch(sid, [
              entry(1,
                message: "boom\n  at: _ready (res://boat.gd:42)\r\n[error] Repo is down",
                category: "net\nwork"
              )
            ])
          )
        end)

      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[client]"))
      assert line =~ "boom at: _ready (res://boat.gd:42) [error] Repo is down"
      assert line =~ "cat=net work"
      refute log =~ "\n[error]"
    end

    test "caps the batch and counts the overflow as dropped" do
      sid = session_id()
      entries = Enum.map(1..250, &entry/1)

      assert {:ok, summary} = ingest(batch(sid, entries))
      assert summary.accepted == 200
      assert summary.dropped == 50
    end

    test "skips entries with no message rather than failing the batch" do
      sid = session_id()

      assert {:ok, summary} =
               ingest(batch(sid, [entry(1), %{"seq" => 2, "level" => "info"}, entry(3)]))

      assert summary.accepted == 2
      assert summary.dropped == 1
    end

    test "rejects a session id that is too short to be a real one" do
      assert {:error, :invalid} = ingest(batch("abc", [entry(1)]))
    end
  end

  describe "device metadata" do
    test "is recorded once and survives later batches that omit it" do
      # The client stops re-sending the run's description after the first
      # accepted batch — it is the same few hundred bytes every 10s otherwise.
      # This is the behaviour that makes that safe.
      sid = session_id()

      first =
        batch(sid, [entry(1)], %{
          "app_version" => "1.4.2",
          "meta" => %{
            "os_version" => "17.2",
            "gpu" => "Apple A17 Pro",
            "rendering" => "mobile",
            "ram_mb" => 8192
          }
        })

      assert {:ok, _} = ingest(first)

      # A later batch carrying only the id, as the client sends it.
      assert {:ok, _} =
               ingest(%{"session" => %{"client_session_id" => sid}, "entries" => [entry(2)]})

      session = ClientLogs.get_session(sid)
      assert session.entry_count == 2
      assert session.app_version == "1.4.2"
      assert session.meta["os_version"] == "17.2"
      assert session.meta["rendering"] == "mobile"
      assert session.meta["ram_mb"] == 8192
    end

    test "caps how much a client can put in meta" do
      sid = session_id()
      wide = Map.new(1..60, fn i -> {"key#{i}", "value"} end)
      long = %{"browser" => String.duplicate("u", 4_000)}

      assert {:ok, _} = ingest(batch(sid, [entry(1)], %{"meta" => Map.merge(wide, long)}))

      meta = ClientLogs.get_session(sid).meta
      assert map_size(meta) <= 32
      assert Enum.all?(Map.values(meta), &(byte_size(to_string(&1)) <= 256))
    end
  end

  describe "ownership" do
    test "binds an anonymous session to the user who later logs in" do
      sid = session_id()
      user = AccountsFixtures.user_fixture()

      assert {:ok, _} = ingest(batch(sid, [entry(1)]))
      assert ClientLogs.get_session(sid).user_id == nil

      # Same run, now authenticated — the pre-login half is exactly the auth
      # logs someone would be chasing, so it must not be discarded.
      assert {:ok, _} = ingest(batch(sid, [entry(2)]), user_id: user.id)
      assert ClientLogs.get_session(sid).user_id == user.id
      assert ClientLogs.get_session(sid).entry_count == 2
    end

    test "refuses a session already owned by someone else" do
      sid = session_id()
      owner = AccountsFixtures.user_fixture()
      attacker = AccountsFixtures.user_fixture()

      assert {:ok, _} = ingest(batch(sid, [entry(1)]), user_id: owner.id)
      assert {:error, :forbidden} = ingest(batch(sid, [entry(2)]), user_id: attacker.id)
      assert ClientLogs.get_session(sid).entry_count == 1
    end
  end

  describe "lobbies" do
    test "records each lobby once and finds the session from either end" do
      sid = session_id()

      assert {:ok, _} =
               ingest(
                 batch(sid, [
                   entry(1, lobby_id: "lob-a"),
                   entry(2, lobby_id: "lob-a"),
                   entry(3, lobby_id: "lob-b")
                 ])
               )

      # Repeated batches for the same run must not duplicate rows.
      assert {:ok, _} = ingest(batch(sid, [entry(4, lobby_id: "lob-a")]))

      assert Repo.aggregate(SessionLobby, :count) == 2

      assert [found] = ClientLogs.list_sessions(lobby_id: "lob-a")
      assert found.client_session_id == sid
      assert [] = ClientLogs.list_sessions(lobby_id: "lob-zzz")
    end
  end

  describe "list_sessions/1" do
    test "filters by platform, errors and free-text" do
      android = session_id()
      web = session_id()

      assert {:ok, _} = ingest(batch(android, [entry(1, level: "error")]))
      assert {:ok, _} = ingest(batch(web, [entry(1)], %{"platform" => "web"}))

      assert [%{client_session_id: ^android}] = ClientLogs.list_sessions(platform: "android")
      assert [%{client_session_id: ^android}] = ClientLogs.list_sessions(errors_only: true)
      assert [%{client_session_id: ^web}] = ClientLogs.list_sessions(query: web)
      assert ClientLogs.count_sessions([]) == 2
    end
  end

  describe "retention" do
    test "prunes stale sessions but keeps flagged ones for the longer window" do
      quiet = session_id()
      errored = session_id()
      recent = session_id()

      assert {:ok, _} = ingest(batch(quiet, [entry(1, lobby_id: "lob-old")]))
      assert {:ok, _} = ingest(batch(errored, [entry(1, level: "error")]))
      assert {:ok, _} = ingest(batch(recent, [entry(1)]))

      # Age the first two past the 14-day window; the third stays current.
      long_ago = DateTime.add(DateTime.utc_now(), -30, :day)

      {2, _} =
        from(s in Gamend.ClientLogs.Session,
          where: s.client_session_id in ^[quiet, errored]
        )
        |> Repo.update_all(set: [last_seen_at: long_ago])

      Gamend.Retention.prune_all()

      # The quiet one is gone, along with its lobby rows...
      refute ClientLogs.get_session(quiet)

      assert Repo.aggregate(from(l in SessionLobby, where: l.client_session_id == ^quiet), :count) ==
               0

      # ...the errored one survives, because it is the one worth coming back to.
      assert ClientLogs.get_session(errored)
      assert ClientLogs.get_session(recent)
    end
  end

  describe "capture_policy/0" do
    test "parses category overrides from the flat list form" do
      SettingsHelpers.put(:gamend_core, ClientLogs, :category_levels, [
        "perf:off",
        "network:warn",
        "bogus",
        "camera:nonsense"
      ])

      on_exit(fn -> SettingsHelpers.delete(:gamend_core, ClientLogs, :category_levels) end)

      policy = ClientLogs.capture_policy()
      assert policy.categories == %{"perf" => "off", "network" => "warn"}
      assert policy.level == "info"
      assert policy.enabled
    end
  end
end
