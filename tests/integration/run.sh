#!/usr/bin/env bash

set -euo pipefail

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

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

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
  printf 'TEST %s\n' "$name"
  "$name"
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
