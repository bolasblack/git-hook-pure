ensure_npm_package_tarball() {
  local native_tarball

  [ -z "${npm_package_tarball:-}" ] || return 0

  npm_package_pack_dir="$suite_tmp/npm-pack"
  mkdir -p "$npm_package_pack_dir"
  npm_package_tarball=$(
    cd "$repo_root"
    npm --cache "$suite_tmp/npm-cache" pack --silent \
      --pack-destination "$npm_package_pack_dir" | tail -n 1
  )
  npm_package_tarball="$npm_package_pack_dir/$npm_package_tarball"
  [ -f "$npm_package_tarball" ] || fail 'npm pack did not produce a tarball'
  if command -v cygpath >/dev/null 2>&1; then
    native_tarball=$(cygpath -m "$npm_package_tarball")
  else
    native_tarball=$npm_package_tarball
  fi
  npm_package_file_spec=git-hook-pure@file:$native_tarball
}

test_npm_package_automatically_installs_hooks_and_reports_controls() {
  local tarball packed_readme plain repo bin output status actual_files expected_files extracted help_output help_argument
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  if tar -xOf "$tarball" package/README.md | grep -Eq '\]\((\./)?docs/'; then
    fail 'packed README links to documentation that is absent from the package'
  fi
  packed_readme="$npm_package_pack_dir/README.md"
  tar -xOf "$tarball" package/README.md >"$packed_readme"
  grep -Fq \
    'https://github.com/bolasblack/git-hook-pure/blob/develop/docs/releasing.md' \
    "$packed_readme" || fail 'packed README release guide does not target the default branch'
  actual_files="$npm_package_pack_dir/files.actual"
  expected_files="$npm_package_pack_dir/files.expected"
  tar -tf "$tarball" | LC_ALL=C sort >"$actual_files"
  printf '%s\n' \
    package/LICENSE \
    package/README.md \
    package/dist/git-hook-pure \
    package/install-standalone.sh \
    package/package.json \
    package/scripts/npm-cli.sh \
    package/scripts/postinstall.sh >"$expected_files"
  assert_files_equal "$expected_files" "$actual_files"
  extracted="$npm_package_pack_dir/extracted"
  mkdir -p "$extracted"
  tar -xf "$tarball" -C "$extracted"
  [ -x "$extracted/package/install-standalone.sh" ] ||
    fail 'packed standalone installer is not executable'
  [ -x "$extracted/package/scripts/npm-cli.sh" ] ||
    fail 'packed npm CLI adapter is not executable'
  [ "$(sed -n '1p' "$extracted/package/scripts/npm-cli.sh")" = '#!/usr/bin/env sh' ] ||
    fail 'packed npm CLI shebang cannot be resolved by the Windows npm shim'
  [ -x "$extracted/package/scripts/postinstall.sh" ] ||
    fail 'packed npm postinstall adapter is not executable'

  plain="$suite_tmp/npm-plain"
  mkdir -p "$plain/home"
  printf '%s\n' '{"name":"plain-consumer","private":true}' >"$plain/package.json"
  HOME="$plain/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    npm --cache "$suite_tmp/npm-cache" --prefix "$plain" install \
    --no-audit --no-fund "$tarball" >/dev/null
  [ ! -e "$plain/.git" ] || fail 'plain npm consumer unexpectedly became a Git repository'
  bin="$plain/node_modules/.bin/git-hook-pure"
  [ -x "$bin" ] || fail 'packed npm command is not executable'
  "$bin" --version >/dev/null
  for help_argument in '' help -h --help; do
    if [ -n "$help_argument" ]; then
      help_output=$("$bin" "$help_argument")
    else
      help_output=$("$bin")
    fi
    case "$help_output" in *'install-standalone'*) ;;
      *) fail "npm command help does not expose standalone vendoring: ${help_argument:-no argument}" ;;
    esac
  done
  set +e
  "$bin" --help extra >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail 'npm command help accepted trailing arguments'
  set +e
  "$bin" install-standalone -h extra >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail 'npm standalone help accepted trailing arguments'

  repo=$(new_repo npm-git-consumer)
  printf '%s\n' '{"name":"git-consumer","private":true}' >"$repo/package.json"
  set +e
  output=$(
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm --cache "$suite_tmp/npm-cache" --prefix "$repo" install \
      --no-audit --no-fund --foreground-scripts "$tarball" 2>&1
  )
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "npm package install failed: $output"
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" || \
    fail 'npm package did not install hooks automatically'
  case "$output" in *'npx git-hook-pure uninstall'*) ;;
    *) fail 'successful npm setup did not explain how to uninstall hooks' ;;
  esac
  case "$output" in *'GIT_HOOK_PURE_SKIP_INSTALL=1'*) ;;
    *) fail 'successful npm setup did not explain how to skip automatic installation' ;;
  esac
}

