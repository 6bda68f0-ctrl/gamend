#!/usr/bin/env python3
"""Rename a Godot game's references to generated Gamend SDK classes.

The Godot addon's model classes change names when the OpenAPI document names
a schema (`ListFriends200ResponseDataInner` becomes `GamendFriend`) and when
the generator adds the `Gamend` prefix (`CreateLobbyRequest` becomes
`GamendCreateLobbyRequest`). A game that names those classes in its own
scripts has to follow.

The mapping is derived, not listed. Both addons are read: the one the game
vendors now and the newly generated one. Each operation's response class is
paired with its counterpart in the new addon, then each nested property's
class with the one at the same property, recursively. Pairing by position
is what makes it exact: `ListFriends200Response`, `ListLobbies200Response`
and a dozen others are all `{data, meta}`, so matching by shape would guess.
Request bodies pair the same way, through each operation's body parameter.
When the old generator merged identical bodies, one old class maps to several
new ones (`OpenLobbyReadyCheckRequest` served both ready-check operations); each
use is then resolved at its call site: `var r := X.new()` passed to
`gamend_api.fn(r)`, where `fn` reaches an operation through `GamendApi.gd`. A
class nothing else reaches maps to its prefixed twin.

    clients/godot_migrate.py OLD_ADDON NEW_ADDON GAME_ROOT           # report
    clients/godot_migrate.py OLD_ADDON NEW_ADDON GAME_ROOT --write   # rewrite

OLD_ADDON is the game's vendored copy (`<game>/addons/gamend`), NEW_ADDON the
regenerated one (`godot_addons/addons/gamend`). Only scripts outside
`GAME_ROOT/addons/` are rewritten; copy the new addon over the old one in the
same change. Exits 1 when a referenced class has no mapping.
"""

import argparse
import re
import sys
from pathlib import Path

FUNC = re.compile(r"^func (\w+)\(", re.M)
RESPONSE = re.compile(r"bzz_response\.data = (\w+)\.bzz_denormalize_(?:single|multiple)\(")
BODY = re.compile(r"# \w+: ([A-Z]\w*)")
CALL_API = re.compile(r'_call_api\([^,]+, "(\w+)"')
NESTED = re.compile(r'me\.(\w+) = (\w+)\.bzz_denormalize_(?:single|multiple)\(from_dict\["\w+"\]\)')
IDENT = re.compile(r"(?<![A-Za-z0-9_])[A-Z][A-Za-z0-9_]*\b")


def models(addon: Path) -> set[str]:
    return {p.stem for p in (addon / "models").glob("*.gd")}


def responses(addon: Path) -> dict[str, str]:
    """Operation name to the class its success response denormalizes into."""
    out: dict[str, str] = {}
    for api in (addon / "apis").glob("*.gd"):
        text = api.read_text()
        starts = [(m.start(), m.group(1)) for m in FUNC.finditer(text)]
        for i, (start, name) in enumerate(starts):
            end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
            found = RESPONSE.search(text, start, end)
            if found and not name.endswith("_threaded"):
                out[name] = found.group(1)
    return out


def functions(text: str) -> list[tuple[str, str]]:
    """Each top-level function's name and text."""
    starts = [(m.start(), m.group(1)) for m in FUNC.finditer(text)]
    return [
        (name, text[start : starts[i + 1][0] if i + 1 < len(starts) else len(text)])
        for i, (start, name) in enumerate(starts)
    ]


def bodies(addon: Path) -> dict[str, str]:
    """Operation name to the class of its request body."""
    known = models(addon)
    out: dict[str, str] = {}
    for api in (addon / "apis").glob("*.gd"):
        for name, block in functions(api.read_text()):
            header = block.split("on_success", 1)[0]
            found = [t for t in BODY.findall(header) if t in known]
            if found and not name.endswith("_threaded"):
                out[name] = found[-1]
    return out


def facade_operations(addon: Path) -> dict[str, str]:
    """GamendApi.gd function to the operation it calls."""
    facade = addon / "GamendApi.gd"
    if not facade.is_file():
        return {}
    out: dict[str, str] = {}
    for name, block in functions(facade.read_text()):
        found = CALL_API.search(block)
        if found:
            out[name] = found.group(1)
    return out


def nested(addon: Path) -> dict[str, dict[str, str]]:
    """Model to {property: class of that property}."""
    return {
        p.stem: dict(NESTED.findall(p.read_text())) for p in (addon / "models").glob("*.gd")
    }


