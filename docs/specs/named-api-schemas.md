# Named API schemas

Goal: every response shape in the OpenAPI document is a named component —
`Lobby`, `LobbyPage`, `PageMeta`, `ErrorResponse` — checked against what the
server actually sends, so any generator in any language produces types a
person would have written by hand.

This is the prerequisite for every SDK in [client-sdks.md](client-sdks.md).
Slices 1–4 named what was sent; after them the API was also reshaped to one
envelope (R15 in [api-conventions.md](api-conventions.md)), so from slice 5
each domain is named and reshaped in the same change.

## Why

The document describes 251 operations with 9 named schemas (the five
`ClientLog*` ones, `ErrorResponse`, `HealthResponse`, two OAuth). Everything
else is inline: 777 inline object schemas, 150 distinct shapes. The
`{error: string}` shape alone is restated 374 times.

Generators name what the document does not, from the operation and its
position:

- Godot gets 157 classes like `ListLobbies200ResponseDataInner`, and
  `generate_godot.sh` carries ~90 lines of `perl -i` rewriting the generator's
  snake/Pascal confusion about those invented names.
- A generator dedupes identical inline shapes, so every `{error}` becomes one
  class named after whichever operation came first.
- `polyglot-pirates-game` references 26 of these names across 8 files
  (`UserQuests200ResponseDataInner`, `GetMyRecord200ResponseData`, …).
- A C#, TypeScript or C++ SDK would ship the same names to every user,
  permanently.

And inline schemas drift, because nothing ties them to the serializer:

- `@lobby_schema` omits `state` and `state_changed_at`, which
  `Serializers.serialize_lobby/2` has sent since the lobby-state work.
- `join_lobby` and `set_lobby_state` document `%Schema{type: :object}` — no
  properties — while both return a full lobby.

A typed SDK drops a field its schema does not declare. Naming the shapes
without checking them would ship that loss into every generated client, so
the check is half of this spec.

## Scope

**In:** every response schema, public and admin.

**Out, deliberately:**

- **Wire changes, at first.** Slices 1–4 documented the wire as it was and
  listed what contradicted the conventions (see *Wire inconsistencies*). That
  list was then fixed in one breaking change — see *Reshaping* — and every
  later slice fixes its own as it goes.
- **Request bodies.** Generators already name an inline body
  `<OperationId>Request` (`CreateLobbyRequest`), which is the name anyone would
  choose. A body shared by several operations gets a module; the rest stay put.
  This also leaves `generate_balaur.py`, which reads `requestBody` schemas
  directly, untouched.

## Names

| Shape | Name | Example |
|---|---|---|
| A serialized entity | Singular noun, the proto message name where one exists | `Lobby`, `Group`, `UserBrief`, `ChatMessage` |
| A variant | Role prefix/suffix, never the operation | `User` / `UserBrief` / `CurrentUser`; `AdminLobby` |
| `{data: [T], meta}` | `<T>Page` | `LobbyPage` |
| `{data: T, …extras}` | `<T>Response` | `LobbyResponse` (`data`, `members`, `spectator_count`) |
| A bare entity | The entity | `create_lobby` → `Lobby` |
| Pagination block | `PageMeta` | the six keys from `Pagination.meta/4` |
| Any error | `ErrorResponse` | `error`, optional `reason`, optional `errors` (R12) |
| `/stats` counters | `<Area>Stats` | `LobbyStats` |

Matching the realtime proto's names (`Lobby`, `Group`, `Party`, `UserBrief`,
`ChatMessage`, `Notification`, `QuestProgress`, `KvEntry`) is the point, not
a nicety: an SDK can then use one `Lobby` type for `GET /lobbies/:id` and for
the `lobby:<id>` `updated` event.

A module's title is its last segment (`GamendWeb.Schemas.LobbyPage` →
`"LobbyPage"`), so the component key is predictable from the code. A test
asserts titles are unique across `GamendWeb.Schemas.*`: OpenApiSpex keys
components by title, and a clash silently keeps one.

## Mechanism

One module per shape in `apps/gamend_web/lib/gamend_web/schemas/`, the way
`ErrorResponse` and the `ClientLog*` schemas already are:

