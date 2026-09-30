defmodule Gamend.ChatModerationTest do
  # async: false — the blocklist and mute tables are named public ETS tables
  # shared by the whole VM, so a concurrent test would see this one's words.
  use Gamend.DataCase, async: false

  alias Gamend.Accounts.User
  alias Gamend.AccountsFixtures
  alias Gamend.Chat
  alias Gamend.Chat.Message
  alias Gamend.Chat.Moderation
  alias Gamend.Chat.Moderation.Cache
  alias Gamend.Chat.Moderation.Normalizer
  alias Gamend.Chat.Moderation.Notices
  alias Gamend.Chat.Reports
  alias Gamend.Notifications
  alias Gamend.Repo

  setup do
    Cache.init_table()
    on_exit(fn -> reset_cache() end)
    reset_cache()
    :ok
  end

  defp reset_cache do
    :ets.delete_all_objects(:chat_filter_words)
    :ets.delete_all_objects(:chat_mutes)
    :persistent_term.erase({Cache, :substring_pattern})
    :ok
  end

  defp create_user, do: AccountsFixtures.user_fixture()

  defp add_word(word, severity \\ "block", match_mode \\ "substring") do
    {:ok, filter_word} =
      Moderation.create_filter_word(%{
        "word" => word,
        "severity" => severity,
        "match_mode" => match_mode
      })

    filter_word
  end

  defp send_to_lobby(user, lobby_id, content) do
    Chat.send_message(%{user: user}, %{
      "chat_type" => "lobby",
      "chat_ref_id" => lobby_id,
      "content" => content
    })
  end

  describe "normalizer" do
    test "folds case, diacritics, repeats, leetspeak and punctuation to one key" do
      assert Normalizer.normalize("IDIOT") == "idiot"
      assert Normalizer.normalize("iiiidiot") == "idiot"
      assert Normalizer.normalize("ïdïot") == "idiot"
      assert Normalizer.normalize("1d10t") == "idiot"
      assert Normalizer.normalize("i.d.i.o.t") == "idiot"
      assert Normalizer.normalize("hello   world") == "helo world"
    end

    test "strips zero-width characters inserted to defeat matching" do
      assert Normalizer.normalize("id​iot") == "idiot"
    end

    test "returns an empty string for anything that is not a binary" do
      assert Normalizer.normalize(nil) == ""
      assert Normalizer.normalize(42) == ""
    end
  end

  describe "check_content/1" do
    test "passes clean content through untouched" do
      add_word("idiot")
      assert {:ok, "hello there", []} = Moderation.check_content("hello there")
    end

    test "blocks a block-severity hit, including evasive spellings" do
      add_word("idiot")

      assert {:error, :blocked_content} = Moderation.check_content("you idiot")
      assert {:error, :blocked_content} = Moderation.check_content("you 1d10t")
      assert {:error, :blocked_content} = Moderation.check_content("you IDIOT")
      assert {:error, :blocked_content} = Moderation.check_content("you ïdïot")
    end

    test "masks a mask-severity hit and leaves the rest of the message" do
      add_word("idiot", "mask")

      assert {:ok, "you *** there", []} = Moderation.check_content("you idiot there")
    end

    test "masks the whole token when the hit only appears after normalizing" do
      add_word("idiot", "mask")

      assert {:ok, "you *** there", []} = Moderation.check_content("you 1d10t there")
    end

    test "flags without altering the content" do
      add_word("idiot", "flag")

      assert {:ok, "you idiot", ["idiot"]} = Moderation.check_content("you idiot")
    end

    test "block wins over mask and flag in the same message" do
      add_word("badword", "block")
      add_word("meh", "mask")

      assert {:error, :blocked_content} = Moderation.check_content("meh badword")
    end

    test "exact mode matches a whole token only" do
      add_word("ass", "block", "exact")

      assert {:error, :blocked_content} = Moderation.check_content("you ass")
      assert {:ok, _content, []} = Moderation.check_content("classic passage")
    end

    test "substring mode matches inside a word" do
      add_word("ass", "block", "substring")

      assert {:error, :blocked_content} = Moderation.check_content("classic")
    end
  end

  describe "filter word CRUD" do
    test "stores the normalized form so lookups are stable" do
      word = add_word("IDIOT")
      assert word.word == "idiot"
    end

    test "rejects a duplicate word" do
      add_word("idiot")
      assert {:error, changeset} = Moderation.create_filter_word(%{"word" => "idiot"})
      assert %{word: ["has already been taken"]} = errors_on(changeset)
    end

    test "enforces max_chat_filter_words" do
      previous = Application.get_env(:gamend_core, Gamend.Limits, [])
      Application.put_env(:gamend_core, Gamend.Limits, [{:max_chat_filter_words, 1} | previous])
      on_exit(fn -> Application.put_env(:gamend_core, Gamend.Limits, previous) end)

      add_word("one")
      assert {:error, :too_many_filter_words} = Moderation.create_filter_word(%{"word" => "two"})
    end

    test "deleting a word stops it matching" do
      word = add_word("idiot")
      assert {:error, :blocked_content} = Moderation.check_content("idiot")

      {:ok, _} = Moderation.delete_filter_word(word)
      assert {:ok, "idiot", []} = Moderation.check_content("idiot")
    end

    test "deletes an imported list by language in bulk" do
      {:ok, _} = Moderation.create_filter_word(%{"word" => "aaa", "lang" => "de"})
      {:ok, _} = Moderation.create_filter_word(%{"word" => "bbb", "lang" => "de"})
      {:ok, _} = Moderation.create_filter_word(%{"word" => "ccc", "lang" => "en"})

      assert Moderation.delete_filter_words_by_lang("de") == 2
      assert Moderation.count_filter_words() == 1
    end
  end

  describe "bundled lists" do
    test "ships at least an english list and imports it" do
      assert "en" in Moderation.bundled_languages()

      assert {:ok, count} = Moderation.import_bundled_list("en", "block")
      assert count > 0
      assert Moderation.count_filter_words(%{"lang" => "en"}) == count
    end

    test "rejects an unknown language" do
      assert {:error, :unknown_language} = Moderation.import_bundled_list("nope")
    end
  end

  describe "mutes" do
    test "a global mute silences every chat type" do
      user = create_user()
      {:ok, _mute} = Moderation.mute_user(user.id, "global", nil)

      assert Moderation.muted?(user.id, "lobby", Ecto.UUID.generate())
      assert Moderation.muted?(user.id, "friend", Ecto.UUID.generate())
      assert Moderation.muted?(user.id, "party", Ecto.UUID.generate())
    end

    test "a scoped mute only covers its own room" do
      user = create_user()
      lobby_id = Ecto.UUID.generate()
      other_lobby_id = Ecto.UUID.generate()

      {:ok, _mute} = Moderation.mute_user(user.id, "lobby", lobby_id)

      assert Moderation.muted?(user.id, "lobby", lobby_id)
      refute Moderation.muted?(user.id, "lobby", other_lobby_id)
      refute Moderation.muted?(user.id, "friend", Ecto.UUID.generate())
    end

    test "an expired mute does not apply even before the sweep runs" do
      user = create_user()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _mute} = Moderation.mute_user(user.id, "global", nil, %{"expires_at" => past})

      refute Moderation.muted?(user.id, "lobby", Ecto.UUID.generate())
    end

    test "a future expiry still applies" do
      user = create_user()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _mute} = Moderation.mute_user(user.id, "global", nil, %{"expires_at" => future})

      assert Moderation.muted?(user.id, "lobby", Ecto.UUID.generate())
    end

    test "re-muting replaces the existing mute rather than failing" do
      user = create_user()
      {:ok, _} = Moderation.mute_user(user.id, "global", nil, %{"reason" => "first"})
      {:ok, mute} = Moderation.mute_user(user.id, "global", nil, %{"reason" => "second"})

      assert mute.reason == "second"
      assert Moderation.count_mutes(%{"user_id" => user.id}) == 1
    end

    test "unmute lifts it locally and in the database" do
      user = create_user()
      {:ok, _} = Moderation.mute_user(user.id, "global", nil)

      assert {:ok, 1} = Moderation.unmute_user(user.id, "global", nil)
      refute Moderation.muted?(user.id, "lobby", Ecto.UUID.generate())
      assert Moderation.count_mutes(%{"user_id" => user.id}) == 0
    end

    test "unmuting someone who is not muted is not an error" do
      user = create_user()
      assert {:ok, 0} = Moderation.unmute_user(user.id, "global", nil)
    end

    test "a global mute requires a nil scope_ref_id" do
      user = create_user()

      assert {:error, changeset} =
               Moderation.mute_user(user.id, "global", Ecto.UUID.generate())

      assert %{scope_ref_id: ["must be nil for a global mute"]} = errors_on(changeset)
    end

    test "a scoped mute requires a scope_ref_id" do
      user = create_user()
      assert {:error, changeset} = Moderation.mute_user(user.id, "lobby", nil)
      assert %{scope_ref_id: ["is required for a scoped mute"]} = errors_on(changeset)
    end

    test "the sweep deletes expired rows and keeps live ones" do
      user_a = create_user()
      user_b = create_user()
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} = Moderation.mute_user(user_a.id, "global", nil, %{"expires_at" => past})
      {:ok, _} = Moderation.mute_user(user_b.id, "global", nil, %{"expires_at" => future})

      assert Moderation.purge_expired_mutes() == 1
      assert Moderation.count_mutes() == 1
    end
  end

  describe "send_message enforcement" do
    setup do
      host = create_user()
      {:ok, lobby} = Gamend.Lobbies.create_lobby(%{title: "moderation", host_id: host.id})
      {:ok, user} = Gamend.Lobbies.join_lobby(create_user(), lobby.id)

      %{user: user, lobby_id: lobby.id}
    end

    test "a muted sender is rejected before anything is persisted", %{
      user: user,
      lobby_id: lobby_id
    } do
      {:ok, _} = Moderation.mute_user(user.id, "lobby", lobby_id)

      assert {:error, :muted} = send_to_lobby(user, lobby_id, "hello")
      assert Repo.aggregate(Message, :count, :id) == 0
    end

    test "a blocked word is rejected before anything is persisted", %{
      user: user,
      lobby_id: lobby_id
    } do
      add_word("idiot")

      assert {:error, :blocked_content} = send_to_lobby(user, lobby_id, "you idiot")
      assert Repo.aggregate(Message, :count, :id) == 0
    end

    test "a masked word is persisted in its masked form", %{user: user, lobby_id: lobby_id} do
      add_word("idiot", "mask")

      assert {:ok, message} = send_to_lobby(user, lobby_id, "you idiot")
      assert message.content == "you ***"
    end

    test "a flagged word is stored verbatim and files a system report", %{
      user: user,
      lobby_id: lobby_id
    } do
      add_word("idiot", "flag")

      assert {:ok, message} = send_to_lobby(user, lobby_id, "you idiot")
      assert message.content == "you idiot"
      assert message.metadata["flagged"] == true

      # The report is filed off the async post-commit path.
      assert eventually(fn -> Reports.count_reports(%{"message_id" => message.id}) == 1 end)

      [report] = Reports.list_reports()
      assert report.reporter_id == nil
      assert report.reported_user_id == user.id
      assert report.content_snapshot == "you idiot"
    end

    test "a clean message is unaffected", %{user: user, lobby_id: lobby_id} do
      add_word("idiot")

      assert {:ok, message} = send_to_lobby(user, lobby_id, "hello everyone")
      assert message.content == "hello everyone"
    end
  end

  describe "reports" do
    setup do
      reporter = create_user()
      sender = create_user()
      lobby_id = Ecto.UUID.generate()

      message =
        %Message{sender_id: sender.id}
        |> Message.changeset(%{
          chat_type: "lobby",
          chat_ref_id: lobby_id,
          content: "something rude"
        })
        |> Repo.insert!()

      %{reporter: reporter, sender: sender, message: message}
    end

    test "a player can report a message once", %{reporter: reporter, message: message} do
      assert {:ok, report} = Reports.report_message(reporter.id, message.id, "abusive")

      assert report.status == "open"
      assert report.reason == "abusive"
      assert report.content_snapshot == "something rude"

      assert {:error, :already_reported} =
               Reports.report_message(reporter.id, message.id, "again")
    end

    test "reporting your own message is rejected", %{sender: sender, message: message} do
      assert {:error, :own_message} = Reports.report_message(sender.id, message.id, nil)
    end

    test "reporting an unknown message is rejected", %{reporter: reporter} do
      assert {:error, :not_found} = Reports.report_message(reporter.id, Ecto.UUID.generate(), nil)
    end

    test "the report survives deletion of the message", %{reporter: reporter, message: message} do
      {:ok, report} = Reports.report_message(reporter.id, message.id, "abusive")
      {:ok, _} = Repo.delete(message)

      kept = Reports.get_report(report.id)
      assert kept.message_id == nil
      assert kept.content_snapshot == "something rude"
    end

    test "resolving records status, note and resolver", %{reporter: reporter, message: message} do
      moderator = create_user()
      {:ok, report} = Reports.report_message(reporter.id, message.id, "abusive")

      assert {:ok, resolved} =
               Reports.resolve_report(report, "actioned", %{
                 "note" => "muted for a day",
                 "resolved_by" => moderator.id
               })

      assert resolved.status == "actioned"
      assert resolved.resolution_note == "muted for a day"
      assert resolved.resolved_by == moderator.id
      assert resolved.resolved_at

      assert Reports.count_open_reports() == 0
    end

    test "counts by status back the admin queue", %{reporter: reporter, message: message} do
      {:ok, report} = Reports.report_message(reporter.id, message.id, "abusive")
      assert Reports.count_by_status() == %{"open" => 1}

      {:ok, _} = Reports.resolve_report(report, "dismissed")
      assert Reports.count_by_status() == %{"dismissed" => 1}
    end
  end

  describe "moderator workflow" do
    setup do
      reporter = create_user()
      sender = create_user()

      message =
        %Message{sender_id: sender.id}
        |> Message.changeset(%{
          chat_type: "lobby",
          chat_ref_id: Ecto.UUID.generate(),
          content: "something rude"
        })
        |> Repo.insert!()

      %{reporter: reporter, sender: sender, message: message}
    end

    test "a report starts open and can be claimed for review", %{
      reporter: reporter,
      message: message
    } do
      {:ok, report} = Reports.report_message(reporter.id, message.id, "abusive")
      assert report.status == "open"

      assert {:ok, reviewing} = Reports.review_report(report)
      assert reviewing.status == "reviewing"
      # Claiming is not a resolution: it stays in the queue.
      refute reviewing.resolved_at
    end

    test "every admin is alerted when a report lands", %{reporter: reporter, message: message} do
      admin_a = promote(create_user())
      admin_b = promote(create_user())

      {:ok, _report} = Reports.report_message(reporter.id, message.id, "abusive")

      for admin <- [admin_a, admin_b] do
        assert eventually(fn ->
                 Notifications.list_notifications_by_title(admin.id, Notices.report_title()) != []
               end),
               "admin #{admin.id} was not alerted"
      end
    end

    test "repeat reports collapse into one standing admin alert", %{
      reporter: reporter,
      sender: sender,
      message: message
    } do
      admin = promote(create_user())
      other_reporter = create_user()

      {:ok, _} = Reports.report_message(reporter.id, message.id, "abusive")
      {:ok, _} = Reports.report_message(other_reporter.id, message.id, "abusive too")
      _ = sender

      assert eventually(fn ->
               length(Notifications.list_notifications_by_title(admin.id, Notices.report_title())) ==
                 1
             end)
    end

    test "a muted player can be told, with a message a moderator can edit", %{sender: sender} do
      {:ok, mute} =
        Moderation.mute_user(sender.id, "global", nil, %{
          "expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "reason" => "spam"
        })

      default = Notices.default_mute_message(mute)
      assert default =~ "chat"
      assert default =~ "spam"

      :ok = Notices.notify_muted(sender.id, "Custom wording from the moderator")

      assert [notification] =
               Notifications.list_notifications_by_title(sender.id, Notices.mute_title())

      assert notification.content == "Custom wording from the moderator"
    end

    test "a permanent mute reads as permanent, a timed one names its expiry", %{sender: sender} do
      {:ok, permanent} = Moderation.mute_user(sender.id, "global", nil, %{"reason" => "spam"})
      refute Notices.default_mute_message(permanent) =~ "until"

      {:ok, timed} =
        Moderation.mute_user(sender.id, "global", nil, %{
          "expires_at" => DateTime.add(DateTime.utc_now(), 600, :second)
        })

      assert Notices.default_mute_message(timed) =~ "until"
    end

    test "a warning notifies without muting", %{sender: sender} do
      :ok = Notices.notify_warning(sender.id, Notices.default_warning_message("something rude"))

      assert [notification] =
               Notifications.list_notifications_by_title(sender.id, Notices.warning_title())

      assert notification.content =~ "something rude"
      refute Moderation.muted?(sender.id, "lobby", Ecto.UUID.generate())
    end

    test "the reporter can be told what came of it", %{reporter: reporter} do
      assert Notices.default_reporter_message("dismissed") =~ "no action"
      assert Notices.default_reporter_message("actioned") =~ "took action"

      :ok = Notices.notify_reporter(reporter.id, Notices.default_reporter_message("actioned"))

      assert [_notification] =
               Notifications.list_notifications_by_title(
                 reporter.id,
                 Notices.report_resolved_title()
               )
    end

    test "list_admin_ids returns admins only" do
      admin = promote(create_user())
      plain = create_user()

      ids = Gamend.Accounts.list_admin_ids()
      assert admin.id in ids
      refute plain.id in ids
    end
  end

  defp promote(user) do
    user
    |> User.admin_changeset(%{"is_admin" => true})
    |> Repo.update!()
  end

  # The flagged-report insert runs on Gamend.Async, so give it a moment.
  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
