test_packager_builds_a_deterministic_standalone_executable() {
  local build first second expected_version standalone repo hook trace
  build="$repo_root/scripts/build.sh"
  first="$suite_tmp/build one/git-hook-pure"
  second="$suite_tmp/build two/git-hook-pure"
  expected_version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo_root/package.json" | sed -n '1p')

  "$build" --output "$first" >/dev/null
  "$build" --output "$second" >/dev/null
  assert_files_equal "$first" "$second"
  [ -x "$first" ] || fail 'packaged artifact is not executable'
  [ "$(sed -n '1p' "$first")" = '#!/bin/sh' ] || fail 'packaged artifact has no POSIX shebang'
  ! grep -q '@GIT_HOOK_PURE_VERSION@' "$first" || fail 'artifact retained its version placeholder'
  [ "$("$first" --version)" = "$expected_version" ] || fail 'artifact embedded the wrong version'

  standalone="$suite_tmp/standalone"
  mkdir -p "$standalone"
  cp "$first" "$standalone/git-hook-pure"
  chmod +x "$standalone/git-hook-pure"
  (cd "$standalone" && ./git-hook-pure --help >/dev/null)

  repo=$(new_repo artifact-smoke)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$standalone/git-hook-pure" install >/dev/null
  )
  write_recording_handler "$repo/.githooks/pre-commit/artifact-handler"
  hook="$repo/.git/hooks/pre-commit"
  trace="$repo/artifact-trace"
  (cd "$repo" && TRACE="$trace" "$hook")
  printf '%s\n' artifact-handler >"$repo/artifact-expected"
  assert_files_equal "$repo/artifact-expected" "$trace"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$standalone/git-hook-pure" uninstall >/dev/null
  )
  [ ! -e "$hook" ] || fail 'standalone artifact did not uninstall its generated hook'
}

test_packager_uses_strict_semantic_versions() {
  local fixture output invalid status
  fixture="$suite_tmp/semantic-version-build"
  mkdir -p "$fixture/scripts" "$fixture/src" "$fixture/dist"
  cp "$repo_root/scripts/build.sh" "$fixture/scripts/build.sh"
  cp "$repo_root/scripts/version.sh" "$fixture/scripts/version.sh"
  chmod +x "$fixture/scripts/build.sh"
  printf '%s\n' main.sh >"$fixture/src/modules.list"
  cat >"$fixture/src/main.sh" <<'EOF'
version='@GIT_HOOK_PURE_VERSION@'
git_hook_pure_main() {
  case "${1:-}" in
    --version) printf '%s\n' "$version" ;;
  esac
}
EOF
  cat >"$fixture/package.json" <<'EOF'
{
  "version": "1.2.3-alpha.1+build.5"
}
EOF
  output="$fixture/dist/git-hook-pure"
  "$fixture/scripts/build.sh" >/dev/null
  [ "$("$output" --version)" = '1.2.3-alpha.1+build.5' ] || \
    fail 'packager rejected or changed a valid semantic version'

  for invalid in 01.2.3 1.02.3 1.2.03 1.2.3-01 1.2.3.foo 1.2; do
    printf '{\n  "version": "%s"\n}\n' "$invalid" >"$fixture/package.json"
    rm -f "$output"
    set +e
    "$fixture/scripts/build.sh" >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "packager accepted invalid semantic version: $invalid"
    [ ! -e "$output" ] || fail "invalid semantic version produced an artifact: $invalid"
  done
}

test_source_loader_reports_a_missing_module_manifest() {
  local fixture output status prefix manifest reported_root expected_root
  fixture="$suite_tmp/missing-source-manifest"
  mkdir -p "$fixture/scripts" "$fixture/src"
  cp "$repo_root/package.json" "$fixture/package.json"
  cp "$repo_root/scripts/run-source.sh" "$repo_root/scripts/version.sh" "$fixture/scripts/"
  cp "$repo_root/src/load.sh" "$fixture/src/load.sh"

  set +e
  output=$(sh "$fixture/scripts/run-source.sh" --version 2>&1)
  status=$?
  set -e

  [ "$status" -eq 1 ] || fail "missing source manifest exited with status $status: $output"
  prefix='[git-hook-pure] missing source module manifest: '
  case "$output" in
    "$prefix"*/src/modules.list) manifest=${output#"$prefix"} ;;
    *) fail "missing source manifest had the wrong diagnostic: $output" ;;
  esac
  reported_root=${manifest%/src/modules.list}
  reported_root=$(CDPATH= cd -- "$reported_root" && pwd -P) ||
    fail "missing source manifest reported an inaccessible path: $manifest"
  expected_root=$(CDPATH= cd -- "$fixture" && pwd -P)
  [ "$reported_root" = "$expected_root" ] ||
    fail "missing source manifest reported the wrong repository: $manifest"
}