```elixir
defmodule GamendWeb.Schemas.Lobby do
  @moduledoc "A lobby as `Serializers.serialize_lobby/2` sends it."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Lobby",
    type: :object,
    properties: %{id: %Schema{type: :string, format: :uuid}, …},
    required: [:id, :title, …]
  })
end
```

Envelopes repeat the same few lines per entity, so one macro,
`GamendWeb.Schemas.Envelope`, writes them:

```elixir
defmodule GamendWeb.Schemas.LobbyPage do
  use GamendWeb.Schemas.Envelope, page: GamendWeb.Schemas.Lobby
end

defmodule GamendWeb.Schemas.LobbyStatsResponse do
  use GamendWeb.Schemas.Envelope, data: GamendWeb.Schemas.LobbyStats
end
```

Controllers reference modules (`items: Lobby`, `{"…", "application/json",
LobbyPage}`), and `OpenApiSpex.resolve_schema_modules/1` — already the last
step of `GamendWeb.ApiSpec.spec/0` — turns them into `$ref`s. Error responses
go through one helper, `GamendWeb.Schemas.error("Not authenticated")`, so the
374 restatements become one reference each.

`required` lists what the serializer always sends. Fields gated by an
option (`include_members`, `include_slowdown`) are declared but not required.

## The check

A test-only plug, `GamendWeb.ResponseContract`, registered by the endpoint
when `config :gamend_web, :response_contract, true` (set in
`apps/gamend_web/config/test.exs`, absent everywhere else, host repos
included). Before every JSON response from a controller that
declares OpenAPI operations, it:

