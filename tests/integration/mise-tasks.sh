test_mise_owns_repository_maintenance_tasks() {
  local actual expected fixture trace

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
  mkdir -p "$fixture/mise-data" "$fixture/mise-state" "$fixture/scripts" "$fixture/tests"
  cp "$repo_root/.mise.toml" "$fixture/.mise.toml"
  cat >"$fixture/scripts/build.sh" <<'EOF'
#!/bin/sh
printf 'build:%s\n' "$PWD" >>"$TRACE"
EOF
  cat >"$fixture/tests/run.sh" <<'EOF'
#!/usr/bin/env bash
printf 'test:%s\n' "$PWD" >>"$TRACE"
EOF
  chmod +x "$fixture/scripts/build.sh" "$fixture/tests/run.sh"

  MISE_DATA_DIR="$fixture/mise-data" MISE_STATE_DIR="$fixture/mise-state" MISE_OFFLINE=1 \
    mise trust --quiet --yes "$fixture/.mise.toml"
  MISE_DATA_DIR="$fixture/mise-data" MISE_STATE_DIR="$fixture/mise-state" MISE_OFFLINE=1 \
    MISE_TASK_RUN_AUTO_INSTALL=false TRACE="$trace" \
    mise -C "$fixture" run --quiet build
  MISE_DATA_DIR="$fixture/mise-data" MISE_STATE_DIR="$fixture/mise-state" MISE_OFFLINE=1 \
    MISE_TASK_RUN_AUTO_INSTALL=false TRACE="$trace" \
    mise -C "$fixture" run --quiet test

  printf 'build:%s\ntest:%s\n' "$fixture" "$fixture" >"$fixture/expected.trace"
  assert_files_equal "$fixture/expected.trace" "$trace"
}

run_mise_task_integration_tests() {
  run_test test_mise_owns_repository_maintenance_tasks
}
