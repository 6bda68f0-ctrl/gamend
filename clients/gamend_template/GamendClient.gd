# gdlint: disable=max-public-methods
# ^ deliberate: GamendClient is the SDK facade — a wide public surface is its job.
class_name GamendClient
extends Node
## Game-agnostic client layer on top of GamendApi: a verified KV subscription
## registry with automatic (re)subscription, an in-memory row cache fed by
## subscribe replies and live pushes, and optional disk persistence.
##
## Register the keys the game cares about once (register_kv); the client
## subscribes them whenever the user channel (re)joins, verifies every reply —
## a rejected subscribe is a loud signal instead of a silently dropped result —
## re-evaluates dynamic keys on refresh_keys(), and keeps the latest row per
## key readable at any time (get_row / fetch_row).
##
## Quickstart — everything a game needs, start to finish:
##
##   var api := GamendApi.new("mygame.com", 443, true)
##   add_child(api)
##   var client := GamendClient.new()
##   add_child(client)
##   client.setup(api, func() -> String: return api._user_id)
##   client.plugin = "my_hook"
##
##   # Login: resume the saved session, else log in as this device.
##   # The token persists on its own (user://gamend_auth.cfg) — the next
##   # launch restores silently. Own settings system? Override
##   # client.auth.secret_get / secret_set instead.
##   await client.auth.restore_session()
##   var error := ""
##   if api.is_authenticated():
##       error = await client.auth.save_session()
##   else:
##       error = await client.auth.device_auth()
##   if not error.is_empty():
##       push_error(error)   # or show your login screen / provider buttons:
##                           # await client.auth.provider_auth(GamendApi.PROVIDER_GOOGLE)
##
##   # Live server data: declare once, read any time, react to pushes.
##   client.register_kv("progress", "", {"persist": true})
##   client.refresh_keys()
##   client.kv_row_changed.connect(func(key, row): print(key, " -> ", row))
##
##   # Who is around — fills itself from realtime events, just read it:
##   client.presence.user_changed.connect(func(id): print(client.presence.get_user(id)))
##
##   # Reconnect handling with default policies; map the signals to your UI.
##   client.enable_network_watch()
##   client.network_failed.connect(func(_kind, msg): show_offline_popup(msg))
##
##   # Server logic (hook RPCs):
##   var reply: Dictionary = await client.rpc_call("start_game", ["word_match"])

## A row in the cache changed — from a live push, a subscribe reply that carried
## data, a fetch, or the disk cache loading at login.
signal kv_row_changed(key: String, row: Dictionary)
## The server confirmed a subscription; `row` is the current value ({} when the
## row does not exist yet).
signal kv_subscribed(key: String, row: Dictionary)
## The server rejected a subscription (e.g. "forbidden"). Always also logged.
signal kv_subscribe_failed(key: String, error_message: String)

## Network watchdog (opt-in via enable_network_watch) — connection state as
## signals, so the game owns every popup/UI decision:
## Entered reconnecting (automatic recoveries stay invisible during the grace
## window — show UI on network_reconnecting_display, not here).
signal network_reconnecting(message: String)
## Still down after the grace window (or an explicit retry): show the UI now.
signal network_reconnecting_display(message: String)
## Back to connected (popups hide here).
signal network_recovered
## A reconnect finished a verified channel rejoin — the moment to refetch
## whatever pushes were missed while the socket was down.
signal network_rejoined
## Gave up: `kind` is "timeout" | "request" | "revalidate" | "retry" |
## "external"; `message` is the server/caller text ("" for timeout — the game
## supplies its own wording).
signal network_failed(kind: String, message: String)

## A hook rpc_call answered with an error (also returned to the caller).
signal rpc_failed(fn: String, error_message: String)

## "" disables disk persistence entirely. Rows registered with persist=true are
## written here (namespaced per user) and reloaded on the next login, so the
## game can paint last-known values before the network answers.
var cache_file_path := "user://gamend_client_cache.cfg"

