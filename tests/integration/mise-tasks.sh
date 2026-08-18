test_mise_owns_repository_maintenance_tasks() {
  local actual expected fixture fixture_root trace coord output status

  [ -f "$repo_root/.mise.toml" ] || fail 'repository maintenance tasks have no mise config'

  actual=$(
    node -e '
      const scripts = require(process.argv[1]).scripts || {};
      for (const name of Object.keys(scripts).sort()) {
        process.stdout.write(`${name}=${scripts[name]}\n`);
      }
    ' "$repo_root/package.json"
  )
  expected='postinstall=sh ./scripts/postinstall.sh
prepack=mise run build'
  [ "$actual" = "$expected" ] ||
    fail "package.json owns repository maintenance tasks: $actual"

  fixture="$suite_tmp/mise task fixture"
  trace="$fixture/task.trace"
  coord="$fixture/task-coordination"
  mkdir -p "$fixture/mise-data" "$fixture/mise-state" "$fixture/scripts" "$fixture/tests" "$coord"
  cp "$repo_root/.mise.toml" "$fixture/.mise.toml"
  cat >"$fixture/scripts/build.sh" <<'EOF'
#!/bin/sh
printf 'build:%s\n' "$(pwd -P)" >>"$TRACE"
: >"$COORD/build"
EOF
  cat >"$fixture/tests/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  source|standalone)
    suite=$1
    other=standalone
    [ "$suite" = source ] || other=source
    : >"$COORD/$suite"
    for attempt in 1 2 3 4 5; do
      if [ -e "$COORD/$other" ]; then
        printf '%s:%s\n' "$suite" "$(pwd -P)" >>"$TRACE"
        : >"$COORD/$suite.done"
        exit 0
      fi
      sleep 1
    done
    printf 'timed out waiting for %s; coordination entries:\n' "$other" >&2
    ls -la "$COORD" >&2
    exit 81
    ;;
  support)
    [ -e "$COORD/source.done" ] && [ -e "$COORD/standalone.done" ] || exit 82
    printf 'support:%s\n' "$(pwd -P)" >>"$TRACE"
    ;;
  *) exit 83 ;;
esac
EOF
  chmod +x "$fixture/scripts/build.sh" "$fixture/tests/run.sh"

  MISE_DATA_DIR="$fixture/mise-data" MISE_STATE_DIR="$fixture/mise-state" MISE_OFFLINE=1 \
    mise trust --quiet --yes "$fixture/.mise.toml"
  MISE_DATA_DIR="$fixture/mise-data" MISE_STATE_DIR="$fixture/mise-state" MISE_OFFLINE=1 \
    MISE_TASK_RUN_AUTO_INSTALL=false TRACE="$trace" COORD="$coord" \
    mise -C "$fixture" run --quiet build
  fixture_root=$(CDPATH= cd -- "$fixture" && pwd -P)
  printf 'build:%s\n' "$fixture_root" >"$fixture/build.expected"
  assert_files_equal "$fixture/build.expected" "$trace"

  rm -f "$trace" "$coord/build" "$coord/source" "$coord/source.done" \
    "$coord/standalone" "$coord/standalone.done"
  set +e
  output=$(
    MISE_DATA_DIR="$fixture/mise-data" MISE_STATE_DIR="$fixture/mise-state" MISE_OFFLINE=1 \
      MISE_TASK_RUN_AUTO_INSTALL=false MISE_JOBS=2 TRACE="$trace" COORD="$coord" \
      mise -C "$fixture" run --quiet test 2>&1
  )
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "mise test task did not complete its parallel graph: $output"

  printf 'build:%s\nsource:%s\nstandalone:%s\nsupport:%s\n' \
    "$fixture_root" "$fixture_root" "$fixture_root" "$fixture_root" | LC_ALL=C sort \
    >"$fixture/test.expected"
  LC_ALL=C sort "$trace" >"$fixture/test.actual"
  assert_files_equal "$fixture/test.expected" "$fixture/test.actual"
  [ "$(tail -n 1 "$trace")" = "support:$fixture_root" ] ||
    fail 'mise ran support before both parallel core suites completed'
}

run_mise_task_integration_tests() {
  run_test test_mise_owns_repository_maintenance_tasks
}
