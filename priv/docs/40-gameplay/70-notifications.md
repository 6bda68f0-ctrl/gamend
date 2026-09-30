---
icon: hero-bell
---

# Notifications

The notification system delivers real-time and persistent notifications for social events (friend requests, group invites, party actions), chat messages, and custom payloads. Every system-generated notification includes a metadata.type tag for client-side routing and filtering.

## API endpoints

Endpoints are under `/api/v1/notifications` - see [/api/docs](/api/docs).

There is deliberately **no** "mark as read" endpoint. Reading is server-side:
the web UI and `Notifications.mark_all_notifications_read/1` set the flag, so a
game client tracks its own seen state or deletes what it has handled.

## Notification schema

```json
{
  "id": "01977f5a-0009-7000-8000-3f6a2d8c0a09",
  "sender_id": "01977f5a-0001-7000-8000-3f6a2d8c0a01",
  "sender_name": "SomePlayer",
  "recipient_id": "01977f5a-0007-7000-8000-3f6a2d8c0a07",
  "title": "New Group Invite",
  "content": "You've been invited to join Cool Guild",
  "icon_url": "",
  "metadata": {"type": "group_invite", "group_id": "01977f5a-0005-7000-8000-3f6a2d8c0a05"},
  "inserted_at": "2026-02-22T12:00:00Z"
}
```

## Notification types (metadata.type)

All system-generated notifications include a type string in metadata for client-side routing. The set is closed: core's codes are below, plugins add theirs with `notification_types/0` (see [server scripting](/docs/server-scripting)), and a notification whose `metadata.type` is neither is rejected when it is written. The admin Runtime page lists every registered code. Below is core's list grouped by domain.

### Friends

```text
  ┌──────────────────────┬──────────────────────────────────────────────┐
  │ Type                 │ Description                                  │
  ├──────────────────────┼──────────────────────────────────────────────┤
  │ friend_request       │ New incoming friend request                  │
  │ friend_accepted      │ Your friend request was accepted             │
  │ friend_rejected      │ Your friend request was declined             │
  └──────────────────────┴──────────────────────────────────────────────┘
```

### Groups

```text
  ┌─────────────────────────────┬──────────────────────────────────────────────┐
  │ Type                        │ Description                                  │
  ├─────────────────────────────┼──────────────────────────────────────────────┤
  │ group_invite                │ Invited to join a group                      │
  │ group_invite_accepted       │ Your group invite was accepted               │
  │ group_invite_declined       │ Your group invite was declined               │
  │ group_join_request          │ Someone requested to join your group (admin) │
  │ group_join_request_approved │ Your group join request was approved         │
  │ group_join_request_rejected │ Your group join request was declined         │
  │ group_kicked                │ You were removed from a group                │
  │ group_promoted              │ You were promoted to admin                   │
  │ group_demoted               │ You were demoted to member                   │
  └─────────────────────────────┴──────────────────────────────────────────────┘
```

### Parties

```text
  ┌──────────────────────┬──────────────────────────────────────────────┐
  │ Type                 │ Description                                  │
  ├──────────────────────┼──────────────────────────────────────────────┤
  │ party_invite         │ Invited to join a party                      │
  │ party_invite_accepted│ Your party invite was accepted               │
  │ party_invite_declined│ Your party invite was declined               │
  │ party_kicked         │ You were removed from a party                │
  └──────────────────────┴──────────────────────────────────────────────┘
```

### Lobbies

```text
  ┌──────────────────────┬──────────────────────────────────────────────┐
  │ Type                 │ Description                                  │
  ├──────────────────────┼──────────────────────────────────────────────┤
  │ lobby_kicked         │ You were removed from a lobby                │
  └──────────────────────┴──────────────────────────────────────────────┘
```

### Chat

Chat notifications include a message_count field in metadata indicating how many unread messages triggered the notification.

```text
  ┌──────────────────────┬──────────────────────────────────────────────┐
  │ Type                 │ Description                                  │
  ├──────────────────────┼──────────────────────────────────────────────┤
  │ chat_friend          │ New friend DM messages                       │
  │ chat_group           │ New group chat messages                      │
  │ chat_lobby           │ New lobby chat messages                      │
  │ chat_party           │ New party chat messages                      │
  └──────────────────────┴──────────────────────────────────────────────┘
```

### Chat moderation

```text
  ┌──────────────────────┬──────────────────────────────────────────────┐
  │ Type                 │ Description                                  │
  ├──────────────────────┼──────────────────────────────────────────────┤
  │ chat_report          │ A chat report is waiting (sent to admins)    │
  │ chat_report_resolved │ A report you filed was reviewed              │
  │ chat_warning         │ A moderator sent you a warning               │
  │ chat_mute            │ You were muted in chat                       │
  └──────────────────────┴──────────────────────────────────────────────┘
```

### Quests

```text
  ┌──────────────────────┬──────────────────────────────────────────────┐
  │ Type                 │ Description                                  │
  ├──────────────────────┼──────────────────────────────────────────────┤
  │ quest_completed      │ A quest or achievement was completed         │
  └──────────────────────┴──────────────────────────────────────────────┘
```

`quest_completed` carries `quest_key`, `category` and `quest_title`.

## Behaviour notes

- Notifications upsert on (sender_id, recipient_id, title): sending the same notification again updates the existing one.
- Cancelling a friend request, group invite, or party invite automatically retracts (deletes) the original notification.
- Notifications are delivered in real time via PubSub on the "user:" topic and persisted to the database.
- Custom notifications can be sent between friends via POST /api/v1/notifications with any title, content, and metadata. A `metadata.type`, if present, must be a registered code.

## Real-time (WebSocket)

Connect to the UserChannel to receive notifications in real time. Each one arrives as a `notification_created` event on the "user:" topic; on join the channel replays the most recent 50, oldest first.

```javascript
  // JavaScript — join the user channel
  const channel = socket.channel("user:" + userId, {});
  channel.on("notification_created", (payload) => {
    console.log("New notification:", payload.metadata.type, payload);
  });
```

## Reference

- **HTTP API:** [/api/docs](/api/docs) - every endpoint, parameter and response, generated from the spec.
- **Elixir API:** [`Gamend.Notifications`](https://docs.gamend.org/Gamend.Notifications.html) - the functions a plugin calls, with their
  signatures and docs.
