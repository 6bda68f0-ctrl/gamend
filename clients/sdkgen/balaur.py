"""The Balaur emitter: Rune over `gamend::rest`.

The Godot client goes through openapi-generator, which has no Rune target;
adding one is a Java generator plus a template set. Balaur mounts an addon's
files as modules, so `addons/gamend/lobbies.rn` is `gamend::lobbies` in every
script, and this writes one file per tag. A function is named for its
operation without the tag: `gamend::lobbies::create_lobby`. `events.rn` holds
one `pub mod` per channel of `clients/events.json`, each event without the
channel (`gamend::events::lobby::MEMBER_JOINED`), and the decoder.
`README.md` is the reference, by tag. Everything else in the addon is the
hand-written `clients/balaur_template/`, copied over the top.
"""

import json
import re

from model import CLIENTS, ROOT, Model, resolve, snake, wrap

TEMPLATE = CLIENTS / "balaur_template"
OUT = ROOT / "balaur_addons" / "addons" / "gamend"
REGENERATE = "clients/generate_balaur.sh"
# Every file in OUT is this emitter's or the template's, so a file neither
# writes any more (a tag renamed, the old `api.rn`) is removed.
OWNS_OUT = True

# A tag whose file would read as something else: `gamend::push` is the
# engine's own function.
FILE_NAMES = {"push": "push_tokens"}
# What a tag's file must not take: the template's files and the engine's own
# `gamend::` functions, which share the path.
TAKEN = {
    "auth", "client", "core", "events", "log_sink", "logs", "prefs",
    "presence", "version",
    "activity", "call_hook", "clear_activity", "close", "configure", "connect",
    "connection", "join", "leave", "login", "push", "register", "reply",
    "rest", "restore", "run_id", "session", "target",
}

BANNER = (
    "// Written by clients/sdkgen (balaur) from the OpenAPI document.\n"
    "// Do not edit; edit the generator or the spec and run\n"
    "// clients/generate_balaur.sh.\n"
)

# Rune's keywords, which a path parameter or a body field could otherwise
# collide with when it becomes an argument name.
RESERVED = {
    "as", "async", "await", "break", "const", "continue", "crate", "default",
    "else", "enum", "false", "fn", "for", "if", "impl", "in", "is", "let",
    "loop", "match", "mod", "move", "mut", "not", "pub", "return", "select",
    "self", "static", "struct", "super", "true", "typeof", "use", "while",
    "yield",
}


def safe(name: str) -> str:
    return f"{name}_" if name in RESERVED else name


def path_expression(op: dict, with_query: bool) -> str:
    """The path as a Rune string.

    A path with no holes and no query is a plain literal; anything else is a
    template, because the parameters and the query are interpolated into it.
    """
    filled = re.sub(r"\{([^}]+)\}", lambda m: "${" + safe(m.group(1)) + "}", op["path"])
    if not op["path_params"] and not with_query:
        return json.dumps(op["path"])
    tail = "${query}" if with_query else ""
    return f"`{filled}{tail}`"


def file_of(op: dict) -> str:
    """The file a tag's operations go in: `Admin – KV` is `admin_kv`."""
    tag = snake(op["tag"])
    return FILE_NAMES.get(tag, tag)


def short_name(op: dict, file: str) -> str:
    """The operation without what its file already says:
    `matchmaking_join` in `matchmaking` is `join`, and `admin_list_lobbies`
    in `admin_lobbies` is `list_lobbies`."""
    name = op["id"]
    prefixes = [f"{file}_"] + (["admin_"] if file.startswith("admin_") else [])
    for prefix in prefixes:
        if name.startswith(prefix) and len(name) > len(prefix):
            name = name[len(prefix):]
            break
    return safe(name)