1. validates the body against the documented schema for that status
   (OpenApiSpex's own cast, as `assert_operation_response/2` does);
2. fails on any key the schema does not declare — the drift typed SDKs would
   silently drop — for every object schema with `properties` and no
   `additionalProperties`;
3. fails on an undocumented 2xx status. An undocumented 4xx must still be an
   `ErrorResponse`, but need not be listed per operation: every error is the
   same type, so a missing status costs a client nothing. 5xx is skipped — a
   crash already fails the test, and the error page Phoenix renders after a
   violation would otherwise replace the violation's own message;
4. fails when a response documented as a bare `type: object` (no properties,
   no `additionalProperties`) has keys: a generator emits no type for it, so
   the payload is invisible to a typed client. Nested bare objects —
   `metadata`, KV values — are free-form by design and are not checked.

Exceptions rendered by `GamendWeb.ErrorJSON` are skipped: that shape belongs
to the endpoint, not the operation (see *Wire inconsistencies*).

It raises inside the request, so the existing controller tests become the
contract tests without being edited: the lobby suite's 44 tests exercise
every lobby operation. Enforcement was by tag — a list in the plug that grew
one domain per slice, a migration ratchet rather than a baseline. It was
deleted at close-out, once every domain was in: every documented operation is
checked, so a new endpoint meets its schema from its first test.

Two switches for working a slice, both test-run only:

- `RESPONSE_CONTRACT_REPORT=<file>` appends violations instead of raising, so
  one run shows all of a domain's drift rather than the first per test.
- `RESPONSE_CONTRACT_SEEN=<file>` records every checked operation and status.
  The check only sees what tests request; this shows which operations no test
  reaches, and each slice adds the tests that close that gap.

Run a slice with `MIX_TEST_PARTITION=<n>` when other suites share the SQLite
test database; concurrent runs otherwise fail with `Database busy`.

## Slices

One domain per change, each self-contained: modules, controller references,
the tag added to the check, tests green, spec regenerated.

1. **Pilot — Lobbies. Done.** `PageMeta`, `UserBrief`, `Lobby`, `LobbyPage`,
   `LobbyResponse`, `LobbyStats`, `LobbyStatsResponse`; `ErrorResponse`
   gains optional `reason` and `errors`. On the old inline schemas the check
   failed 17 of the 44 lobby tests — the drift below — and passes all of them
   on the named ones; the full web suite (1,993 tests) passes with it on.
   `generate_balaur.py` output is byte-identical before and after.
2. **Users, Authentication, Friends. Done.** 36 operations. `CurrentUser`,
   `LinkedProviders`, `PublicUser(Page)`, `UserBriefPage`, `ProfileUpdate`,
   `AvatarUpdate`, `UploadTicket`, `PlayerStats(Response)`,
   `Session(Response)`, `OAuthResult(Response)`, `OAuthAuthorization`,
   `AuthProvidersResponse`, `Friend(Page)`, `FriendRequest`,
   `FriendRequestLists`, `FriendRequestMeta`, `FriendRequestsResponse`,
   `BlockedFriendship(Page)`; `ErrorResponse` gains `message` and `details`.
   The report run found 13 distinct drifts; two operations had no test
   reaching their success response (`update_current_user_username`,
   `reject_friend_request`) and now do. Full web suite green; Balaur
   byte-identical. The OAuth exchanges answer tokens *or* a link result
   depending on a bearer token, modelled as one flat `OAuthResult` with every
   field optional rather than a `oneOf`, which game-engine generators handle
   poorly.
3. **Groups, Parties. Done.** 38 operations. `Group(Page)`,
   `GroupMember(Page)`, `GroupJoinRequest(Page)`, `GroupInvite(Page)`,
   `StatusResponse`, `Party`, `PartyInvite`, `PartyStats(Response)`; party
   lobby actions reuse `Lobby`, the icon ticket `UploadTicket`. The coverage
   switch showed no test reached the success response of any of the six
   party-invite operations; one flow test now covers invite, both lists,
   accept, cancel and decline.
4. **Chat, Notifications, Push. Done.** 24 operations. `ChatMessage(Page)`,
   `ChatReadCursor`, `ChatUnread(Response)`, `ChatMuteRecord` (with a page and
   a response; the realtime `ChatMute` is the muted player's smaller notice,
   hence the distinct name), `UnmuteResult`, `Notification(Page)`,
   `DeletedCount(Response)`, `PushToken(Page)`, `OkResponse`. Eight success
   responses had no test reaching them — the three mute lists and get, edit,
   delete, mark-read and unread-count of a chat message — and now do.
5. **Leaderboards, Tournaments. Done.** 14 operations, named and reshaped
   in one change. `Leaderboard(Page, Response)`, `LeaderboardRecord(Page,
   Response)`, `LeaderboardsBySlug(Response)`, `Tournament(Page,
   Response)`, `TournamentEntry(Page, Response)`, `TournamentMatchResponse`,
   `TournamentBracketPage`, `TournamentStandings(Response)` with
   `TournamentPlacement`. The report run flagged seven of the eight
   tournament operations (documented `{}` or a bare entity; join answered
   `{ok, entry}`) and every leaderboard error, which was prose. Eight error
   responses had no test reaching them and now do.
6. **Quests, Economy, Payments. Done.** 18 operations. `Quest(Page)`,
   `QuestObjective`, `QuestReward`, `QuestProgress`, `QuestClaim(Response)`,
   `QuestStats(Response)`, `LedgerEntry(Page)`, `WalletBalances(Response)`,
   `Inventory(Response)`, `PaymentProduct`, `PaymentCatalogEntry(Page)`,
   `Purchase(Response)`, `Entitlement(Page)`, `StripeCheckout(Response)`,
   `SteamCheckout(Response)`, `PurchaseValidation(Response)`,
   `PaymentWebhookReceipt(Response)`. `Gamend.Payments` gained opt-in paging
   for the catalog and entitlements (`count_catalog/1`,
   `count_user_entitlements/2`). The report run found no drift in what was
   sent, only in what was documented; eight responses had no test reaching
   them and now do. The payment controllers share one error mapper,
   `GamendWeb.Api.V1.PaymentErrors`. `ApiShapeTest` gained R6 on the document,
   which caught five nullable ids in slice 5's `TournamentMatch`.
7. **KV, Hooks, Matchmaking, Ready checks, Time, Signaling, Health, Client
   logs, Stats. Done.** 19 operations (Storage has no player operation; its
   uploads live on their entities). `KvEntry(Response)`, `HookFunction(Page)`,
   `HookSignature`, `HookCallResponse`, `MatchmakingTicket(Response)`,
   `MatchmakingQueue`, `MatchmakingStats(Response)`, `CancelledCount(Response)`,
   `ReadyCheckState(Response)`, `ReadyCheckParticipant`,
   `MyReadyChecks(Response)`, `ServerTime(Response)`, `Health(Response)`,
   `ClientLogPolicyResponse`, `ClientLogResultResponse`,
   `SignalingStats(Response)`, `ActivityStats`, `TournamentStats`,
   `TournamentMatchCounts`, `ServerStats(Response)`; `GamendWeb.ApiStatsSchema`
   is gone. Every non-admin tag is now enforced. The report run found no
   violations once shaped; `list_hooks` and `get_server_time` had no test and
   now do. `HookFunction` is declared `struct?: false`: its `fn` property is
   reserved in Elixir.
8. **Admin – \*. Done.** 94 operations in 17 tags, in three passes (social,
   game, operations). An admin answer with the player's shape is the
   player's type (`Lobby`, `Group`, `Notification`, `ChatMessage`,
   `Leaderboard`, `TournamentMatch`, `ServerStats`): `serialize_leaderboard/1`
   and `serialize_tournament_match/2` moved to `GamendWeb.Serializers` so
   both sides send one shape. Everything else is an `Admin<T>` or a named
   report (`ChatReport`, `ChatFilterWord`, `QuestFunnel`, `RetentionStatus`,
   `AnalyticsSummary`, `StorageUsage`, ...). Only 17 of the 94 had a test
   reaching their success response; every one with a JSON body does now (the
   storage download is bytes). Two 500s surfaced on the way (below).
   Every tag in the document is now enforced.
