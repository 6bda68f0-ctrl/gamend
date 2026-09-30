"""Writing an SDK, or checking the written one is current.

An emitter answers the files it owns; the hand-written half of the SDK is a
template directory copied over the top, as `gamend_template` is for Godot.
`--check` compares both without touching anything, for CI.
"""

import shutil
import sys
from pathlib import Path

from model import ROOT


def template_files(template: Path) -> list[Path]:
    """The template's files. What a local build left inside it (`build/`) is not."""
    return [
        name
        for name in sorted(template.rglob("*"))
        if name.is_file() and not {"__pycache__", "build"} & set(name.relative_to(template).parts)
    ]


def write(out: Path, files: dict[str, str], template: Path | None, owns: bool = False) -> None:
    """Write `files` and the template into `out`. An emitter that `owns` the
    directory has what neither writes any more removed."""
    out.mkdir(parents=True, exist_ok=True)
    if owns:
        for name in leftovers(out, files, template):
            (out / name).unlink()
    for name, text in files.items():
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    if template is None:
        return
    for name in template_files(template):
        target = out / name.relative_to(template)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(name, target)


def check(
    out: Path, files: dict[str, str], template: Path | None, regenerate: str, owns: bool = False
) -> int:
    stale = [
        name
        for name, text in files.items()
        if not (out / name).is_file() or (out / name).read_text() != text
    ]
    if owns:
        stale += [f"{name} (no longer written)" for name in leftovers(out, files, template)]
    if template is not None:
        for name in template_files(template):
            target = out / name.relative_to(template)
            if not target.is_file() or target.read_bytes() != name.read_bytes():
                stale.append(str(name.relative_to(template)))
    if stale:
        print("stale: " + ", ".join(stale), file=sys.stderr)
        print(f"run {regenerate}", file=sys.stderr)
        return 1
    print(f"{relative(out)} is current")
    return 0


def leftovers(out: Path, files: dict[str, str], template: Path | None) -> list[str]:
    """What is in `out` that neither `files` nor the template writes. Hidden
    files are the platform's, not the SDK's."""
    if not out.is_dir():
        return []
    kept = set(files)
    if template is not None:
        kept |= {str(name.relative_to(template)) for name in template_files(template)}
    return sorted(
        str(path.relative_to(out))
        for path in out.rglob("*")
        if path.is_file()
        and not any(part.startswith(".") for part in path.relative_to(out).parts)
        and str(path.relative_to(out)) not in kept
    )


def relative(path: Path) -> Path:
    try:
        return path.resolve().relative_to(ROOT)
    except ValueError:
        return path
