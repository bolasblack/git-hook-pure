#!/usr/bin/env bash

set -euo pipefail

mode=${1:-all}
if [ "$#" -gt 1 ]; then
  printf '%s\n' 'Usage: tests/run.sh [all|source|standalone|support]' >&2
  exit 2
fi
case "$mode" in
  all|source|standalone|support) ;;
  *)
    printf '%s\n' 'Usage: tests/run.sh [all|source|standalone|support]' >&2
    exit 2
    ;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
integration_suite=$repo_root/tests/integration/run.sh
source_cli=$repo_root/scripts/run-source.sh
standalone_cli=$repo_root/dist/git-hook-pure

case "$mode" in
  all|source)
    printf 'SUITE integration: source loader\n'
    GIT_HOOK_PURE_UNDER_TEST="$source_cli" bash "$integration_suite" core
    ;;
esac

if [ "$mode" = all ]; then
  (cd "$repo_root" && mise run build)
fi

case "$mode" in
  all|standalone)
    tested_standalone_oid=$(git hash-object --no-filters "$standalone_cli")
    printf 'SUITE integration: standalone artifact\n'
    GIT_HOOK_PURE_UNDER_TEST="$standalone_cli" bash "$integration_suite" core
    if [ "$(git hash-object --no-filters "$standalone_cli")" != "$tested_standalone_oid" ]; then
      printf '%s\n' 'FAIL: standalone artifact changed during core integration testing' >&2
      exit 1
    fi
    ;;
esac

case "$mode" in
  all|support)
    tested_standalone_oid=$(git hash-object --no-filters "$standalone_cli")
    printf 'SUITE integration: distribution and release support\n'
    bash "$integration_suite" support
    if [ "$(git hash-object --no-filters "$standalone_cli")" != "$tested_standalone_oid" ]; then
      printf '%s\n' 'FAIL: standalone artifact changed during support integration testing' >&2
      exit 1
    fi
    ;;
esac

printf 'PASS: %s tests\n' "$mode"