test_top_level_test_runner_builds_from_the_repository_root() {
  local fixture outside stub_bin mise_cwd actual_root expected_root output status
  fixture="$suite_tmp/top-level-test-runner"
  outside="$suite_tmp/top-level-test-runner-caller"
  stub_bin="$suite_tmp/top-level-test-runner-bin"
  mise_cwd="$suite_tmp/top-level-test-runner-mise-cwd"
  mkdir -p "$fixture/tests/integration" "$fixture/scripts" "$fixture/dist" \
    "$outside" "$stub_bin"
  cp "$repo_root/tests/run.sh" "$fixture/tests/run.sh"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture/tests/integration/run.sh"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture/scripts/run-source.sh"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture/dist/git-hook-pure"
  chmod +x "$fixture/tests/integration/run.sh" "$fixture/scripts/run-source.sh" \
    "$fixture/dist/git-hook-pure"
  cat >"$stub_bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$PWD" >"$MISE_CWD_FILE"
[ "$#" -eq 2 ] && [ "$1" = run ] && [ "$2" = build ]
EOF
  chmod +x "$stub_bin/mise"

  set +e
  output=$(
    cd "$outside"
    PATH="$stub_bin:$PATH" MISE_CWD_FILE="$mise_cwd" bash "$fixture/tests/run.sh" 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "top-level test runner failed from another cwd: $output"
  actual_root=$(CDPATH= cd -- "$(cat "$mise_cwd")" && pwd -P)
  expected_root=$(CDPATH= cd -- "$fixture" && pwd -P)
  [ "$actual_root" = "$expected_root" ] ||
    fail "top-level test runner built outside the repository root: $(cat "$mise_cwd")"
}

test_packager_cleans_staging_when_mktemp_is_interrupted_before_returning() {
  local output previous shim_bin created_path_file real_mktemp status stage
  output="$suite_tmp/build assignment gap/git-hook-pure"
  previous="$suite_tmp/build assignment gap/previous"
  shim_bin="$suite_tmp/build assignment gap bin"
  created_path_file="$suite_tmp/build-assignment-gap.path"
  mkdir -p "$(dirname -- "$output")" "$shim_bin"
  printf '%s\n' old-build-before-assignment-gap >"$output"
  chmod 751 "$output"
  cp -p "$output" "$previous"

  real_mktemp=$(command -v mktemp)
  cat >"$shim_bin/mktemp" <<'EOF'
#!/bin/sh
created=$("$REAL_MKTEMP" "$@") || exit $?
printf '%s\n' "$created" >"$MKTEMP_CREATED_PATH"
kill -TERM "$PPID"
kill -TERM "$$"
EOF
  chmod +x "$shim_bin/mktemp"

  set +e
  (
    trap - TERM
    PATH="$shim_bin:$PATH" REAL_MKTEMP="$real_mktemp" \
      MKTEMP_CREATED_PATH="$created_path_file" \
      "$repo_root/scripts/build.sh" --output "$output"
  ) >/dev/null 2>&1
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'packager ignored an interrupted mktemp'
  [ -s "$created_path_file" ] || fail 'mktemp shim did not record its created staging path'
  assert_files_equal "$previous" "$output"
  [ "$(file_mode "$output")" = "$(file_mode "$previous")" ] ||
    fail 'interrupted mktemp changed the previous artifact mode'
  stage=$(cat "$created_path_file")
  [ ! -e "$stage" ] || fail 'interrupted mktemp left a staging file before path assignment'
}

test_packager_failure_preserves_the_previous_artifact() {
  local fake output expected status directory_output fifo_output signal signal_bin real_mv
  fake="$suite_tmp/failing-build"
  mkdir -p "$fake/scripts" "$fake/src" "$fake/dist"
  cp "$repo_root/scripts/build.sh" "$fake/scripts/build.sh"
  cp "$repo_root/scripts/version.sh" "$fake/scripts/version.sh"
  chmod +x "$fake/scripts/build.sh"
  printf '%s\n' main.sh >"$fake/src/modules.list"
  cat >"$fake/package.json" <<'EOF'
{
  "version": "9.8.7"
}
EOF
  cat >"$fake/src/main.sh" <<'EOF'
embedded='@GIT_HOOK_PURE_VERSION@'
git_hook_pure_main() {
  if
}
EOF
  output="$fake/dist/git-hook-pure"
  expected="$fake/expected"
  printf '%s\n' old-valid-artifact >"$output"
  cp "$output" "$expected"

  set +e
  "$fake/scripts/build.sh" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'packager accepted an invalid generated shell script'
  assert_files_equal "$expected" "$output"
  [ "$(find "$fake/dist" ! -path "$fake/dist" | wc -l | tr -d '[:space:]')" -eq 1 ] || \
    fail 'failed build left a staging file'

  directory_output="$suite_tmp/build-directory-output"
  mkdir -p "$directory_output"
  set +e
  "$repo_root/scripts/build.sh" --output "$directory_output" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'packager accepted a directory as its output file'
  [ -z "$(find "$directory_output" ! -path "$directory_output" -print | sed -n '1p')" ] || \
    fail 'directory output failure left a staged artifact'

  fifo_output="$suite_tmp/build-fifo-output"
  if mkfifo "$fifo_output" 2>/dev/null; then
    set +e
    "$repo_root/scripts/build.sh" --output "$fifo_output" >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'packager replaced a FIFO output target'
    [ -p "$fifo_output" ] || fail 'packager did not preserve the FIFO output target'
    [ -z "$(find "$suite_tmp" -maxdepth 1 -type f -name '.git-hook-pure-build.*' -print | sed -n '1p')" ] || \
      fail 'FIFO output failure left a staged artifact'
  else
    printf '%s\n' 'SKIP: filesystem FIFOs are unavailable for the packager test'
  fi

  signal_bin="$suite_tmp/build-signal-bin"
  mkdir -p "$signal_bin"
  real_mv=$(command -v mv)
  cat >"$signal_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
if [ "$#" -eq 3 ] && [ "$1" = -f ] && [ "$last" = "$TARGET_OUTPUT" ]; then
  kill -s "$TEST_SIGNAL" "$PPID"
  exit 0
fi
exec "$REAL_MV" "$@"
EOF
  chmod +x "$signal_bin/mv"
  for signal in QUIT PIPE; do
    output="$suite_tmp/build-signal-$signal/git-hook-pure"
    mkdir -p "$(dirname -- "$output")"
    printf '%s\n' "old-build-before-$signal" >"$output"
    cp -p "$output" "$output.expected"
    set +e
    (
      trap - "$signal"
      PATH="$signal_bin:$PATH" REAL_MV="$real_mv" TEST_SIGNAL="$signal" \
        TARGET_OUTPUT="$output" \
        "$repo_root/scripts/build.sh" --output "$output" >/dev/null 2>&1
    )
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "packager ignored SIG$signal while staging"
    assert_files_equal "$output.expected" "$output"
    [ -z "$(find "$(dirname -- "$output")" -maxdepth 1 -type f -name '.git-hook-pure-build.*' -print | sed -n '1p')" ] || \
      fail "packager SIG$signal left a staged artifact"
  done
}

run_build_integration_tests() {
  run_test test_packager_builds_a_deterministic_standalone_executable
  run_test test_packager_uses_strict_semantic_versions
  run_test test_source_loader_reports_a_missing_module_manifest
  run_test test_top_level_test_runner_builds_from_the_repository_root
  run_test test_packager_cleans_staging_when_mktemp_is_interrupted_before_returning
  run_test test_packager_failure_preserves_the_previous_artifact
}