var _api: GamendApi
var _user_id_provider: Callable
## name -> {key_source, user_scoped, persist, subscribe, active_key}
var _registrations: Dictionary = {}
## key -> row (session cache; {} is a valid cached value: "known missing").
var _rows: Dictionary = {}
var _subscribed: Dictionary = {}
var _subscribe_in_flight: Dictionary = {}
## Backoff schedule for transiently failed subscribes (one entry per retry).
## Auth rejections (401/403) never retry — they cannot heal within a session.
var subscribe_retry_delays_sec: Array = [2.0, 5.0, 15.0]
## key -> failed subscribe attempts on this connection.
var _subscribe_attempts: Dictionary = {}
var _fetch_in_flight: Dictionary = {}
## key -> completed-fetch counter, so a waiter can tell "someone fetched fresh
## data while I waited" from "the cache is just old" (matters for force).
var _fetch_generation: Dictionary = {}
var _channel_up := false
var _cache_file: ConfigFile

## Automatic reconnects stay UI-silent this long; a recovery inside the window
## never surfaces (fast Wi-Fi blips don't flash popups).
var reconnect_grace_sec := 3.0
## Reconnecting for longer than this fails hard (kind "timeout").
var reconnect_timeout_sec := 15.0

var _watch_enabled := false
## "connected" | "reconnecting" | "failed"
var _net_state := "connected"
## Bumped on every state change; cancels stale grace/timeout timers.
var _net_attempt_id := 0
## Game-supplied hooks: is_session_active() -> bool (post-login, where only a
## verified channel rejoin counts as recovery), revalidate() -> bool (async
## session check on rejoin), retry_login() -> bool (async re-auth for retry).
var _watch_hooks: Dictionary = {}


## Authentication flows (client.auth.provider_auth(...) etc.); built in setup().
var auth: GamendAuth
## Who is around — users/lobbies/presence, self-maintained from realtime
## events (client.presence.users etc.); built in setup().
var presence: GamendPresence


func setup(api: GamendApi, user_id_provider: Callable) -> void:
	_api = api
	_user_id_provider = user_id_provider
	auth = GamendAuth.new()
	auth.name = "GamendAuth"
	add_child(auth)
	auth.setup(api)
	presence = GamendPresence.new()
	presence.name = "GamendPresence"
	add_child(presence)
	presence.setup(api)
	_api.user_channel_joined.connect(_on_channel_joined)
	_api.user_channel_disconnected.connect(_on_channel_disconnected)
	_api.kv_updated.connect(_on_kv_push)


## Register a KV key to subscribe and cache. `key_source` is the key string, or
## a Callable returning it for keys that depend on runtime state (locale pairs);
## "" means "use `name` itself". Options:
##   user_scoped (true)  — subscribe/fetch under the current user's id
##   persist     (false) — mirror the row to cache_file_path across sessions
##   subscribe   (true)  — false registers cache-only (fetch_row still works)
func register_kv(name: String, key_source: Variant = "", options: Dictionary = {}) -> void:
	_registrations[name] = {
		"key_source": key_source if (key_source is Callable or (key_source is String and not str(key_source).is_empty())) else name,
		"user_scoped": bool(options.get("user_scoped", true)),
		"persist": bool(options.get("persist", false)),
		"subscribe": bool(options.get("subscribe", true)),
		"active_key": "",
	}
	if _channel_up:
		_subscribe_entry(_registrations[name])


## Re-evaluate every registration's key and subscribe anything not yet
## confirmed. Call after login (the join can precede the user id existing) and
## whenever an input to a dynamic key changes (e.g. the target language): the
## old key is unsubscribed, the new one subscribed.
func refresh_keys() -> void:
	if not _channel_up:
		return
	for name in _registrations:
		var entry: Dictionary = _registrations[name]
		var new_key := _entry_key(entry)
		var old_key := str(entry.get("active_key", ""))
		if not old_key.is_empty() and old_key != new_key and _subscribed.has(old_key):
			_subscribed.erase(old_key)
			_api.kv_unsubscribe_ws(old_key, _entry_user_id(entry))
		_subscribe_entry(entry)


