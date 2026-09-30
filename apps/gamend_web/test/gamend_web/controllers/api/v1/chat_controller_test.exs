defmodule GamendWeb.Api.V1.ChatControllerTest do
  use GamendWeb.ConnCase

  alias Gamend.AccountsFixtures
  alias Gamend.Chat.Message
  alias Gamend.Groups
  alias Gamend.Repo
  alias GamendWeb.Auth.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp create_user, do: AccountsFixtures.user_fixture()

  defp insert_message(sender, chat_type, chat_ref_id, content) do
    %Message{sender_id: sender.id}
    |> Message.changeset(%{chat_type: chat_type, chat_ref_id: chat_ref_id, content: content})
    |> Repo.insert!()
  end

  describe "GET /api/v1/chat/messages" do
    test "lists messages for group members", %{conn: conn} do
      owner = create_user()
      member = create_user()

      {:ok, group} =
        Groups.create_group(owner.id, %{"title" => "member-chat", "type" => "public"})

      {:ok, _} = Groups.join_group(member.id, group.id)

      message = insert_message(owner, "group", group.id, "group secret")

      conn =
        conn
        |> auth_conn(member)
        |> get("/api/v1/chat/messages", %{chat_type: "group", chat_ref_id: group.id})

      assert %{"data" => [%{"id" => id}]} = json_response(conn, 200)
      assert id == message.id
    end

    test "rejects non-members", %{conn: conn} do
      owner = create_user()
      outsider = create_user()

      {:ok, group} =
        Groups.create_group(owner.id, %{"title" => "private-chat", "type" => "public"})

      _message = insert_message(owner, "group", group.id, "group secret")

      conn =
        conn
        |> auth_conn(outsider)
        |> get("/api/v1/chat/messages", %{chat_type: "group", chat_ref_id: group.id})

      assert %{"error" => "not_in_group"} = json_response(conn, 403)
    end
  end

  describe "a group conversation" do
    test "send, read one, edit, mark read, count unread and delete", %{conn: conn} do
      owner = create_user()
      member = create_user()
      {:ok, group} = Groups.create_group(owner.id, %{"title" => "flow-chat", "type" => "public"})
      {:ok, _} = Groups.join_group(member.id, group.id)
      where = %{chat_type: "group", chat_ref_id: group.id}

      sent =
        conn
        |> auth_conn(owner)
        |> post("/api/v1/chat/messages", Map.put(where, :content, "first"))
        |> json_response(201)
        |> Map.fetch!("data")

      assert conn |> auth_conn(member) |> get("/api/v1/chat/unread", where) |> json_response(200) ==
               %{"data" => %{"unread_count" => 1}}

      got =
        conn
        |> auth_conn(member)
        |> get("/api/v1/chat/messages/#{sent["id"]}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert got["content"] == "first"

      edited =
        conn
        |> auth_conn(owner)
        |> patch("/api/v1/chat/messages/#{sent["id"]}", %{content: "edited"})
        |> json_response(200)
        |> Map.fetch!("data")

      assert edited["content"] == "edited"

      assert conn
             |> auth_conn(member)
             |> post("/api/v1/chat/read", Map.put(where, :message_id, sent["id"]))
             |> json_response(200)

      assert conn |> auth_conn(member) |> get("/api/v1/chat/unread", where) |> json_response(200) ==
               %{"data" => %{"unread_count" => 0}}

      assert conn
             |> auth_conn(owner)
             |> delete("/api/v1/chat/messages/#{sent["id"]}")
             |> json_response(200)

      assert conn
             |> auth_conn(member)
             |> get("/api/v1/chat/messages/#{sent["id"]}")
             |> json_response(404)
    end
  end

  describe "POST /api/v1/chat/read" do
    test "rejects message ids from another conversation", %{conn: conn} do
      owner = create_user()
      member = create_user()
      {:ok, group_a} = Groups.create_group(owner.id, %{"title" => "group-a", "type" => "public"})
      {:ok, group_b} = Groups.create_group(owner.id, %{"title" => "group-b", "type" => "public"})
      {:ok, _} = Groups.join_group(member.id, group_a.id)

      message_b = insert_message(owner, "group", group_b.id, "wrong group")

      conn =
        conn
        |> auth_conn(member)
        |> post("/api/v1/chat/read", %{
          chat_type: "group",
          chat_ref_id: group_a.id,
          message_id: message_b.id
        })

      assert %{"error" => "message_not_in_chat"} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/chat/unread" do
    test "rejects non-members", %{conn: conn} do
      owner = create_user()
      outsider = create_user()

      {:ok, group} =
        Groups.create_group(owner.id, %{"title" => "unread-chat", "type" => "public"})

      conn =
        conn
        |> auth_conn(outsider)
        |> get("/api/v1/chat/unread", %{chat_type: "group", chat_ref_id: group.id})

      assert %{"error" => "not_in_group"} = json_response(conn, 403)
    end
  end
end