9. **Close-out. Done, but for the game.** The tag list is gone: every
   operation is checked. R15 is in `mix gamend.api.lint`: an API controller
   answers through `GamendWeb.Reply`, never `json/2`, and documents a JSON
   response with a named module, never an inline `%Schema{}`. The rule found
   the two undocumented API controllers (the local upload target and the
   `/api/v1` 404), which kept their own shapes because no contract saw them.
   `generate_godot.sh` lost 46 of its 56 `perl` rewrites and its snake_case
   class mapping: replayed one by one against the raw generator output, the
   44 per-model renames, the per-call `bzz_denormalize` rename, the
   `OAuthSessionData_details` rename (the suffix join already does it) and the
   mapping change nothing, and the script without them writes a
   byte-identical addon.
   **Left:** migrating `polyglot-pirates-game` with `clients/godot_migrate.py`.

Request bodies stay inline, on the reasoning that the generator names them
`<OperationId>Request`. That held for 72 of 93. The generator merges bodies
that are identical down to their descriptions and keeps the first
operation's name for all of them, and controllers share bodies through module
attributes, so 21 operations took someone else's class: the player's own
avatar upload an `AdminSetQuestIconRequest`, `join_lobby` a
`PartyJoinLobbyRequest`, `kick_user` a `KickPartyMemberRequest`.
**Fixed:** `GamendWeb.Schemas.RequestTitles`, the last step of
`GamendWeb.ApiSpec.spec/0`, titles every inline object body
`<OperationId>Request`. Distinct titles stop the merge, and the title is the
name the generator already gave the other 72, so only the 21 change. A
nested inline item under a titled body is referenced as
`<Parent>_<snake>` by the GDScript generator; `generate_godot.sh` joins it
back to the class name.

## SDK impact

The document gets better; generated client class names change. Nothing on
the wire moves, so an existing build keeps working until it regenerates.

- **Godot.** GDScript `class_name` is global, and a game is likely to have
  its own `Lobby` or `Quest`. Generate with `--model-name-prefix Gamend`
  (`GamendLobby`), which also renames the request classes — once, in the same
  release as the response renames, rather than two breaks. The hand-written
  facade's references (`GamendApi.gd`, `GamendAuth.gd`, `GamendClient.gd`)
  update in that change. **Decided: `GamendLobby`.** Verified against
  openapi-generator 7.26: named `$ref`s resolve to correct class names
  (`GamendUserBrief.bzz_denormalize_multiple`), while references to
  still-inline models come out as `Gamend<snake_case>`
  (`Gamendaccept_party_invite_200_response_members_inner`) — 162 before slice
  2, 138 after, zero at close-out, when the generic snake_case mapping in
  `generate_godot.sh` went with them. What the document still leaves inline
  (request body items, `OAuthSessionData.details`) is referenced as
  `<Parent>_<snake>`, which the script joins back to the class name. **Done:** the script
  generates with the prefix and the facade uses the new names. Checked by
  loading all 311 addon scripts in headless Godot 4.7 and by a live run of
  13 calls against a dev server, each denormalizing into its named class.
  That run found two generator faults, both fixed in post-processing: an
  untyped property (`ErrorResponse.details`) came out as the nonexistent
  `AnyType`, and every enum-array setter rejected its own value — so
  `list_auth_providers` had always returned no providers.