def emit_function(model: Model, op: dict, file: str, name: str) -> str:
    """One operation as a Rune function over `gamend::rest`."""
    args = ["node"] + [safe(p) for p in op["path_params"]]
    required_body: list[str] = []
    if op["body"]:
        args.append("params")
        required_body = list(resolve(model.spec, op["body"]["schema"]).get("required", []))
    if op["query"]:
        args.append("options")
    # A mounted function takes at most five arguments; the document's worst
    # case is a node, two path parameters, a body and a query, exactly five.
    if len(args) > 5:
        raise SystemExit(f"{name}: {len(args)} arguments, more than a mount carries")

    called = json.dumps(f"gamend::{file}::{name}")
    out = wrap(op["summary"], 76, "///")
    out.append(f"/// `{op['method']} {op['path']}`")
    out.append(f"pub fn {name}({', '.join(args)}) {{")
    for field in required_body:
        out.append(f'    if !gamend::core::given(params, {json.dumps(field)}) {{')
        out.append(f'        return gamend::core::missing({called}, {json.dumps(field)});')
        out.append("    }")
    if op["query"]:
        for field in [q for q, needed in op["query"] if needed]:
            out.append(f'    if !gamend::core::given(options, {json.dumps(field)}) {{')
            out.append(f'        return gamend::core::missing({called}, {json.dumps(field)});')
            out.append("    }")
        allowed = ", ".join(json.dumps(q) for q, _ in op["query"])
        out.append(f"    let query = gamend::core::query(options, [{allowed}]);")
    path = path_expression(op, bool(op["query"]))
    call = f'gamend::rest(node, "{op["method"]}", {path}'
    call += ", params)" if op["body"] else ")"
    out.append(f"    {call}")
    out.append("}")
    return "\n".join(out)


def by_file(model: Model) -> dict[str, list[tuple[str, dict]]]:
    """Each file's operations, with the name each takes in it."""
    files: dict[str, list[tuple[str, dict]]] = {}
    for op in model.ops:
        file = file_of(op)
        if file in TAKEN:
            raise SystemExit(f"tag {op['tag']!r} would be gamend::{file}; add it to FILE_NAMES")
        name = short_name(op, file)
        taken = [n for n, _ in files.get(file, [])]
        if name in taken:
            raise SystemExit(f"gamend::{file}::{name} is wanted twice; {op['id']} is the second")
        files.setdefault(file, []).append((name, op))
    return files


def write_tags(model: Model) -> dict[str, str]:
    out = {}
    for file, ops in by_file(model).items():
        tag = ops[0][1]["tag"]
        chunks = [
            BANNER,
            f"//! {tag}: one function per operation, as `gamend::{file}::<name>`.\n"
            "//!\n"
            "//! A call takes the node its result should reach, then the path's own\n"
            "//! parameters, then `params` for the request body and `options` for the\n"
            "//! query where the operation has them. It answers the id `gamend::rest`\n"
            "//! answers, to await with `task::wait`.\n",
        ]
        chunks += [emit_function(model, op, file, name) for name, op in ops]
        out[f"{file}.rn"] = "\n\n".join(chunks) + "\n"
    return out