## Latest cached row for a key ({} when unknown or known-missing).
func get_row(key: String) -> Dictionary:
	var row: Variant = _rows.get(key, {})
	return (row as Dictionary).duplicate(true) if row is Dictionary else {}


## Whether the cache holds an answer for the key — including the authoritative
## "row does not exist" ({}), which get_row alone cannot distinguish.
func has_row(key: String) -> bool:
	return _rows.has(key)


## Drop a cached row so the next fetch_row goes to the network.
func clear_row(key: String) -> void:
	_rows.erase(key)


## Drop every cached row — call on logout so nothing crosses users.
func clear_all_rows() -> void:
	_rows.clear()


## Cache-first read of a KV row with in-flight dedupe. A 404 is the server's
## authoritative "no row yet" and caches {} (live pushes overwrite it the
## moment the row exists); transient failures stay uncached so a later call
## retries.
func fetch_row(key: String, user_scoped := true, force := false) -> Dictionary:
	return await fetch_cached(key, _kv_fetcher(key, user_scoped), force)


## Waiters sharing an in-flight fetch give up after this long and return the
## current cache — the escape hatch if a game-supplied fetcher hangs (the
## SDK's own fetchers are bounded by the api's HTTP timeout).
var fetch_wait_timeout_sec := 30.0


## Transport-agnostic cache-first fetch: same caching/dedupe as fetch_row, but
## the caller supplies the fetcher (a hook RPC, an HTTP call, anything async).
## The fetcher returns the Dictionary to cache — {} is cached as an
## authoritative empty — or null for a transient failure, which caches nothing
## so a later call retries. Concurrent callers share one network fetch; a
## `force` caller that finds a fetch already completing while it waited takes
## that result instead of fetching again.
func fetch_cached(key: String, fetcher: Callable, force := false) -> Dictionary:
	if not force and _rows.has(key):
		return get_row(key)
	var start_generation := int(_fetch_generation.get(key, 0))
	var wait_deadline_ms := Time.get_ticks_msec() + int(fetch_wait_timeout_sec * 1000.0)
	while _fetch_in_flight.get(key, false):
		if Time.get_ticks_msec() > wait_deadline_ms:
			return get_row(key)
		await get_tree().process_frame
	if _rows.has(key) and (not force or int(_fetch_generation.get(key, 0)) != start_generation):
		return get_row(key)
	_fetch_in_flight[key] = true
	var value: Variant = await fetcher.call()
	_fetch_in_flight.erase(key)
	_fetch_generation[key] = int(_fetch_generation.get(key, 0)) + 1
	if value is Dictionary:
		_store_row(key, value as Dictionary)
	return get_row(key)


func _kv_fetcher(key: String, user_scoped: bool) -> Callable:
	return func() -> Variant:
		var result = await _api.kv_get_kv(key, _user_id() if user_scoped else null)
		if result.error:
			if result.error.response_code == 404:
				return {}
			return null
		return _row_from_body(result)


func _on_channel_joined() -> void:
	# A fresh join means server-side subscription state is gone: everything
	# re-subscribes, and persisted rows load so listeners paint immediately.
	_channel_up = true
	_subscribed.clear()
	_subscribe_attempts.clear()
	_load_persisted_rows()
	for name in _registrations:
		_subscribe_entry(_registrations[name])


func _on_channel_disconnected() -> void:
	_channel_up = false
	_subscribed.clear()


func _subscribe_entry(entry: Dictionary) -> void:
	if not bool(entry.get("subscribe", true)):
		return
	var key := _entry_key(entry)
	if key.is_empty():
		return
	# A user-scoped key without a user yet (join raced the login) is skipped
	# here; the post-login refresh_keys() picks it up.
	if bool(entry.get("user_scoped", true)) and _user_id().is_empty():
		return
	if _subscribed.has(key) or _subscribe_in_flight.get(key, false):
		return
	entry["active_key"] = key
	_subscribe_in_flight[key] = true
	var result = await _api.kv_subscribe_ws(key, _entry_user_id(entry))
	_subscribe_in_flight.erase(key)
	if result.error:
		push_warning("GamendClient: kv subscribe rejected for '%s': %s" % [key, result.error.message])
		kv_subscribe_failed.emit(key, str(result.error.message))
		_maybe_retry_subscribe(entry, key, result.error.response_code)
		return
	_subscribed[key] = true
	_subscribe_attempts.erase(key)
	var row := _row_from_body(result)
	_store_row(key, row)
	kv_subscribed.emit(key, row)