- **JavaScript.** Model classes are renamed; method names and call shapes are
  not. Only code importing model classes by name notices.
- **Balaur.** Untouched — it is untyped, and request bodies stay inline.
- **Migration.** `clients/godot_migrate.py OLD_ADDON NEW_ADDON GAME_ROOT`
  derives the old → new class names instead of a hand-kept table: it pairs
  each operation's response class across the two addons, then each nested
  property's class, and falls back to the prefixed twin for request bodies.
  Pairing by position is what makes it exact — a dozen old envelopes are all
  `{data, meta}`. On a copy of `polyglot-pirates-game` (vendored addon from
  before slice 1, regenerated addon after slice 2) it mapped all 47 classes
  the game names, rewrote 9 scripts, and the game compiled exactly as before
  (764 scripts, the same one unrelated failure). The game itself is migrated
  once, at close-out: every remaining slice renames more of what it uses.
- **Checks.** `clients/check_godot.sh` compiles every addon script in headless
  Godot; with a server URL it also makes live calls that must land in their
  named classes. The JS `generate` script clears its previous output first,
  so a renamed model does not linger in the package.

## Reshaping (R15)

Slices 1–4 then moved to the four response shapes, as one breaking change:
74 of their 108 success responses changed. Bare entities went under `data`
(a create answers 201 with the new row), `{}` became `{"ok": true}`, every
profile change answers the whole `CurrentUser`, the OAuth session poll answers
`{data: {status, message, result}}`, unmute answers `{data: {deleted}}`,
party invitation lists became pages (the context gained paging and counts),
and `group_name` became `group_title`. Errors became `snake_case` codes with
optional `message` prose; `details` and `reason` folded into `message` or into
`validation_failed`, which is now always 422 (409 for a uniqueness clash).
Phoenix's own error pages and the auth pipeline's 401 took the same shape.
Controllers answer through `GamendWeb.Reply` (`reply_data`, `reply_page`,
`reply_pages`, `reply_ok`, `reply_error`), and two tests hold it:
`GamendWeb.ApiShapeTest` on the document, `GamendWeb.ResponseContract` on
every response the suite provokes. From slice 5 on, a domain is named and
reshaped in one change.

## Wire inconsistencies

Recorded as each slice finds them. Everything below from slices 1–4 was fixed
by the reshaping above, except where noted:

- Lobby mutations (`create`, `update`, `join`, `quick_join`, `set_state`)
  return a bare lobby, not `{data: lobby}`.
- `leave`, `kick`, `disband` return `{}`, not `{"ok": true}`.
- `set_lobby_state` returns `{error, reason}` where `reason` is an
  `inspect/1` of an Elixir term.
- `host_id` is `""` for a hostless lobby, so it cannot carry `format: :uuid`
  (the never-null policy and the format disagree). Same for `lobby_id` and
  `party_id` on users.
- Exceptions on API routes render `GamendWeb.ErrorJSON`:
  `{"errors": {"detail": "Not Found"}}`, not `{"error": "not_found"}`. An
  unknown or disabled OAuth provider answers this way.
- Auth errors carry `message` (prose) and `details` (a string or a field map)
  besides `error`; convention R12 puts field detail under `errors`.
- `/me` profile changes answer validation failures with
  `error: "invalid_data"` (R12 says `validation_failed`), status 400 not 422.
- `PublicUser.lobby_id` and `party_id` are always `""`: kept so the shape
  matches the member row, but they carry nothing. *(Fixed at close-out: gone,
  and the test asserts their absence, since a public lobby id is the
  discovery half of joining a room uninvited.)*
- Password, display-name and username changes answer `{ok, id, …}`; avatar
  confirmation `{ok, profile_url}` — neither is `{data: …}`.
- The OAuth exchange answers two unrelated shapes under `data` depending on
  whether a bearer token was sent. *(Fixed: sign-in answers `Session`, linking
  is its own endpoints under `/api/v1/me/providers` and answers the current
  user; `OAuthResult` and `OAuthSessionData` are gone.)*