test_npm_cli_resolves_windows_script_coordinates() {
  local tarball extracted caller fake_bin windows_cli output status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  extracted="$suite_tmp/npm-windows-script-coordinate"
  caller="$suite_tmp/npm-windows-script-caller"
  fake_bin="$suite_tmp/npm-windows-script-bin"
  mkdir -p "$extracted" "$caller" "$fake_bin"
  tar -xf "$tarball" -C "$extracted"
  windows_cli='C:\package\scripts\npm-cli.sh'

  cat >"$fake_bin/cygpath" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] || exit 64
[ "$1" = -u ] || exit 65
[ "$2" = "$WINDOWS_CLI_PATH" ] || exit 66
printf '%s\n' "$POSIX_CLI_PATH"
EOF
  chmod +x "$fake_bin/cygpath"

  set +e
  output=$(
    cd "$caller"
    WINDOWS_CLI_PATH="$windows_cli" \
      POSIX_CLI_PATH="$extracted/package/scripts/npm-cli.sh" \
      PATH="$fake_bin:$PATH" \
      sh -c 'source_file=$1; shift; . "$source_file"' \
      "$windows_cli" "$extracted/package/scripts/npm-cli.sh" --version 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] ||
    fail "npm CLI did not resolve its Windows script path: $output"
  [ "$output" = "$package_version" ] ||
    fail "npm CLI resolved the wrong package from its Windows script path: $output"
}

test_npm_auto_install_failure_is_nonfatal_and_actionable() {
  local tarball repo output status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  repo=$(new_repo npm-auto-install-failure)
  printf '%s\n' '{"name":"failing-consumer","private":true}' >"$repo/package.json"
  git -C "$repo" config core.hooksPath custom-hooks

  set +e
  output=$(
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm --cache "$suite_tmp/npm-cache" --prefix "$repo" install \
      --no-audit --no-fund --foreground-scripts "$tarball" 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "failed automatic hook setup aborted npm install: $output"
  [ -x "$repo/node_modules/.bin/git-hook-pure" ] ||
    fail 'npm package was unavailable after automatic hook setup failed'
  [ ! -e "$repo/.githooks" ] || fail 'failed automatic setup created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'failed automatic setup mutated default Git hooks'
  fi
  case "$output" in *'automatic Git hook installation did not take effect'*) ;;
    *) fail 'failed automatic setup did not report that hooks were inactive' ;;
  esac
  case "$output" in *'npx git-hook-pure install'*) ;;
    *) fail 'failed automatic setup did not provide the repair command' ;;
  esac
}

