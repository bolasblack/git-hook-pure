#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
. "$script_dir/version.sh"

tagged=false
if [ "$#" -eq 2 ] && [ "$1" = --tagged ]; then
  tagged=true
  shift
elif [ "$#" -ne 1 ]; then
  printf '%s\n' 'Usage: scripts/check-release.sh [--tagged] v<semver>' >&2
  exit 2
fi

tag=$1
case "$tag" in v*) ;; *)
  printf '[release] invalid release tag: %s (expected v<semver>)\n' "$tag" >&2
  exit 2
esac
version=${tag#v}
if ! git_hook_pure_is_semver "$version"; then
  printf '[release] invalid semantic version in tag: %s\n' "$tag" >&2
  exit 2
fi

if ! package_version=$(git_hook_pure_read_package_version "$repo_root/package.json"); then
  printf '%s\n' '[release] package.json must contain exactly one valid semantic version' >&2
  exit 1
fi
if [ "$version" != "$package_version" ]; then
  printf '[release] tag version %s does not match package.json version %s\n' \
    "$version" "$package_version" >&2
  exit 1
fi

note=$repo_root/docs/releases/$tag.md
if [ ! -s "$note" ]; then
  printf '[release] missing or empty release note: %s\n' "$note" >&2
  exit 1
fi

if [ "$tagged" = true ]; then
  if ! tag_commit=$(git -C "$repo_root" rev-parse --verify "refs/tags/${tag}^{commit}" 2>&1); then
    printf '[release] unable to resolve release tag %s to a commit\n' "$tag" >&2
    [ -z "$tag_commit" ] || printf '%s\n' "$tag_commit" >&2
    exit 1
  fi
  if ! head_commit=$(git -C "$repo_root" rev-parse --verify HEAD 2>&1); then
    printf '%s\n' '[release] unable to resolve HEAD for release validation' >&2
    [ -z "$head_commit" ] || printf '%s\n' "$head_commit" >&2
    exit 1
  fi
  if [ "$head_commit" != "$tag_commit" ]; then
    printf '[release] HEAD does not match the exact commit for %s\n' "$tag" >&2
    exit 1
  fi
  printf '[release] version, release note, and exact tag commit verified for %s\n' "$tag"
  exit 0
fi

printf '[release] version and release note verified for %s\n' "$tag"