- `GroupInvite.group_name` is the group's title; convention says a thing has
  a `title` and nothing is called `name`.
- Party invitation lists are bare arrays: no `{data, meta}`, no paging.
- Group invite actions answer `{status}`; the matching party ones `{}`.
- A mute answers `{data: mute}`, while sending a notification or registering a
  push token answers the bare entity.

Slice 5, all fixed in the same change:

- Leaderboard errors were prose (`"Leaderboard not found"`, `"No record found
  for this user"`, a sentence for a missing `slugs`); now `not_found`,
  `record_not_found`, `missing_param`.
- Records around a user were an array without `meta`; now one complete page.
- Tournament join answered `{ok, entry}`; now the entry under `data`.
- The bracket answered `{data: {brackets, entries, matches}, meta}`: three
  lists beside one page's `meta`. Now a page of brackets, each carrying its
  own matches and the entries they name.
- `my_match` answered `{"data": null}` when there was no match; now 404
  `no_current_match`, like `not_in_party`.
- Standings sent their placements under `entries`, the key that holds
  `TournamentEntry` rows everywhere else; now `placements`.
- The entries page counted every entry whatever the `state` filter, so
  `total_count` and `has_more` were wrong for a filtered list.
- Every tournament refusal was 400, and a failed changeset 400
  `invalid_data` with `errors` (R12). Refusals now follow the status rule in
  api-conventions.md; the changeset answers 422 `validation_failed`.
- `TournamentMatch` did not document `a_entry_id` and `b_entry_id`, which it
  always sent.
- Across slices 1–3, `already_member`, `already_admin` and `already_in_lobby`
  answered 403 from four operations and 409 from the others; now 409
  everywhere.

Slice 6, all fixed in the same change:

- The payments catalog and entitlements were bare arrays under `data`: no
  `meta`, no paging.
- Seven of the eight payment operations documented `{}`, so a generated
  client had no type for any purchase, checkout or entitlement.
- Every payment error was 400, and a reason that was not an atom went out as
  its `inspect/1` text. A failed changeset was 400 `invalid_data`.
- Webhooks answered `{ok, status}`; Steam finalize wrapped its purchase in
  `{purchase}` with nothing beside it.
- A quest claim vetoed by a hook answered `{error, reason}` with `reason` an
  `inspect/1` of the hook's term; `not_completed` was 409, though nothing
  about it already holds.
- `Quest.category` and `prerequisite_quest_key` were documented nullable while
  the serializer sends `""`.

Slice 7, all fixed in the same change:

- Health, the clock and both client-log answers were bare top-level objects;
  a KV read put `metadata` beside `data`; ready checks answered bare, and
  cancelling one `{}`.
- `GET /matchmaking/tickets/me` answered `{"data": null}` with no ticket.
- Answering a ready check with none open was 409 while cancelling one was
  404, for the same `no_open_check`.
- A hook call's refusals carried `max`, `max_bytes` and `details` beside
  `error`; an unknown plugin was 400.
- `ControllerScope` answered `"Not authenticated"`, a sentence, for every
  controller using it (chat mutes and ready checks).
- The hook listing named each function's name `name` (R16), while
  `call_hook` takes it as `fn`.
- The ready check documented no `metadata`, which it always sent.

Found by the R6 document check: twelve admin schemas declared a nullable
`format: :uuid` string (`user_id`, `lobby_id`, `host_id`, `match_id`,
`opened_by`). `mix gamend.api.lint` exempted any line with `format:`, which is
why it missed them. *(Fixed in slice 8: the inline schemas are gone, the
serializers send `""`, and the lint exempts dates only.)*

Slice 8, all fixed in the same change:

- 77 of the 94 admin operations documented a bare `{}` or an inline schema
  no test reached; admin leaderboards, records and quests answered raw Ecto
  structs through their `Jason.Encoder`, so the admin quest never gained
  `group_key`/`group_title` and a label record sent `user_id: null`.
- Two lists put a second value beside the page: the filter words'
  `languages` and storage's `usage`. Each is now its own endpoint.
- Deletes answered `{}`, `{ok, key}`, `{ok, removed}` or `{data: {deleted:
  true}}`; grants `{ok, user_id, currency, balance}`; resolving a match
  `{ok, winner_entry_id}`; analytics, retention and the quest funnel were
  bare top-level objects.
