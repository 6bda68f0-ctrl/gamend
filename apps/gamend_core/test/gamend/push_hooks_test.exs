defmodule Gamend.PushHooksTest do
  use Gamend.DataCase, async: false
  use Oban.Testing, repo: Gamend.Repo

  alias Gamend.AccountsFixtures
  alias Gamend.Push
  alias Gamend.Push.DeliveryWorker

  defmodule VetoHooks do
    use Gamend.TestSupport.NoopHooks

    @impl true
    def before_push_send(user_id, message) do
      send(:push_hooks_test, {:before_push_send, user_id})

      if message["data"]["veto"] == "yes" do
        {:error, :muted}
      else
        {:ok, message}
      end
    end
  end

  defmodule RewriteHooks do
    use Gamend.TestSupport.NoopHooks

    @impl true
    def before_push_send(_user_id, message) do
      {:ok, Map.put(message, "title", "[rewritten] " <> message["title"])}
    end
  end

  defmodule OversizeRewriteHooks do
    use Gamend.TestSupport.NoopHooks

    @impl true
    def before_push_send(_user_id, message) do
      {:ok, Map.put(message, "title", String.duplicate("x", 10_000))}
    end
  end

  defmodule ObserverHooks do
    use Gamend.TestSupport.NoopHooks

    @impl true
    def after_push_sent(user_id, message, result) do
      send(:push_hooks_test, {:after_push_sent, user_id, message, result})
      :ok
    end
  end

  setup do
    Process.register(self(), :push_hooks_test)
    original = Application.get_env(:gamend_core, :hooks_module)

    on_exit(fn ->
      if original,
        do: Application.put_env(:gamend_core, :hooks_module, original),
        else: Application.delete_env(:gamend_core, :hooks_module)
    end)

    :ok
  end

  defp use_hooks(module) do
    Application.put_env(:gamend_core, :hooks_module, module)
  end

  defp register!(user) do
    {:ok, token} =
      Push.register_token(user.id, %{
        "token" => "tok-#{System.unique_integer([:positive])}",
        "platform" => "android"
      })

    token
  end

  test "before_push_send can veto a push per user" do
    use_hooks(VetoHooks)
    user = AccountsFixtures.user_fixture()
    register!(user)

    assert :ok =
             Push.send_to_user(user.id, %{
               "title" => "Hi",
               "data" => %{"veto" => "yes"}
             })

    assert_received {:before_push_send, _}
    assert all_enqueued(worker: DeliveryWorker) == []

    assert :ok = Push.send_to_user(user.id, %{"title" => "Hi"})
    assert [_] = all_enqueued(worker: DeliveryWorker)
  end

  test "before_push_send can rewrite the message" do
    use_hooks(RewriteHooks)
    user = AccountsFixtures.user_fixture()
    register!(user)

    assert :ok = Push.send_to_user(user.id, %{"title" => "Hi"})

    assert [job] = all_enqueued(worker: DeliveryWorker)
    assert job.args["message"]["title"] == "[rewritten] Hi"
  end

  test "a rewrite that breaks the limits drops the push instead of enqueuing it" do
    use_hooks(OversizeRewriteHooks)
    user = AccountsFixtures.user_fixture()
    register!(user)

    assert :ok = Push.send_to_user(user.id, %{"title" => "Hi"})
    assert all_enqueued(worker: DeliveryWorker) == []
  end

  test "after_push_sent observes the delivery outcome" do
    use_hooks(ObserverHooks)
    user = AccountsFixtures.user_fixture()
    token = register!(user)

    args = %{
      "token_id" => token.id,
      "user_id" => user.id,
      "message" => %{"title" => "Hi"}
    }

    assert :ok = perform_job(DeliveryWorker, args)

    assert_received {:after_push_sent, user_id, %{"title" => "Hi"}, result}
    assert user_id == user.id
    assert result["status"] == "delivered"
    assert result["token_id"] == token.id
  end

  test "hooks are blocked from client RPC" do
    assert {:error, :disallowed} = Gamend.Hooks.call(:before_push_send, ["u", %{}])
    assert {:error, :disallowed} = Gamend.Hooks.call(:after_push_sent, ["u", %{}, %{}])
  end

  test "notifications bridge to push after commit" do
    sender = AccountsFixtures.user_fixture()
    recipient = AccountsFixtures.user_fixture()
    {:ok, request} = Gamend.Friends.create_request(sender.id, recipient.id)
    {:ok, _} = Gamend.Friends.accept_friend_request(request.id, recipient)
    register!(recipient)

    {:ok, notification} =
      Gamend.Notifications.send_notification(sender.id, %{
        "user_id" => recipient.id,
        "title" => "Game invite",
        "content" => "Join my lobby!"
      })

    assert [job] = all_enqueued(worker: DeliveryWorker)
    assert job.args["user_id"] == recipient.id
    assert job.args["message"]["title"] == "Game invite"
    assert job.args["message"]["body"] == "Join my lobby!"
    assert job.args["message"]["collapse_key"] == "notif-#{notification.id}"
    assert job.args["message"]["data"]["notification_id"] == notification.id
  end

  test "notifications to a user with no devices enqueue nothing" do
    sender = AccountsFixtures.user_fixture()
    recipient = AccountsFixtures.user_fixture()
    {:ok, request} = Gamend.Friends.create_request(sender.id, recipient.id)
    {:ok, _} = Gamend.Friends.accept_friend_request(request.id, recipient)

    {:ok, _} =
      Gamend.Notifications.send_notification(sender.id, %{
        "user_id" => recipient.id,
        "title" => "Game invite"
      })

    assert all_enqueued(worker: DeliveryWorker) == []
  end

  test "retention prunes stale tokens by updated_at" do
    user = AccountsFixtures.user_fixture()
    token = register!(user)

    days = 271
    stale = DateTime.add(DateTime.utc_now(:second), -days, :day)

    Repo.update_all(Gamend.Push.PushToken,
      set: [updated_at: stale]
    )

    original = Application.get_env(:gamend_core, Gamend.Retention, [])

    Application.put_env(
      :gamend_core,
      Gamend.Retention,
      Keyword.put(original, :push_tokens_days, 270)
    )

    on_exit(fn -> Application.put_env(:gamend_core, Gamend.Retention, original) end)

    results = Gamend.Retention.prune_all()
    assert results.push_tokens >= 1
    assert Push.count_tokens(user.id) == 0
    refute Repo.get(Gamend.Push.PushToken, token.id)
  end
end