## Transient subscribe failures (server hiccup, brief channel wobble) retry on
## a short backoff instead of leaving the key push-less until the next
## reconnect. Auth rejections are permanent for the session and never retry.
func _maybe_retry_subscribe(entry: Dictionary, key: String, response_code: int) -> void:
	if response_code in [HTTPClient.RESPONSE_UNAUTHORIZED, HTTPClient.RESPONSE_FORBIDDEN]:
		return
	var attempts := int(_subscribe_attempts.get(key, 0)) + 1
	_subscribe_attempts[key] = attempts
	if attempts > subscribe_retry_delays_sec.size():
		return
	await get_tree().create_timer(float(subscribe_retry_delays_sec[attempts - 1])).timeout
	# The world may have moved on while we slept: only retry if this key is
	# still wanted, still unsubscribed, and the channel is still up.
	if not _channel_up or _subscribed.has(key) or _subscribe_in_flight.get(key, false):
		return
	if _entry_key(entry) != key or str(entry.get("active_key", "")) != key:
		return
	_subscribe_entry(entry)


func _on_kv_push(payload: Dictionary) -> void:
	var key := str(payload.get("key", ""))
	if key.is_empty():
		return
	var data: Variant = payload.get("data", {})
	_store_row(key, (data as Dictionary) if data is Dictionary else {})


func _store_row(key: String, row: Dictionary) -> void:
	_rows[key] = row.duplicate(true)
	if _persisted_entry_for_key(key) != null:
		_persist_row(key, row)
	kv_row_changed.emit(key, get_row(key))


## The KV row out of a get_kv reply.
##
## The answer is `{data: KvEntry}` and the entry's own `data` is the stored
## row, the same fields the channel's `kv_updated` push carries. `response.data`
## is the DENORMALIZED model (GamendKvEntryResponse) — the generated api swaps
## it in before this runs — so requiring a Dictionary rejected every
## successful fetch and read a real row as "no row". A raw Dictionary is still
## what a hand-rolled or cached reply gives, and a server from before the
## entry shape answered `{data: row}` (or `{value: row}` earlier still), so
## every form is taken.
func _row_from_body(result) -> Dictionary:
	if result.response == null:
		return {}
	return _kv_row(result.response.data)


static func _kv_row(body: Variant) -> Dictionary:
	var entry: Variant = null
	if body is Dictionary:
		entry = (body as Dictionary).get("data", (body as Dictionary).get("value", {}))
	elif body != null and "data" in body:
		entry = body.data
	if entry is Dictionary:
		var fields := entry as Dictionary
		if fields.has("key") and fields.get("data") is Dictionary:
			return fields["data"]
		return fields
	if entry != null and "data" in entry:
		var row: Variant = entry.data
		return (row as Dictionary) if row is Dictionary else {}
	return {}


func _entry_key(entry: Dictionary) -> String:
	var source: Variant = entry.get("key_source", "")
	if source is Callable:
		return str((source as Callable).call())
	return str(source)


func _entry_user_id(entry: Dictionary) -> Variant:
	return _user_id() if bool(entry.get("user_scoped", true)) else null


func _user_id() -> String:
	if _user_id_provider.is_valid():
		return str(_user_id_provider.call())
	return ""


func _persisted_entry_for_key(key: String) -> Variant:
	for name in _registrations:
		var entry: Dictionary = _registrations[name]
		if bool(entry.get("persist", false)) and _entry_key(entry) == key:
			return entry
	return null


# --- disk persistence (opt-in per registration; one file, per-user sections) --


func _persist_row(key: String, row: Dictionary) -> void:
	if cache_file_path.is_empty():
		return
	var file := _ensure_cache_file()
	file.set_value(_cache_section(), key, {"row": row, "ts": int(Time.get_unix_time_from_system())})
	file.save(cache_file_path)


