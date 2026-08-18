#!/usr/bin/env bash

set -Eeuo pipefail

mode=${1:-all}
if [ "$#" -gt 1 ]; then
  printf '%s\n' 'Usage: tests/integration/run.sh [all|core|support]' >&2
  exit 2
fi
case "$mode" in
  all|core|support) ;;
  *)
    printf '%s\n' 'Usage: tests/integration/run.sh [all|core|support]' >&2
    exit 2
    ;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
git_hook_pure=${GIT_HOOK_PURE_UNDER_TEST:-"$repo_root/scripts/run-source.sh"}
package_version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo_root/package.json" | sed -n '1p')
package_tag=v$package_version
suite_tmp=$(mktemp -d "${TMPDIR:-/tmp}/git-hook-pure-tests.XXXXXX")
trap 'rm -rf "$suite_tmp"' EXIT

current_test=
failure_reported=false

emit_failure() {
  local message=$*
  local annotation

  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    annotation=${message//'%'/'%25'}
    annotation=${annotation//$'\r'/'%0D'}
    annotation=${annotation//$'\n'/'%0A'}
    printf '::error title=git-hook-pure integration test::%s\n' "$annotation" >&2
  fi
  printf 'FAIL: %s\n' "$message" >&2
}

fail() {
  failure_reported=true
  emit_failure "$*"
  return 1
}

report_unexpected_test_failure() {
  local status=$1
  local command_text=$2

  case $- in
    *e*) ;;
    *) return "$status" ;;
  esac
  [ -n "$current_test" ] || return "$status"
  [ "$failure_reported" = false ] || return "$status"

  failure_reported=true
  emit_failure \
    "unexpected command failure in $current_test (status $status): $command_text"
  return "$status"
}

trap 'report_unexpected_test_failure "$?" "$BASH_COMMAND"' ERR

[ -n "$package_version" ] || fail 'package.json has no testable version'

assert_files_equal() {
  local expected=$1
  local actual=$2

  if ! cmp -s "$expected" "$actual"; then
    diff -u "$expected" "$actual" >&2 || true
    fail "$actual did not match $expected"
  fi
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

path_in_shell_coordinates() {
  local path=$1

  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$path"
  else
    printf '%s\n' "$path"
  fi
}

path_for_path_env() {
  path_in_shell_coordinates "$1"
}

create_test_symlink() {
  local target=$1
  local link=$2

  # Git Bash may copy the target when native symbolic links are unavailable.
  if ln -s "$target" "$link" 2>/dev/null && [ -L "$link" ]; then
    return 0
  fi
  rm -rf -- "$link"

  if command -v cygpath >/dev/null 2>&1 &&
    MSYS=winsymlinks:nativestrict ln -s "$target" "$link" 2>/dev/null &&
    [ -L "$link" ]; then
    return 0
  fi
  rm -rf -- "$link"
  return 1
}

new_repo() {
  local name=$1
  local path="$suite_tmp/$name"

  mkdir -p "$path/home"
  git -C "$path" init -q
  git -C "$path" config user.name 'Git Hook Pure Tests'
  git -C "$path" config user.email 'git-hook-pure@example.invalid'
  path=$(CDPATH= cd -- "$path" && pwd -P)
  printf '%s\n' "$path"
}

write_recording_handler() {
  local path=$1

  mkdir -p "$(dirname -- "$path")"
  cat >"$path" <<'EOF'
#!/bin/sh
printf '%s' "$(basename "$0")" >>"$TRACE"
for argument do
  printf '<%s>' "$argument" >>"$TRACE"
done
printf '\n' >>"$TRACE"
EOF
  chmod +x "$path"
}

run_test() {
  local name=$1

  current_test=$name
  failure_reported=false
  printf 'TEST %s\n' "$name"
  "$name"
  current_test=
}

. "$repo_root/tests/integration/git-hook-pure.sh"
. "$repo_root/tests/integration/build.sh"
. "$repo_root/tests/integration/npm-package.sh"
. "$repo_root/tests/integration/install-standalone.sh"
. "$repo_root/tests/integration/check-release.sh"
. "$repo_root/tests/integration/prepare-release-assets.sh"
. "$repo_root/tests/integration/release-workflows.sh"
. "$repo_root/tests/integration/mise-tasks.sh"

if [ "$mode" != support ]; then
  run_git_hook_pure_integration_tests
fi
if [ "$mode" != core ]; then
  run_build_integration_tests
  run_npm_package_integration_tests
  run_install_standalone_integration_tests
  run_check_release_integration_tests
  run_prepare_release_assets_integration_tests
  run_release_workflow_contract_tests
  run_mise_task_integration_tests
fi
printf 'PASS: integration tests\n'