def write_events(model: Model) -> str:
    table = model.table
    lines = [
        BANNER,
        "//! The realtime events, one `pub mod` per channel, and the decoder that\n"
        "//! names a raw socket message: `gamend::events::lobby::MEMBER_JOINED` is\n"
        "//! what `decode` answers as `kind` for a lobby's `user_joined`.\n"
        "//!\n"
        "//! OpenAPI does not describe the socket, so this comes from\n"
        "//! `clients/events.json`, which the Godot client's dispatch seeded. An\n"
        "//! event the table does not name still arrives, as `message`.\n",
    ]
    channels: dict[str, set[str]] = {}
    for row in table:
        channels.setdefault(row["channel"], set()).add(row["signal"])
    for channel in sorted(channels):
        names: dict[str, str] = {}
        for signal in sorted(channels[channel]):
            name = signal.removeprefix(f"{channel}_").upper()
            if name in names:
                raise SystemExit(f"events::{channel}::{name} is both {names[name]} and {signal}")
            names[name] = signal
        body = "\n".join(f'    pub const {name} = "{signal}";' for name, signal in names.items())
        lines.append(
            f"/// What arrives on `{channel}` topics, as `decode` names it.\n"
            f"pub mod {channel} {{\n{body}\n}}"
        )
    rows = ",\n".join(
        f'    ["{row["channel"]}", "{row["event"]}", "{row["signal"]}"]' for row in table
    )
    lines.append(
        "/// Every row of the table: the channel a topic belongs to, the event the\n"
        "/// server sends, and what this client calls it.\n"
        f"pub fn table() {{\n    [\n{rows},\n    ]\n}}"
    )
    lines.append(
        '/// The channel a topic names: `lobby:12` is `lobby`, `lobbies` is itself.\n'
        "pub fn channel_of(topic) {\n"
        '    let parts = topic.split(":").collect::<Vec>();\n'
        "    parts[0]\n"
        "}"
    )
    lines.append(
        "/// A socket message as this client names it. The payload is carried\n"
        "/// through under `kind`; an event no row names comes back as `message`.\n"
        "pub fn decode(topic, event, payload) {\n"
        "    let channel = channel_of(topic);\n"
        "    let named = \"message\";\n"
        "    for row in table() {\n"
        "        if row[0] == channel && row[1] == event {\n"
        "            named = row[2];\n"
        "            break;\n"
        "        }\n"
        "    }\n"
        "    let out = #{};\n"
        "    if payload is Object {\n"
        "        for key in payload.keys() {\n"
        "            out[key] = payload[key];\n"
        "        }\n"
        "    }\n"
        '    out["kind"] = named;\n'
        '    out["topic"] = topic;\n'
        '    out["event"] = event;\n'
        "    out\n"
        "}"
    )
    return "\n\n".join(lines) + "\n"


def write_readme(model: Model) -> str:
    files = by_file(model)
    lines = [
        "# The Gamend SDK for Balaur",
        "",
        "Written by `clients/sdkgen` (balaur). Copy this directory into a",
        "project as `addons/gamend/`. Each file is a module every script",
        "reaches by path, beside the engine's own `gamend::login` and",
        "`gamend::rest`:",
        "",
        "```rune",
        'gamend::configure("https://gamend.org");',
        "let reply = task::wait(gamend::lobbies::quick_join(this.node, #{",
        '    "title": "duel", "max_users": 2,',
        "})).await;",
        "if e[\"kind\"] == gamend::events::lobby::MEMBER_JOINED { }",
        "```",
        "",
        f"{len(model.ops)} operations in {len(files)} modules, and "
        f"{len(model.signals())} realtime events.",
        "",
        "Beside the generated modules and `events.rn`, written by hand:",
        "",
        "| Module | For |",
        "| --- | --- |",
        "| `gamend::client` | `configure`, the socket, hooks and the key-value cache |",
        "| `gamend::auth` | Sign-in through a provider, and the kept session |",
        "| `gamend::presence` | The user cache |",
        "| `gamend::prefs` | The player's prefs on this device |",
        "| `gamend::logs` | This run's log, shipped in batches; put `log_sink.rn` on a node that lives as long as the game |",
        "| `gamend::core` | The query string, the required-field check and the reply helpers |",
        "| `editor/gamend.rn` | The Gamend dock in the Balaur editor |",
        "",
    ]
    for file in sorted(files):
        ops = files[file]
        lines += [
            f"## gamend::{file}",
            "",
            f"{ops[0][1]['tag']}.",
            "",
            "| Function | Call | What it does |",
            "| --- | --- | --- |",
        ]
        for name, op in ops:
            args = ["node"] + [p for p in op["path_params"]]
            if op["body"]:
                args.append("params")
            if op["query"]:
                args.append("options")
            summary = op["summary"].replace("|", "\\|")
            lines.append(f"| `{name}({', '.join(args)})` | `{op['method']} {op['path']}` | {summary} |")
        lines.append("")
    return "\n".join(lines)


def emit(model: Model) -> dict[str, str]:
    return {
        **write_tags(model),
        "events.rn": write_events(model),
        "README.md": write_readme(model),
    }


def summary(model: Model) -> str:
    return f"wrote {len(model.ops)} operations and {len(model.signals())} events"
