#!/usr/bin/env bash

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
integration_suite=$repo_root/tests/integration/run.sh
source_cli=$repo_root/scripts/run-source.sh
standalone_cli=$repo_root/dist/git-hook-pure

printf 'SUITE integration: source loader\n'
GIT_HOOK_PURE_UNDER_TEST="$source_cli" bash "$integration_suite" core

(cd "$repo_root" && mise run build)
tested_standalone_oid=$(git hash-object --no-filters "$standalone_cli")

printf 'SUITE integration: standalone artifact\n'
GIT_HOOK_PURE_UNDER_TEST="$standalone_cli" bash "$integration_suite" core

printf 'SUITE integration: distribution and release support\n'
bash "$integration_suite" support
if [ "$(git hash-object --no-filters "$standalone_cli")" != "$tested_standalone_oid" ]; then
  printf '%s\n' 'FAIL: standalone artifact changed during integration testing' >&2
  exit 1
fi

printf 'PASS: all tests\n'