func _load_persisted_rows() -> void:
	if cache_file_path.is_empty():
		return
	var file := _ensure_cache_file()
	var section := _cache_section()
	if not file.has_section(section):
		return
	for name in _registrations:
		var entry: Dictionary = _registrations[name]
		if not bool(entry.get("persist", false)):
			continue
		var key := _entry_key(entry)
		# Live data always wins: only fill rows nothing has answered for yet.
		if key.is_empty() or _rows.has(key) or not file.has_section_key(section, key):
			continue
		var stored: Variant = file.get_value(section, key, {})
		if stored is Dictionary and (stored as Dictionary).get("row") is Dictionary:
			_rows[key] = ((stored as Dictionary)["row"] as Dictionary).duplicate(true)
			kv_row_changed.emit(key, get_row(key))


func _ensure_cache_file() -> ConfigFile:
	if _cache_file == null:
		_cache_file = ConfigFile.new()
		_cache_file.load(cache_file_path)
	return _cache_file


func _cache_section() -> String:
	var uid := _user_id()
	return uid if not uid.is_empty() else "global"


# --- hook RPCs + session snapshot -------------------------------------------


## Server-plugin name rpc_call/rpc_send target (e.g. "my_game_hook").
var plugin := ""
## key -> value writes currently in flight (write_deduped dedupe).
var _pending_writes: Dictionary = {}


## Hook call over HTTP, awaited. Returns
## {"ok": bool, "data": Variant, "error": String, "latency_ms": int} — the
## caller decides logging/toasts; errors also fire rpc_failed.
func rpc_call(fn: String, args: Array = []) -> Dictionary:
	var start_ms := Time.get_ticks_msec()
	var request := GamendCallHookRequest.new()
	request.plugin = plugin
	request.fn = fn
	request.args = args
	var result = await _api.hooks_call_hook(request)
	var latency := Time.get_ticks_msec() - start_ms
	if result.error:
		var message := str(result.error.message)
		rpc_failed.emit(fn, message)
		return {"ok": false, "data": null, "error": message, "latency_ms": latency}
	var data: Variant = null
	if result.response and result.response.data:
		data = strip_json_nulls(result.response.data.data)
	return {"ok": true, "data": data, "error": "", "latency_ms": latency}


## JSON null and absent are the same thing to GDScript callers: hook payloads
## are schemaless (GamendHookCallResponse.data), so a null that survives to a
## typed variable is a runtime error the type system cannot catch. Strip nulls
## recursively so `.get(key, default)` applies the default — the same
## null-equals-absent rule generate_godot.sh already enforces for typed model
## properties. Array elements are recursed into but never removed: dropping
## one would shift the positions callers index by.
static func strip_json_nulls(value: Variant) -> Variant:
	if value is Dictionary:
		var dict := {}
		for key: Variant in (value as Dictionary):
			var entry: Variant = (value as Dictionary)[key]
			if entry != null:
				dict[key] = strip_json_nulls(entry)
		return dict
	if value is Array:
		var list := []
		for entry: Variant in (value as Array):
			list.append(strip_json_nulls(entry))
		return list
	return value


## Fire-and-forget hook call over the WebSocket (no reply awaited).
func rpc_send(fn: String, args: Array = []) -> bool:
	return _api.hooks_call_hook_ws(plugin, fn, args)


## Collapse duplicate concurrent writes: when an identical (key, value) write
## is already in flight, skip instead of sending it again. Returns
## {"skipped": bool, "result": Variant} — result is the writer's return.
func write_deduped(key: String, value: Variant, writer: Callable) -> Dictionary:
	if _pending_writes.get(key) == value:
		return {"skipped": true, "result": null}
	_pending_writes[key] = value
	var result: Variant = await writer.call()
	if _pending_writes.get(key) == value:
		_pending_writes.erase(key)
	return {"skipped": false, "result": result}


