#!/usr/bin/env python3
"""Verify that a release tag, version owner, and release note agree."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path


SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


class CheckFailure(Exception):
    """A release invariant failed."""


def fail(message: str) -> None:
    raise CheckFailure(message)


def parse_semver(value: str) -> str:
    if not SEMVER_RE.fullmatch(value):
        fail(f"invalid semantic version: {value}")
    return value


def semver_precedence(value: str) -> tuple[object, ...]:
    match = SEMVER_RE.fullmatch(value)
    if match is None:
        fail(f"invalid semantic version: {value}")
    major, minor, patch, prerelease, _build = match.groups()
    if prerelease is None:
        pre: tuple[object, ...] = (1,)
    else:
        identifiers: list[tuple[object, ...]] = []
        for identifier in prerelease.split("."):
            identifiers.append((0, int(identifier)) if identifier.isdigit() else (1, identifier))
        pre = (0, tuple(identifiers))
    return (int(major), int(minor), int(patch), pre)


def parse_version_content(path: Path, content: str) -> str:
    try:
        if path.suffix.lower() == ".json":
            data = json.loads(content)
            value = data.get("version") if isinstance(data, dict) else None
        elif path.suffix.lower() == ".toml":
            data = tomllib.loads(content)
            values = []
            if isinstance(data, dict) and "version" in data:
                values.append(data["version"])
            if isinstance(data, dict):
                for table in ("package", "project"):
                    section = data.get(table)
                    if isinstance(section, dict) and "version" in section:
                        values.append(section["version"])
            value = values[0] if len(values) == 1 else None
        else:
            lines = content.splitlines()
            value = lines[0].strip() if len(lines) == 1 else None
    except (json.JSONDecodeError, tomllib.TOMLDecodeError) as exc:
        fail(f"unable to read one version value from {path}: {exc.__class__.__name__}")

    if not isinstance(value, str) or not value:
        fail(f"{path} must contain exactly one string version value")
    try:
        return parse_semver(value)
    except CheckFailure:
        fail(f"{path} holds an invalid semantic version")


def read_version(path: Path) -> str:
    if not path.is_file():
        fail(f"version file not found: {path}")
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        fail(f"unable to read one version value from {path}: {exc.__class__.__name__}")
    return parse_version_content(path, content)


def read_version_at(path: Path, revision: str) -> str:
    if path.is_absolute() or ".." in path.parts:
        fail(f"version file must be repository-relative when --version-ref is used: {path}")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._~^/@{}+-]*", revision) is None:
        fail(f"invalid Git revision for --version-ref: {revision!r}")
    content = git("cat-file", "blob", f"{revision}:{path.as_posix()}", strip=False)
    return parse_version_content(path, content)


def git(*args: str, strip: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode != 0:
        fail(f"git {' '.join(args)} failed")
    return result.stdout.strip() if strip else result.stdout


def check_release(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog=".github/release/check.py",
        description=__doc__,
    )
    parser.add_argument("--tagged", action="store_true")
    parser.add_argument("--tag-prefix", default="v")
    parser.add_argument("--version-file", default="package.json")
    parser.add_argument("--notes-dir", default="docs/releases")
    parser.add_argument("--next-version")
    parser.add_argument("--previous-tag", action="store_true")
    parser.add_argument("--version-ref")
    parser.add_argument("tag", nargs="?")
    args = parser.parse_args(argv)

    owner = Path(args.version_file)
    if args.previous_tag:
        if args.tagged or args.next_version is not None or args.tag is not None:
            parser.error("--previous-tag cannot be combined with --tagged, --next-version, or a tag")
        current = read_version_at(owner, args.version_ref) if args.version_ref else read_version(owner)
        expected = f"{args.tag_prefix}{current}"
        candidates = []
        for tag_name in git("tag", "--list", f"{args.tag_prefix}*").splitlines():
            candidate = tag_name[len(args.tag_prefix) :]
            if SEMVER_RE.fullmatch(candidate):
                candidates.append(tag_name)
        if expected not in candidates:
            if candidates:
                fail(f"current version {current} has no matching release tag {expected}")
            return 0
        if git("cat-file", "-t", f"refs/tags/{expected}") != "tag":
            fail(f"previous release tag {expected} must be annotated")
        ancestor = subprocess.run(
            ["git", "merge-base", "--is-ancestor", f"refs/tags/{expected}^{{commit}}", "HEAD"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if ancestor.returncode != 0:
            fail(f"previous release tag {expected} is not an ancestor of HEAD")
        print(expected)
        return 0

    if args.next_version is not None:
        if args.tagged or args.tag is not None:
            parser.error("--next-version cannot be combined with --tagged or a tag")
        try:
            candidate = parse_semver(args.next_version)
        except CheckFailure:
            parser.error(f"invalid semantic version: {args.next_version}")
        current = read_version_at(owner, args.version_ref) if args.version_ref else read_version(owner)
        if semver_precedence(candidate) <= semver_precedence(current):
            fail(f"next version {candidate} must be greater than current version {current}")
        print(f"[release] next version {candidate} is greater than current version {current}")
        return 0

    if args.tag is None:
        parser.error("a tag is required unless --next-version is used")
    if args.version_ref is not None:
        parser.error("--version-ref is valid only with --previous-tag or --next-version")

    if not args.tag.startswith(args.tag_prefix):
        parser.error(f"tag {args.tag} does not start with prefix {args.tag_prefix}")
    version = args.tag[len(args.tag_prefix) :]
    try:
        parse_semver(version)
    except CheckFailure:
        parser.error(f"invalid semantic version in tag: {args.tag}")

    found = read_version(owner)
    if found != version:
        fail(f"tag version {version} does not match {owner} version {found}")

    note = Path(args.notes_dir) / f"{args.tag}.md"
    if not note.is_file() or note.stat().st_size == 0:
        fail(f"missing or empty release note: {note}")

    if args.tagged:
        tag_type = git("cat-file", "-t", f"refs/tags/{args.tag}")
        if tag_type != "tag":
            fail(f"release tag {args.tag} must be annotated")
        tag_commit = git("rev-parse", "--verify", f"refs/tags/{args.tag}^{{commit}}")
        head_commit = git("rev-parse", "--verify", "HEAD")
        if head_commit != tag_commit:
            fail(f"HEAD ({head_commit}) is not the commit tagged {args.tag} ({tag_commit})")
        print(f"[release] version, note, and exact tag commit verified for {args.tag}")
    else:
        print(f"[release] version and note verified for {args.tag}")
    return 0


def main(argv: list[str] | None = None) -> int:
    try:
        return check_release(list(sys.argv[1:] if argv is None else argv))
    except CheckFailure as exc:
        print(f"[release] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
