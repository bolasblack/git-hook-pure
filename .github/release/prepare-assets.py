#!/usr/bin/env python3
"""Create a verified manifest for direct-child release assets."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath


class AssetFailure(Exception):
    """A release-asset invariant failed."""


def fail(message: str) -> None:
    raise AssetFailure(message)


def has_control(value: str) -> bool:
    return any(not character.isprintable() for character in value)


def prepare_assets(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog=".github/release/prepare-assets.py",
        description=__doc__,
    )
    parser.add_argument("--stage-dir")
    parser.add_argument("asset_dir")
    parser.add_argument("patterns", nargs="+")
    args = parser.parse_args(argv)

    root_input = Path(args.asset_dir)
    lexical_root = PurePosixPath(args.asset_dir)
    raw_root_parts = args.asset_dir.split("/")
    if (
        lexical_root.is_absolute()
        or any(part in {"", ".", ".."} for part in raw_root_parts)
        or "\\" in args.asset_dir
        or has_control(args.asset_dir)
    ):
        fail(f"asset directory must be repository-relative without traversal: {root_input}")
    component = Path()
    for part in lexical_root.parts:
        component /= part
        if component.is_symlink():
            fail(f"asset directory must not traverse a symlink: {root_input}")
    try:
        root_stat = root_input.lstat()
    except OSError:
        fail(f"asset directory must be an ordinary directory: {root_input}")
    if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        fail(f"asset directory must be an ordinary directory: {root_input}")
    root = root_input.resolve(strict=True)

    selected: dict[str, Path] = {}
    for pattern in args.patterns:
        if (
            not pattern
            or pattern.startswith((".", "-"))
            or pattern in {".", ".."}
            or "/" in pattern
            or "\\" in pattern
            or has_control(pattern)
        ):
            fail(f"release asset pattern must name direct children only: {pattern!r}")
        matches = list(root.glob(pattern))
        usable = False
        for entry in matches:
            name = entry.name
            if name == "SHA256SUMS" or name.startswith(".release-assets-"):
                continue
            if name.startswith((".", "-")):
                fail(f"release asset names must be visible direct children: {name!r}")
            if has_control(name) or "\\" in name:
                fail(f"release asset has an unsupported name: {name!r}")
            entry_stat = entry.lstat()
            if not stat.S_ISREG(entry_stat.st_mode) or stat.S_ISLNK(entry_stat.st_mode):
                fail(f"release asset must be a regular non-symlink file: {name}")
            if entry.parent.resolve(strict=True) != root:
                fail(f"release asset escaped its root: {name}")
            selected[name] = entry
            usable = True
        if not usable:
            fail(f"no release asset matches: {pattern}")

    manifest_lines = []
    for name in sorted(selected):
        digest = hashlib.sha256()
        with selected[name].open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        manifest_lines.append(f"{digest.hexdigest()}  {name}\n")

    descriptor, temporary_name = tempfile.mkstemp(prefix=".release-assets-manifest.", dir=root)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.writelines(manifest_lines)
        temporary.chmod(0o644)
        for line in manifest_lines:
            expected, name = line.rstrip("\n").split("  ", 1)
            actual = hashlib.sha256(selected[name].read_bytes()).hexdigest()
            if actual != expected:
                fail(f"staged SHA-256 manifest did not verify: {name}")
        os.replace(temporary, root / "SHA256SUMS")
    finally:
        temporary.unlink(missing_ok=True)

    if args.stage_dir is not None:
        stage = Path(args.stage_dir)
        if stage.exists() or stage.is_symlink():
            fail(f"stage directory must not exist: {stage}")
        stage.mkdir(parents=True)
        try:
            for name in sorted(selected):
                shutil.copy2(selected[name], stage / name, follow_symlinks=False)
            shutil.copy2(root / "SHA256SUMS", stage / "SHA256SUMS", follow_symlinks=False)
            for line in manifest_lines:
                expected, name = line.rstrip("\n").split("  ", 1)
                actual = hashlib.sha256((stage / name).read_bytes()).hexdigest()
                if actual != expected:
                    fail(f"staged release asset did not verify: {name}")
        except BaseException:
            shutil.rmtree(stage)
            raise

    print(f"[release-assets] SHA256SUMS covers {len(selected)} asset(s) in {args.asset_dir}:")
    for name in sorted(selected):
        print(f"  {name}")
    return 0


def main(argv: list[str] | None = None) -> int:
    try:
        return prepare_assets(list(sys.argv[1:] if argv is None else argv))
    except AssetFailure as exc:
        print(f"[release-assets] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