test_npm_auto_install_can_be_skipped() {
  local tarball repo ignored global_repo global_prefix output status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  repo=$(new_repo npm-auto-install-skip)
  printf '%s\n' '{"name":"skipped-consumer","private":true}' >"$repo/package.json"

  set +e
  output=$(
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_HOOK_PURE_SKIP_INSTALL=1 \
      npm --cache "$suite_tmp/npm-cache" --prefix "$repo" install \
      --no-audit --no-fund --foreground-scripts "$tarball" 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "skipped npm hook setup failed package install: $output"
  [ ! -e "$repo/.githooks" ] || fail 'skip environment created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'skip environment installed managed hooks'
  fi
  case "$output" in *'automatic Git hook installation skipped'*) ;;
    *) fail 'skip environment did not report the skipped setup' ;;
  esac
  case "$output" in *'npx git-hook-pure install'*) ;;
    *) fail 'skip environment did not provide the later setup command' ;;
  esac

  ignored=$(new_repo npm-ignore-scripts)
  printf '%s\n' '{"name":"ignored-consumer","private":true}' >"$ignored/package.json"
  HOME="$ignored/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    npm --cache "$suite_tmp/npm-cache" --prefix "$ignored" install \
    --no-audit --no-fund --ignore-scripts "$tarball" >/dev/null
  [ ! -e "$ignored/.githooks" ] || fail 'npm --ignore-scripts created .githooks'
  if grep -Rqs 'git-hook-pure start' "$ignored/.git/hooks"; then
    fail 'npm --ignore-scripts installed managed hooks'
  fi

  global_repo=$(new_repo npm-global-install)
  global_prefix="$suite_tmp/npm-global-prefix"
  output=$(
    cd "$global_repo"
    HOME="$global_repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm --cache "$suite_tmp/npm-cache" --prefix "$global_prefix" install -g \
      --no-audit --no-fund --foreground-scripts "$tarball" 2>&1
  )
  [ ! -e "$global_repo/.githooks" ] || fail 'global npm install created .githooks'
  if grep -Rqs 'git-hook-pure start' "$global_repo/.git/hooks"; then
    fail 'global npm install configured repository hooks'
  fi
  case "$output" in *'skipped for a global npm install'*) ;;
    *) fail 'global npm install did not report that hook setup was skipped' ;;
  esac
}

test_npm_auto_install_only_skips_exact_one() {
  local tarball skip_value repo output status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball

  for skip_value in 0 false; do
    repo=$(new_repo "npm-auto-install-not-skipped-$skip_value")
    printf '%s\n' '{"name":"not-skipped-consumer","private":true}' >"$repo/package.json"

    set +e
    output=$(
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_HOOK_PURE_SKIP_INSTALL="$skip_value" \
        npm --cache "$suite_tmp/npm-cache" --prefix "$repo" install \
        --no-audit --no-fund --foreground-scripts "$tarball" 2>&1
    )
    status=$?
    set -e

    [ "$status" -eq 0 ] ||
      fail "GIT_HOOK_PURE_SKIP_INSTALL=$skip_value failed npm package installation: $output"
    grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" ||
      fail "GIT_HOOK_PURE_SKIP_INSTALL=$skip_value skipped automatic hook installation"
    case "$output" in *'Git hooks installed automatically'*) ;;
      *) fail "GIT_HOOK_PURE_SKIP_INSTALL=$skip_value did not report automatic setup" ;;
    esac
  done
}

test_npx_vendors_the_packaged_standalone_executable() {
  local tarball repo output status vendored expected trace tree_before tree_after
  local forbidden_bin command_name unavailable_manager runtime_status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  repo=$(new_repo npx-standalone-vendor)
  printf '%s\n' staged-before-npx >"$repo/staged-sentinel"
  git -C "$repo" add -- staged-sentinel
  tree_before=$(git -C "$repo" write-tree)

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_HOOK_PURE_SKIP_INSTALL=1 \
      npm_config_cache="$suite_tmp/npm-cache" \
      npx --yes "$npm_package_file_spec" install-standalone 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "npx standalone installation failed: $output"
  vendored="$repo/tools/git-hook-pure"
  [ -x "$vendored" ] || fail 'npx did not create an executable project-local manager'
  expected="$suite_tmp/npm-packaged-binary"
  tar -xOf "$tarball" package/dist/git-hook-pure >"$expected"
  assert_files_equal "$expected" "$vendored"
  [ "$(file_mode "$vendored")" = 755 ] || fail 'npx vendored manager mode is not 755'
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" ||
    fail 'npx vendoring did not install Git hooks'

  trace="$repo/standalone.trace"
  write_recording_handler "$repo/.githooks/pre-commit/project-handler"
  forbidden_bin="$repo/forbidden-runtime-commands"
  mkdir -p "$forbidden_bin"
  for command_name in npm npx git-hook-pure; do
    cat >"$forbidden_bin/$command_name" <<'EOF'
#!/bin/sh
exit 97
EOF
    chmod +x "$forbidden_bin/$command_name"
  done
  unavailable_manager="$repo/tools/git-hook-pure.unavailable"
  mv "$vendored" "$unavailable_manager"
  if (
    cd "$repo"
    TRACE="$trace" PATH="$forbidden_bin:$PATH" .git/hooks/pre-commit
  ); then
    runtime_status=0
  else
    runtime_status=$?
  fi
  mv "$unavailable_manager" "$vendored"
  [ "$runtime_status" -eq 0 ] ||
    fail 'vendored hook runtime failed without npm or an external manager binary'
  grep -Fq 'project-handler' "$trace" ||
    fail 'vendored hook runtime depended on npm or an external manager binary'
  [ "$($vendored --version)" = "$package_version" ] ||
    fail 'vendored npm executable reported the wrong version'
  tree_after=$(git -C "$repo" write-tree)
  [ "$tree_after" = "$tree_before" ] || fail 'npx vendoring changed the Git index tree'
  git -C "$repo" ls-files --error-unmatch staged-sentinel >/dev/null ||
    fail 'npx vendoring removed the staged sentinel from the index'
  if git -C "$repo" ls-files --error-unmatch tools/git-hook-pure >/dev/null 2>&1; then
    fail 'npx vendoring added the executable to the Git index'
  fi
  [ "$(git -C "$repo" status --porcelain --untracked-files=all -- tools/git-hook-pure)" = \
    '?? tools/git-hook-pure' ] || fail 'npx vendored executable is not untracked'
}

