#!/bin/sh

set -eu

git_hook_pure_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$git_hook_pure_root/scripts/version.sh"
. "$git_hook_pure_root/src/load.sh"
git_hook_pure_source_version=$(git_hook_pure_read_package_version "$git_hook_pure_root/package.json") || {
  printf '%s\n' '[git-hook-pure] package.json must contain exactly one valid semantic version' >&2
  exit 1
}
git_hook_pure_load "$git_hook_pure_root/src"
git_hook_pure_embedded_version=$git_hook_pure_source_version
unset -f git_hook_pure_is_semver git_hook_pure_read_package_version git_hook_pure_load
unset git_hook_pure_root git_hook_pure_source_version

git_hook_pure_main "$@"