def mapping(old_addon: Path, new_addon: Path) -> tuple[dict[str, str], dict[str, set[str]]]:
    old_nested, new_nested = nested(old_addon), nested(new_addon)
    new_models = models(new_addon)
    pairs: dict[str, set[str]] = {}

    def pair(old: str, new: str) -> None:
        seen = pairs.setdefault(old, set())
        if new in seen:
            return
        seen.add(new)
        for prop, old_child in old_nested.get(old, {}).items():
            new_child = new_nested.get(new, {}).get(prop)
            if new_child:
                pair(old_child, new_child)

    new_responses = responses(new_addon)
    for operation, old in responses(old_addon).items():
        if operation in new_responses:
            pair(old, new_responses[operation])

    new_bodies = bodies(new_addon)
    for operation, old in bodies(old_addon).items():
        if operation in new_bodies:
            pair(old, new_bodies[operation])

    for old in models(old_addon):
        twin = "Gamend" + old
        if old not in pairs and twin in new_models:
            pairs[old] = {twin}

    # A class the old generator deduplicated can land on two named schemas
    # (one `{data, meta}` class served friends and quests alike). Those are
    # reported rather than guessed.
    resolved = {old: next(iter(new)) for old, new in pairs.items() if len(new) == 1}
    ambiguous = {old: new for old, new in pairs.items() if len(new) > 1}
    return resolved, ambiguous


def resolve_sites(text: str, name: str, choices: set[str], by_function: dict[str, str], by_operation: dict[str, str]) -> tuple[str, int]:
    """Rewrite each `var v := NAME.new()` whose `v` is passed to a GamendApi
    function, to that function's own body class. Returns the text and how many
    uses of NAME are left unresolved."""
    site = re.compile(r"var (\w+)(\s*:?=\s*|\s*:\s*)" + name + r"\b([^\n]*)")
    out, pos = [], 0
    for m in site.finditer(text):
        call = re.search(r"\.(\w+)\([^)\n]*\b" + m.group(1) + r"\b", text[m.end():])
        target = by_operation.get(by_function.get(call.group(1), "")) if call else None
        if target in choices:
            out.append(text[pos : m.start()])
            out.append(m.group(0).replace(name, target))
            pos = m.end()
    out.append(text[pos:])
    rewritten = "".join(out)
    return rewritten, len(re.findall(r"\b" + name + r"\b", rewritten))


def game_scripts(root: Path) -> list[Path]:
    return [
        p
        for p in root.rglob("*.gd")
        if "addons" not in p.relative_to(root).parts and ".godot" not in p.relative_to(root).parts
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("old_addon", type=Path)
    parser.add_argument("new_addon", type=Path)
    parser.add_argument("game_root", type=Path)
    parser.add_argument("--write", action="store_true", help="rewrite the game's scripts")
    args = parser.parse_args()

    resolved, ambiguous = mapping(args.old_addon, args.new_addon)
    old_models = models(args.old_addon)
    by_function = facade_operations(args.new_addon)
    by_operation = bodies(args.new_addon)

    used: dict[str, int] = {}
    unmapped: dict[str, list[str]] = {}
    for script in game_scripts(args.game_root):
        text = script.read_text()
        for name in set(IDENT.findall(text)):
            if name not in old_models:
                continue
            used[name] = used.get(name, 0) + text.count(name)
            if name in resolved:
                continue
            left = resolve_sites(text, name, ambiguous.get(name, set()), by_function, by_operation)[1]
            if left:
                unmapped.setdefault(name, []).append(str(script.relative_to(args.game_root)))

    for name in sorted(used):
        target = resolved.get(name) or ("per call site: " + " | ".join(sorted(ambiguous[name])) if name in ambiguous else "?")
        print(f"{name:55s} -> {target}")

    if args.write:
        changed = 0
        for script in game_scripts(args.game_root):
            text = script.read_text()
            out = text
            for name in ambiguous:
                if name in used:
                    out = resolve_sites(out, name, ambiguous[name], by_function, by_operation)[0]
            out = IDENT.sub(lambda m: resolved.get(m.group(0), m.group(0)) if m.group(0) in used else m.group(0), out)
            if out != text:
                script.write_text(out)
                changed += 1
        print(f"rewrote {changed} scripts")

    for name, files in sorted(unmapped.items()):
        choices = " | ".join(sorted(ambiguous.get(name, []))) or "no counterpart"
        print(f"unmapped: {name} ({choices}) in {', '.join(sorted(set(files)))}", file=sys.stderr)
    return 1 if unmapped else 0


if __name__ == "__main__":
    raise SystemExit(main())