test_npx_vendors_to_an_explicit_repository_relative_path() {
  local tarball repo nested output status vendored expected
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  repo=$(new_repo npx-explicit-standalone-path)
  nested="$repo/nested/caller"
  mkdir -p "$nested"

  set +e
  output=$(
    cd "$nested"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm_config_cache="$suite_tmp/npm-cache" \
      npx --yes "$npm_package_file_spec" install-standalone \
      scripts/git-hook-pure 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "npx explicit standalone path failed: $output"
  vendored="$repo/scripts/git-hook-pure"
  [ -x "$vendored" ] || fail 'npx did not create the requested project-local manager'
  [ ! -e "$nested/scripts/git-hook-pure" ] ||
    fail 'npx resolved its custom path from the caller cwd instead of the repository root'
  [ ! -e "$repo/tools/git-hook-pure" ] || fail 'npx also created the default standalone path'
  expected="$suite_tmp/npm-explicit-path-binary"
  tar -xOf "$tarball" package/dist/git-hook-pure >"$expected"
  assert_files_equal "$expected" "$vendored"
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" ||
    fail 'npx explicit standalone path did not install Git hooks'
}

test_npx_does_not_run_dependency_setup_before_its_command() {
  local tarball repo output status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  repo=$(new_repo npx-no-dependency-setup)

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm_config_cache="$repo/.npm-cache" npm_config_foreground_scripts=true \
      npx --yes "$npm_package_file_spec" install-standalone \
      /tmp/git-hook-pure-rejected-destination 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "npx accepted an absolute destination: $output"
  [ ! -e "$repo/.githooks" ] || fail 'npx package lifecycle created .githooks before command validation'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'npx package lifecycle installed hooks before command validation'
  fi

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm_config_cache="$repo/.npm-cache" npm_config_foreground_scripts=true \
      npx --yes "$npm_package_file_spec" install-standalone -h 2>&1
  )
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "npx standalone help failed: $output"
  case "$output" in *'Usage: npx git-hook-pure install-standalone'*) ;;
    *) fail 'npx standalone help omitted its usage' ;;
  esac
  [ ! -e "$repo/-h" ] || fail 'npx standalone help was treated as an install path'
  [ ! -e "$repo/.githooks" ] || fail 'npx standalone help created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'npx standalone help installed Git hooks'
  fi

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm_config_cache="$repo/.npm-cache" npm_config_foreground_scripts=true \
      npx --yes "$npm_package_file_spec" install-standalone '' 2>&1
  )
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "npx accepted an explicitly empty standalone path: $output"
  [ ! -e "$repo/tools" ] || fail 'empty npx path created the default destination'
  [ ! -e "$repo/.githooks" ] || fail 'empty npx path created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'empty npx path installed Git hooks'
  fi
}