## The current user's profile, fetched fresh and normalized to a Dictionary:
## {"ok": bool, "data": Dictionary, "error": String}.
func fetch_current_user() -> Dictionary:
	var result = await _api.users_get_current_user()
	if result.error:
		return {"ok": false, "data": {}, "error": str(result.error.message)}
	var user := user_to_dict(result.response)
	return {"ok": not user.is_empty(), "data": user, "error": ""}


## One lobby, fetched fresh and normalized (members folded in). Same shape as
## fetch_current_user.
func fetch_lobby(lobby_id: String) -> Dictionary:
	var result = await _api.lobbies_get_lobby(lobby_id)
	if result.error:
		return {"ok": false, "data": {}, "error": str(result.error.message)}
	var lobby := lobby_to_dict(result.response)
	return {"ok": not lobby.is_empty(), "data": lobby, "error": ""}


## Point the realtime lobby channel at `lobby_id` ("" leaves every lobby):
## stops the old channel, starts the new one, no-op when already there.
func sync_lobby_channel(lobby_id: String) -> void:
	if _api._lobby_id == lobby_id:
		return
	if _api.is_realtime_connected() and _api._lobby_id != "":
		_api.stop_listening_to_lobby()
	_api._lobby_id = lobby_id
	if _api.is_realtime_connected() and lobby_id != "":
		_api.listen_to_lobby()


## Model/response → plain Dictionary (generated models expose bzz_normalize).
static func user_to_dict(response) -> Dictionary:
	var payload = response.data if response is ApiApiResponseClient else response
	# Every answer is {data: ...}: a generated response model, or the raw dict.
	var user_data = payload
	if payload is Dictionary:
		user_data = payload.get("data", payload)
	elif payload != null and "data" in payload:
		user_data = payload.data
	if user_data is Dictionary:
		return (user_data as Dictionary).duplicate(true)
	if user_data != null and user_data.has_method("bzz_normalize"):
		return user_data.bzz_normalize()
	return {}


static func lobby_to_dict(response) -> Dictionary:
	if response == null:
		return {}
	var payload = response.data if response is ApiApiResponseClient else response
	var lobby_data = payload
	var raw_members: Array = []
	# {data: lobby}; get_lobby puts the members inside the lobby itself.
	if payload is GamendLobbyResponse:
		lobby_data = payload.data
		if lobby_data != null:
			raw_members = lobby_data.members
	elif payload is Dictionary:
		lobby_data = payload.get("data", payload)
		raw_members = (lobby_data as Dictionary).get("members", []) if lobby_data is Dictionary else []
	var lobby: Dictionary = {}
	if lobby_data is Dictionary:
		lobby = lobby_data.duplicate(true)
	elif lobby_data != null and lobby_data.has_method("bzz_normalize"):
		lobby = lobby_data.bzz_normalize()
	if lobby.is_empty():
		return {}
	var members: Array = []
	for member in raw_members:
		if member is Dictionary:
			members.append(member.duplicate(true))
		elif member != null and member.has_method("bzz_normalize"):
			members.append(member.bzz_normalize())
	if not members.is_empty():
		lobby["members"] = members
	return lobby


# --- network watchdog (opt-in) ----------------------------------------------
# Owns the connected/reconnecting/failed lifecycle around the api's socket and
# user channel: silent grace window, hard timeout, verified rejoin, retry.
# Everything user-facing leaves as signals; the game maps them to its own UI.


## `hooks` (all optional Callables): is_session_active, revalidate, retry_login
## — see _watch_hooks. Call once, after setup().
func enable_network_watch(hooks: Dictionary = {}) -> void:
	_watch_enabled = true
	_watch_hooks = hooks
	_api.socket_connected.connect(_on_watch_socket_connected)
	_api.socket_disconnected.connect(_on_watch_disconnected)
	_api.user_channel_joined.connect(_on_watch_channel_joined)
	_api.user_channel_disconnected.connect(_on_watch_disconnected)
	_api.network_request_failed.connect(func(message: String) -> void: fail_network("request", message))
	_api.network_request_succeeded.connect(_on_watch_request_succeeded)


func is_network_failed() -> bool:
	return _net_state == "failed"