- Quest and chat-moderation changesets answered `{errors}` with no `error`,
  or `invalid` with `details`; admin push answered 400 `invalid_message`
  with an `errors` list of strings.
- `DELETE /admin/groups/:id` for an unknown group raised
  `Ecto.NoResultsError` (500), and a hook veto was reported as not found.
- Admin finish right after an early draw set `ends_at == starts_at`, failed
  validation on a hard `{:ok, _} =` match and answered 500.

Schema drift the pilot fixed in the document (the wire was already right):

- `Lobby` lacked `state` and `state_changed_at`.
- Lobby members lacked `is_activated`.
- `host_id` was `format: :uuid, nullable: true`; it is a string that is
  `""` when hostless.
- `join_lobby` and `set_lobby_state` documented an empty object; both return
  a `Lobby`. Six operations gained the error statuses their code returns.

Slice 2 (document fixes, plus two wire fixes that could not break a client):

- Every user row lacked `is_activated`; `/me/blacklist` and `/me/blocked`
  documented three of the member row's eight fields.
- Device login was documented with the OAuth polling payload
  (`OAuthSessionData`), which lacks `username`.
- Password, display-name, username, avatar-ticket and avatar-confirm answers
  were documented as empty objects.
- *Wire:* a friend request whose requester or target was not preloaded sent a
  six-field placeholder; it now goes through `serialize_brief/1` like a loaded
  one, adding `profile_url` and `is_activated`.
- *Wire:* an OAuth sign-up that failed validation put `changeset.errors` (a
  keyword list of tuples) in the body, which Jason cannot encode — a 500. It
  answers 400 with `errors` now.

Found by the live JavaScript check, fixed across the whole API:

- 17 operations behind `:api_auth` declared no usable security — nine none
  at all, eight a `"bearer"` scheme the document does not define — so the
  JavaScript SDK never sent its token and got 401 from all of them
  (`get_lobby`, every chat operation, matchmaking, tournament join/leave/
  my-match, `my_quests`, `claim_quest`, `get_my_record`). Godot hid it by
  sending the token on every request. `list_records_around_user` declared
  `"bearer"` on a route that does not authenticate; it declares nothing now.
- The seven `:api_optional_auth` operations declared nothing, so a signed-in
  JavaScript client called them anonymously and was told a hidden group it
  belongs to does not exist. They declare the token as optional.
- `GamendWeb.ApiSecurityTest` keeps router and document in agreement; the
  rule is in [api-conventions.md](api-conventions.md).

Slice 4 (document only):

- A mute answers `{data: mute}`; it was documented as the bare mute.
- Unmute answers `{ok, removed}`, reporting and deleting a message
  `{ok: true}`, marking read the read cursor; all four were documented as
  empty objects.
- Mute-list `meta` was documented with four of its six keys; the message and
  push-token lists' `meta` as an empty object.

Slice 3 (document only):

- Party members lacked `is_activated`: they are `UserBrief` rows.
- `creator_id` was a UUID "or -1 for system groups"; it is `""` for one.
- Creating or joining a lobby as a party was documented as an empty object;
  both return the `Lobby`. The group icon ticket likewise, as `UploadTicket`.
- `last_seen_at` on members carried `format: "date-time"` as a string, which
  OpenApiSpex does not treat as the date-time format, so it was never checked.

## Definition of done (CONTRIBUTING)

- [x] Every response schema is a `GamendWeb.Schemas.*` module or a `$ref` to
      one; request bodies inline unless shared.
- [x] `GamendWeb.ResponseContract` enforced for every tag; tag list removed.
- [x] Title uniqueness test.
- [x] R15 in `Gamend.ApiConventions` with no violations; documented in
      [api-conventions.md](api-conventions.md), including the naming table.
- [x] `generate_godot.sh` regenerated with the model prefix; dead `perl`
      fixups removed; facade updated; JS SDK regenerated; Balaur `--check`
      clean.
- [ ] CHANGELOG `[breaking]` per slice with the old → new name table.
- [ ] `mix format`, `mix credo --strict`, full `mix test` green on both
      adapters; `mix gamend.api.lint` clean.