test_npx_refuses_directory_syntax_before_hook_setup() {
  local tarball repo target output status expected_status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  repo=$(new_repo npx-directory-syntax)

  for target in tools/ 'tools\git-hook-pure' tools/../git-hook-pure C:/git-hook-pure; do
    expected_status=2
    set +e
    output=$(
      cd "$repo"
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        npm_config_cache="$suite_tmp/npm-cache" \
        npx --yes "$npm_package_file_spec" install-standalone "$target" 2>&1
    )
    status=$?
    set -e

    [ "$status" -eq "$expected_status" ] ||
      fail "npx accepted invalid repository-relative syntax $target: $output"
    [ ! -e "$repo/tools" ] || fail "rejected npx syntax created its destination: $target"
    [ ! -e "$repo/.githooks" ] || fail "rejected npx syntax created .githooks: $target"
    if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
      fail "rejected npx syntax installed Git hooks: $target"
    fi
  done
}

test_npx_delegates_git_admin_safety_to_the_standalone_installer() {
  local tarball repo config config_snapshot config_mode hook hook_snapshot hook_mode
  local tree_before tree_after output status
  ensure_npm_package_tarball
  tarball=$npm_package_tarball
  repo=$(new_repo npx-dot-git-destination)
  config="$repo/.git/config"
  config_snapshot="$suite_tmp/npx-dot-git-config"
  cp -p "$config" "$config_snapshot"
  config_mode=$(file_mode "$config")
  hook="$repo/.git/hooks/pre-commit"
  hook_snapshot="$suite_tmp/npx-dot-git-hook"
  printf '%s\n' '#!/bin/sh' 'exit 31' >"$hook"
  chmod 751 "$hook"
  cp -p "$hook" "$hook_snapshot"
  hook_mode=$(file_mode "$hook")
  printf '%s\n' staged-before-rejected-npx >"$repo/staged-sentinel"
  git -C "$repo" add -- staged-sentinel
  tree_before=$(git -C "$repo" write-tree)

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      npm_config_cache="$suite_tmp/npm-cache" \
      npx --yes "$npm_package_file_spec" install-standalone .git/config 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'packed npx accepted .git/config as its destination'
  case "$output" in *'Git administrative'*) ;;
    *) fail "packed npx did not surface standalone destination safety: $output" ;;
  esac
  case "$output" in *'installed hooks'*|*'installed executable'*)
    fail "rejected packed npx path printed success: $output" ;;
  esac
  assert_files_equal "$config_snapshot" "$config"
  [ "$(file_mode "$config")" = "$config_mode" ] ||
    fail 'rejected packed npx path changed Git config mode'
  assert_files_equal "$hook_snapshot" "$hook"
  [ "$(file_mode "$hook")" = "$hook_mode" ] ||
    fail 'rejected packed npx path changed user hook mode'
  tree_after=$(git -C "$repo" write-tree)
  [ "$tree_after" = "$tree_before" ] || fail 'rejected packed npx path changed the index'
  git -C "$repo" ls-files --error-unmatch staged-sentinel >/dev/null ||
    fail 'rejected packed npx path removed the staged sentinel'
  [ ! -e "$repo/.githooks" ] || fail 'rejected packed npx path created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'rejected packed npx path installed managed hooks'
  fi
}

run_npm_package_integration_tests() {
  run_test test_npm_package_automatically_installs_hooks_and_reports_controls
  run_test test_npm_cli_resolves_windows_script_coordinates
  run_test test_npm_auto_install_failure_is_nonfatal_and_actionable
  run_test test_npm_auto_install_can_be_skipped
  run_test test_npm_auto_install_only_skips_exact_one
  run_test test_npx_vendors_the_packaged_standalone_executable
  run_test test_npx_vendors_to_an_explicit_repository_relative_path
  run_test test_npx_does_not_run_dependency_setup_before_its_command
  run_test test_npx_refuses_directory_syntax_before_hook_setup
  run_test test_npx_delegates_git_admin_safety_to_the_standalone_installer
}
