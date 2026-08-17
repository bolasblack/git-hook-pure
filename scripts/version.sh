#!/bin/sh

git_hook_pure_is_semver() {
  [ "$#" -eq 1 ] || return 2

  printf '%s\n' "$1" | grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
}

git_hook_pure_read_package_version() {
  [ "$#" -eq 1 ] || return 2

  local version_lines version extra_version
  version_lines=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$1") || return $?
  version=$(printf '%s\n' "$version_lines" | sed -n '1p')
  extra_version=$(printf '%s\n' "$version_lines" | sed -n '2p')
  [ -n "$version" ] && [ -z "$extra_version" ] &&
    git_hook_pure_is_semver "$version" || return 1
  printf '%s\n' "$version"
}