func is_network_reconnecting() -> bool:
	return _net_state == "reconnecting"


## Enter reconnecting (no-op while already reconnecting or failed). The UI is
## told twice: network_reconnecting immediately, network_reconnecting_display
## only if still down after the grace window.
func start_network_reconnect(message := "") -> void:
	if _net_state != "connected":
		return
	_net_attempt_id += 1
	_net_state = "reconnecting"
	network_reconnecting.emit(message)
	_reveal_after_grace(_net_attempt_id, message)
	_fail_after_timeout(_net_attempt_id)


## Hard failure: state sticks until retry_network(), and realtime stops so a
## half-alive socket cannot keep mutating session state underneath the game.
func fail_network(kind: String, message := "") -> void:
	if not is_inside_tree():
		return
	_net_attempt_id += 1
	_net_state = "failed"
	_api.realtime_stop()
	network_failed.emit(kind, message)


## The failed-state popup's Retry: re-auth when the session is gone, otherwise
## restart realtime. Shows the reconnecting UI immediately (no grace — the
## player just pressed a button and wants feedback). Only meaningful from
## "failed": while connected nothing would re-fire the join that ends the
## reconnecting state, so a stray call would idle into a timeout failure.
func retry_network() -> void:
	if _net_state != "failed":
		return
	_net_attempt_id += 1
	var attempt_id := _net_attempt_id
	_net_state = "reconnecting"
	network_reconnecting.emit("")
	network_reconnecting_display.emit("")
	_fail_after_timeout(attempt_id)
	if not _api.is_authenticated():
		var retry_login: Callable = _watch_hooks.get("retry_login", Callable())
		var logged_in := false
		if retry_login.is_valid():
			logged_in = bool(await retry_login.call())
		if not logged_in:
			fail_network("retry")
		return
	var result = await _api.realtime_start()
	if result.error:
		fail_network("retry", str(result.error.message))
		return
	_api.listen_to_user()


func _on_watch_disconnected() -> void:
	if not is_inside_tree() or _net_state == "failed":
		return
	# Pre-login the socket is expected to bounce (auth handshakes); only a
	# live session reconnects.
	if not _session_active() or not _api.is_authenticated():
		return
	start_network_reconnect()


func _on_watch_socket_connected() -> void:
	# With a live session, a bare socket is not recovery — the user channel
	# must rejoin (and revalidate) first.
	if _session_active() and _api.is_authenticated():
		return
	_watch_recover()


func _on_watch_channel_joined() -> void:
	if _net_state == "failed":
		return
	if _net_state == "reconnecting":
		var revalidate: Callable = _watch_hooks.get("revalidate", Callable())
		if revalidate.is_valid() and not bool(await revalidate.call()):
			fail_network("revalidate")
			return
		_watch_recover()
		network_rejoined.emit()
		return
	_watch_recover()


func _on_watch_request_succeeded() -> void:
	if _net_state != "connected":
		return
	# An HTTP success while the socket is down must not mask the dead channel.
	if _api.is_authenticated() and not _api.is_realtime_connected():
		return
	_watch_recover()


func _watch_recover() -> void:
	if _net_state == "failed":
		return
	_net_attempt_id += 1
	if _net_state != "connected":
		_net_state = "connected"
	network_recovered.emit()


func _session_active() -> bool:
	var is_session_active: Callable = _watch_hooks.get("is_session_active", Callable())
	if is_session_active.is_valid():
		return bool(is_session_active.call())
	# Default policy: a session is live once auth reports online.
	return auth != null and auth.is_online()


func _reveal_after_grace(attempt_id: int, message: String) -> void:
	if reconnect_grace_sec > 0.0:
		await get_tree().create_timer(reconnect_grace_sec).timeout
	if attempt_id != _net_attempt_id or _net_state != "reconnecting":
		return
	network_reconnecting_display.emit(message)


func _fail_after_timeout(attempt_id: int) -> void:
	await get_tree().create_timer(reconnect_timeout_sec).timeout
	if attempt_id != _net_attempt_id or _net_state != "reconnecting":
		return
	fail_network("timeout")
