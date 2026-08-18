write_v3_default_hook() {
  local path=$1
  local variant=${2:-shift}

  cat >"$path" <<'EOF'


# ================== git-hook-pure start ==================
projectRoot=`git rev-parse --show-toplevel`
hookName=`basename "$0"`
gitParams="$*"

executeAllFiles() {
  local hookFolderPath="$1"
  local hookFilePath

  for f in `ls -1 "$hookFolderPath"`; do
    hookFilePath="$hookFolderPath"/"$f"
    if  [ ! -d "$hookFilePath" ]; then
      if [ -x "$hookFilePath" ]; then
        shift 2
        "$hookFilePath" "$@" || exit 1
      else
        echo "==============================================="
        echo "WARNING: File $hookFilePath not executable"
        echo "==============================================="
      fi
    fi
  done
}

hookFolderPath="$projectRoot"/.githooks
if [ -d "$hookFolderPath" ]; then
  executeAllFiles "$hookFolderPath" "$hookName" "$@"
fi
if [ -d "$hookFolderPath"/"$hookName" ]; then
  executeAllFiles "$hookFolderPath"/"$hookName" "$@"
fi
# ================== git-hook-pure end ==================
EOF
  if [ "$variant" = slice ]; then
    awk '
      $0 == "        shift 2" {
        getline
        print "        \"$hookFilePath\" \"${@:2}\" || exit 1"
        next
      }
      { print }
    ' "$path" >"$path.old"
    mv "$path.old" "$path"
  fi
  chmod +x "$path"
}

assert_install_refused_without_mutation() {
  local repo=$1
  local label=$2
  shift 2
  local output status

  set +e
  output=$(
    cd "$repo"
    env HOME="$repo/home" "$@" "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "$label: install unexpectedly succeeded"
  case "$output" in
    *core.hooksPath*) ;;
    *) fail "$label: failure did not identify core.hooksPath" ;;
  esac
  [ ! -e "$repo/.githooks" ] || fail "$label: failed install created .githooks"
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail "$label: failed install mutated hooks"
  fi
}

write_argument_trace_line() {
  local label=$1
  shift

  printf '%s' "$label"
  for argument do
    printf '<%s>' "$argument"
  done
  printf '\n'
}

write_pid_reuse_wrapper() {
  local path=$1

  cat >"$path" <<'EOF'
#!/bin/sh
set -eu
action=$1
cli=$2
record=$3
hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks)
preflight=${TMPDIR:-/tmp}/git-hook-pure-preflight.$$.ABC123
transaction=$hooks_dir/.git-hook-pure-$action.$$.ABC123
mkdir "$preflight" "$transaction"
printf 'preflight recovery bytes  \nwithout final newline' >"$preflight/sentinel"
printf 'transaction recovery bytes\n' >"$transaction/sentinel"
chmod 640 "$preflight/sentinel"
chmod 751 "$transaction/sentinel"
if preflight_mode=$(stat -c '%a' "$preflight/sentinel" 2>/dev/null); then
  :
else
  preflight_mode=$(stat -f '%Lp' "$preflight/sentinel")
fi
if transaction_mode=$(stat -c '%a' "$transaction/sentinel" 2>/dev/null); then
  :
else
  transaction_mode=$(stat -f '%Lp' "$transaction/sentinel")
fi
printf '%s\n%s\n%s\n%s\n' \
  "$preflight" "$transaction" "$preflight_mode" "$transaction_mode" >"$record"
exec "$cli" "$action"
EOF
  chmod +x "$path"
}

write_absolute_path_git_stub() {
  local path=$1

  cat >"$path" <<'EOF'
#!/bin/sh
point=
case "$*" in
  'rev-parse --path-format=absolute --git-dir') point=git-dir ;;
  'rev-parse --path-format=absolute --show-toplevel') point=toplevel ;;
  'rev-parse --path-format=absolute --git-path hooks') point=hooks ;;
esac
if [ -n "$point" ] && [ "$point" = "${GIT_ABSOLUTE_PATH_FAILURE_POINT:-}" ]; then
  printf 'injected runtime %s failure\n' "$point" >&2
  exit 73
fi
if [ -n "$point" ] && [ "$point" = "${GIT_ABSOLUTE_PATH_MALFORMED_POINT:-}" ]; then
  printf '%s\n' '--path-format=absolute'
  shift 2
  "$REAL_GIT" rev-parse "$@" || exit $?
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$path"
}

test_dispatch_preserves_every_argument_for_every_handler() {
  local repo trace expected hook
  repo=$(new_repo dispatch-arguments)
  trace="$repo/trace"
  expected="$repo/expected"

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  write_recording_handler "$repo/.githooks/10 universal hook"
  write_recording_handler "$repo/.githooks/20-universal"
  write_recording_handler "$repo/.githooks/commit-msg/10 specific hook"
  write_recording_handler "$repo/.githooks/commit-msg/20-specific"

  hook="$repo/.git/hooks/commit-msg"
  (
    cd "$repo"
    TRACE="$trace" "$hook" 'message file' 'argument * two' 'third'
  )

  cat >"$expected" <<'EOF'
10 universal hook<commit-msg><message file><argument * two><third>
20-universal<commit-msg><message file><argument * two><third>
10 specific hook<message file><argument * two><third>
20-specific<message file><argument * two><third>
EOF
  assert_files_equal "$expected" "$trace"
}

test_dispatch_ignores_hidden_and_directory_entries() {
  local repo hook trace expected

  repo=$(new_repo dispatch-hidden-and-directories)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  write_recording_handler "$repo/.githooks/10-visible-global"
  write_recording_handler "$repo/.githooks/.hidden-global"
  write_recording_handler "$repo/.githooks/.hidden-global-directory/hidden-child"
  write_recording_handler "$repo/.githooks/nested-global-directory/nested-child"
  write_recording_handler "$repo/.githooks/pre-commit/10-visible-specific"
  write_recording_handler "$repo/.githooks/pre-commit/.hidden-specific"
  write_recording_handler "$repo/.githooks/pre-commit/.hidden-specific-directory/hidden-child"
  write_recording_handler "$repo/.githooks/pre-commit/nested-specific-directory/nested-child"

  hook="$repo/.git/hooks/pre-commit"
  trace="$repo/hidden-handler-trace"
  (
    cd "$repo"
    TRACE="$trace" "$hook"
  )
  expected="$repo/hidden-handler-expected"
  cat >"$expected" <<'EOF'
10-visible-global<pre-commit>
10-visible-specific
EOF
  assert_files_equal "$expected" "$trace"
}

test_dispatch_uses_c_filename_order_without_changing_handler_locale() {
  local locale_name candidate c_order locale_order repo trace expected hook handler required=false
  [ "${GIT_HOOK_PURE_REQUIRE_NON_C_COLLATION:-}" = 1 ] && required=true
  locale_name=
  for candidate in en_US.UTF-8 en_US.utf8; do
    if LC_ALL="$candidate" locale charmap >/dev/null 2>&1; then
      locale_name=$candidate
      break
    fi
  done
  if [ -z "$locale_name" ]; then
    if [ "$required" = true ]; then
      fail 'required non-C collation locale is unavailable'
      return 1
    fi
    printf '%s\n' 'SKIP: en_US UTF-8 locale is unavailable'
    return 0
  fi
  c_order=$(printf '%s\n' a b ä | LC_ALL=C sort)
  locale_order=$(printf '%s\n' a b ä | LC_ALL="$locale_name" sort)
  if [ "$c_order" = "$locale_order" ]; then
    if [ "$required" = true ]; then
      fail "$locale_name does not provide the required non-C collation order"
      return 1
    fi
    printf '%s\n' "SKIP: $locale_name does not distinguish the collation fixture"
    return 0
  fi

  repo=$(new_repo dispatch-c-filename-order)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  for handler in a b ä; do
    cat >"$repo/.githooks/$handler" <<'EOF'
#!/bin/sh
printf '%s<%s><%s>\n' "${0##*/}" "${LC_ALL-<unset>}" "${LC_COLLATE-<unset>}" >>"$TRACE"
EOF
    chmod +x "$repo/.githooks/$handler"
  done
  trace="$repo/locale-order.trace"
  hook="$repo/.git/hooks/pre-commit"
  (
    cd "$repo"
    TRACE="$trace" LC_ALL="$locale_name" LC_COLLATE=C bash --posix "$hook"
  )
  expected="$repo/locale-order.expected"
  printf '%s<%s><C>\n' a "$locale_name" b "$locale_name" ä "$locale_name" >"$expected"
  assert_files_equal "$expected" "$trace"
}

test_dispatch_fails_closed_and_preserves_handler_status() {
  local repo hook trace output status
  repo=$(new_repo dispatch-failure)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  trace="$repo/trace"

  cat >"$repo/.githooks/10-fails" <<'EOF'
#!/bin/sh
printf '%s\n' first >>"$TRACE"
exit 7
EOF
  chmod +x "$repo/.githooks/10-fails"
  write_recording_handler "$repo/.githooks/20-must-not-run"

  set +e
  output=$(cd "$repo" && TRACE="$trace" "$hook" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 7 ] || fail "handler status 7 became $status: $output"
  printf '%s\n' first >"$repo/expected"
  assert_files_equal "$repo/expected" "$trace"

  rm -f "$repo/.githooks/10-fails" "$repo/.githooks/20-must-not-run" "$trace"
  printf '%s\n' '#!/bin/sh' >"$repo/.githooks/10-not-executable"
  chmod -x "$repo/.githooks/10-not-executable"
  if [ -x "$repo/.githooks/10-not-executable" ]; then
    printf '%s\n' 'SKIP: filesystem cannot represent a non-executable handler'
    return 0
  fi
  write_recording_handler "$repo/.githooks/20-must-not-run"
  set +e
  output=$(cd "$repo" && TRACE="$trace" "$hook" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'non-executable handler was silently skipped'
  case "$output" in *not\ executable*) ;; *) fail 'non-executable handler had no diagnostic' ;; esac
  [ ! -e "$trace" ] || fail 'dispatcher continued after a non-executable handler'
}

test_install_is_idempotent_and_uninstall_restores_owned_state() {
  local repo hook original original_mode existing_first generated_first managed_count
  repo=$(new_repo install-lifecycle)
  hook="$repo/.git/hooks/pre-commit"
  original="$repo/original-pre-commit"

  cat >"$hook" <<'EOF'
#!/bin/sh
printf 'legacy hook\n' >>"$TRACE"
EOF
  chmod 751 "$hook"
  cp -p "$hook" "$original"
  original_mode=$(file_mode "$hook")

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  existing_first="$repo/existing-pre-commit.first"
  cp -p "$hook" "$existing_first"
  generated_first="$repo/generated-commit-msg.first"
  cp -p "$repo/.git/hooks/commit-msg" "$generated_first"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  assert_files_equal "$existing_first" "$hook"
  assert_files_equal "$generated_first" "$repo/.git/hooks/commit-msg"
  managed_count=$(grep -c '^# ================== git-hook-pure start ==================$' "$hook")
  [ "$managed_count" -eq 1 ] || fail "repeated install injected $managed_count managed blocks"
  [ "$(file_mode "$hook")" = "$original_mode" ] || fail 'install changed hook mode'
  [ -x "$repo/.git/hooks/commit-msg" ] || fail 'new hook is not executable'
  [ "$(sed -n '1p' "$repo/.git/hooks/commit-msg")" = '#!/bin/sh' ] || \
    fail 'new hook has no POSIX shell shebang'

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )

  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] || fail 'uninstall changed hook mode'
  [ ! -e "$repo/.git/hooks/commit-msg" ] || fail 'uninstall left a tool-owned hook behind'
}

test_successful_uninstall_preserves_populated_handler_directory() {
  local repo handlers nested universal specific universal_snapshot specific_snapshot
  local handlers_mode nested_mode universal_mode specific_mode
  repo=$(new_repo uninstall-populated-handlers)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  handlers="$repo/.githooks"
  nested="$handlers/pre-commit"
  universal="$handlers/universal data"
  specific="$nested/specific handler"
  mkdir -p "$nested"
  printf 'universal bytes with trailing spaces  \nlast line without newline' >"$universal"
  printf '#!/bin/sh\nprintf "specific bytes\\n"\n' >"$specific"
  chmod 751 "$handlers"
  chmod 750 "$nested"
  chmod 640 "$universal"
  chmod 751 "$specific"
  universal_snapshot="$repo/universal.snapshot"
  specific_snapshot="$repo/specific.snapshot"
  cp -p "$universal" "$universal_snapshot"
  cp -p "$specific" "$specific_snapshot"
  handlers_mode=$(file_mode "$handlers")
  nested_mode=$(file_mode "$nested")
  universal_mode=$(file_mode "$universal")
  specific_mode=$(file_mode "$specific")

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )

  [ -d "$handlers" ] || fail 'uninstall removed a populated .githooks directory'
  [ -d "$nested" ] || fail 'uninstall removed a populated hook-specific directory'
  assert_files_equal "$universal_snapshot" "$universal"
  assert_files_equal "$specific_snapshot" "$specific"
  [ "$(file_mode "$handlers")" = "$handlers_mode" ] ||
    fail 'uninstall changed the .githooks directory mode'
  [ "$(file_mode "$nested")" = "$nested_mode" ] ||
    fail 'uninstall changed a hook-specific directory mode'
  [ "$(file_mode "$universal")" = "$universal_mode" ] ||
    fail 'uninstall changed a universal handler mode'
  [ "$(file_mode "$specific")" = "$specific_mode" ] ||
    fail 'uninstall changed a hook-specific handler mode'
  [ ! -e "$repo/.git/hooks/pre-commit" ] || fail 'uninstall left a generated hook behind'
}

test_managed_content_identity_uses_the_repository_object_format() {
  local repo hook installed oid
  repo="$suite_tmp/sha256-object-format"
  mkdir -p "$repo/home"
  git init -q --object-format=sha256 "$repo"
  git -C "$repo" config user.name 'Git Hook Pure Tests'
  git -C "$repo" config user.email 'git-hook-pure@example.invalid'

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  oid=$(sed -n 's/^# git-hook-pure content oid: //p' "$hook" | sed -n '1p')
  [ "${#oid}" -eq 64 ] || fail 'managed content did not use the SHA-256 repository object format'
  installed="$repo/installed-pre-commit"
  cp -p "$hook" "$installed"

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  assert_files_equal "$installed" "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  [ ! -e "$hook" ] || fail 'uninstall left a generated hook in a SHA-256 repository'
}

test_install_only_manages_composable_hook_protocols() {
  local repo hook
  repo=$(new_repo composable-hooks)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  for hook in \
    applypatch-msg commit-msg post-applypatch post-checkout post-commit post-index-change \
    post-merge post-receive post-rewrite post-update pre-applypatch pre-auto-gc pre-commit \
    pre-merge-commit pre-push pre-rebase pre-receive prepare-commit-msg sendemail-validate \
    update; do
    [ -x "$repo/.git/hooks/$hook" ] || fail "composable hook was not installed: $hook"
  done

  for hook in fsmonitor-watchman p4-changelist p4-post-changelist p4-pre-submit \
    p4-prepare-changelist proc-receive push-to-checkout reference-transaction; do
    [ ! -e "$repo/.git/hooks/$hook" ] || fail "protocol-specific hook was installed: $hook"
  done
}

test_nonreplayable_hooks_fan_out_by_protocol_category() {
  local repo recorder hook category actual expected
  repo=$(new_repo nonreplayable-fanout)
  recorder="$repo/existing-recorder"
  cat >"$recorder" <<'EOF'
#!/bin/sh
printf '%s' existing
for argument do
  printf '<%s>' "$argument"
done
printf '\n'
EOF
  chmod +x "$recorder"
  for hook in \
    applypatch-msg commit-msg post-applypatch post-checkout post-commit post-index-change \
    post-merge post-update pre-applypatch pre-auto-gc pre-commit pre-merge-commit \
    pre-rebase prepare-commit-msg sendemail-validate update; do
    cp -p "$recorder" "$repo/.git/hooks/$hook"
  done
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  cat >"$repo/.githooks/universal" <<'EOF'
#!/bin/sh
printf '%s' "${0##*/}"
for argument do
  printf '<%s>' "$argument"
done
printf '\n'
EOF
  chmod +x "$repo/.githooks/universal"
  for hook in \
    applypatch-msg commit-msg post-applypatch post-checkout post-commit post-index-change \
    post-merge post-update pre-applypatch pre-auto-gc pre-commit pre-merge-commit \
    pre-rebase prepare-commit-msg sendemail-validate update; do
    mkdir -p "$repo/.githooks/$hook"
    cp -p "$repo/.githooks/universal" "$repo/.githooks/$hook/specific"
  done

  while IFS='|' read -r category hook; do
    case "$category" in
      no-args) set -- ;;
      message-file) set -- 'message file' ;;
      prepare-message) set -- 'message file' merge 'commit oid' ;;
      checkout) set -- 'old oid' 'new oid' 1 ;;
      merge) set -- 1 ;;
      index-change) set -- 1 0 ;;
      rebase) set -- 'upstream ref' 'topic branch' ;;
      post-update) set -- refs/heads/one refs/heads/two ;;
      update) set -- refs/heads/main 'old oid' 'new oid' ;;
      *) fail "unknown hook protocol category: $category" ;;
    esac
    actual="$repo/$hook.actual"
    expected="$repo/$hook.expected"
    (cd "$repo" && "$repo/.git/hooks/$hook" "$@") >"$actual"
    {
      write_argument_trace_line universal "$hook" "$@"
      write_argument_trace_line specific "$@"
      write_argument_trace_line existing "$@"
    } >"$expected"
    assert_files_equal "$expected" "$actual"
  done <<'EOF'
message-file|applypatch-msg
message-file|commit-msg
no-args|post-applypatch
checkout|post-checkout
no-args|post-commit
index-change|post-index-change
merge|post-merge
post-update|post-update
no-args|pre-applypatch
no-args|pre-auto-gc
no-args|pre-commit
no-args|pre-merge-commit
rebase|pre-rebase
prepare-message|prepare-commit-msg
message-file|sendemail-validate
update|update
EOF
}

test_install_preserves_update_instead_dirty_worktree_rejection() {
  local target source branch initial_commit output status
  target=$(new_repo update-instead-target)
  printf '%s\n' initial >"$target/deployed"
  git -C "$target" add deployed
  git -C "$target" commit -qm initial
  branch=$(git -C "$target" symbolic-ref --short HEAD)
  initial_commit=$(git -C "$target" rev-parse HEAD)
  git -C "$target" config receive.denyCurrentBranch updateInstead

  source="$suite_tmp/update-instead-source"
  git clone -q "$target" "$source"
  git -C "$source" config user.name 'Git Hook Pure Tests'
  git -C "$source" config user.email 'git-hook-pure@example.invalid'
  printf '%s\n' pushed >"$source/deployed"
  git -C "$source" add deployed
  git -C "$source" commit -qm pushed

  (
    cd "$target"
    HOME="$target/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  printf '%s\n' dirty >"$target/deployed"

  set +e
  output=$(git -C "$source" push "$target" "HEAD:refs/heads/$branch" 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "install bypassed updateInstead's dirty-worktree rejection: $output"
  [ "$(git -C "$target" rev-parse HEAD)" = "$initial_commit" ] ||
    fail 'rejected updateInstead push still moved the checked-out branch'
  [ "$(cat "$target/deployed")" = dirty ] ||
    fail 'rejected updateInstead push changed the dirty worktree'
}

test_install_transaction_rolls_back_a_replacement_time_signal() {
  local repo hook original stub_bin real_mv status
  repo=$(new_repo install-signal-transaction)
  hook="$repo/.git/hooks/applypatch-msg"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-applypatch
EOF
  chmod 751 "$hook"
  original="$repo/original-applypatch"
  cp -p "$hook" "$original"
  stub_bin="$repo/mv-bin"
  mkdir -p "$stub_bin"
  real_mv=$(command -v mv)
  cat >"$stub_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
last_name=${last##*/}
"$REAL_MV" "$@" || exit $?
[ "$last_name" != "$TARGET_HOOK_NAME" ] || [ -e "$SIGNAL_ONCE_FILE" ] || {
  : >"$SIGNAL_ONCE_FILE"
  kill -TERM "$PPID"
}
EOF
  chmod +x "$stub_bin/mv"

  set +e
  (
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MV="$real_mv" TARGET_HOOK_NAME=applypatch-msg \
      SIGNAL_ONCE_FILE="$repo/install-signalled" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install ignored a replacement-time signal'
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
    fail 'install signal rollback changed an existing hook mode'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'install signal rollback left managed hook content'
  fi
  [ ! -e "$repo/.githooks" ] || fail 'install signal rollback left its generated handler directory'
}

test_install_transaction_preserves_backups_when_rollback_fails() {
  local repo hook original stub_bin real_mv output status recovery_dir recovered_original
  repo=$(new_repo install-failed-rollback)
  hook="$repo/.git/hooks/applypatch-msg"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-before-failed-rollback
EOF
  chmod 751 "$hook"
  original="$repo/original-applypatch"
  cp -p "$hook" "$original"
  stub_bin="$repo/mv-bin"
  mkdir -p "$stub_bin"
  real_mv=$(command -v mv)
  cat >"$stub_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
last_name=${last##*/}
[ "$last_name" != "$TARGET_HOOK_NAME" ] || exit 70
exec "$REAL_MV" "$@"
EOF
  chmod +x "$stub_bin/mv"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MV="$real_mv" TARGET_HOOK_NAME=applypatch-msg \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install hid a rollback failure'
  case "$output" in *'recovery files kept at'*) ;; *) fail 'install rollback failure omitted recovery path' ;; esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
    fail 'failed rollback changed the original hook mode'
  recovery_dir=$(printf '%s\n' "$output" |
    sed -n 's/^\[git-hook-pure\] rollback incomplete; recovery files kept at //p' |
    sed -n '1p')
  [ -n "$recovery_dir" ] || fail 'install rollback failure deleted its recovery directory'
  [ -d "$recovery_dir" ] || fail 'reported recovery directory does not exist'
  recovered_original=$(find "$recovery_dir" -type f -exec cmp -s "$original" {} \; -print |
    sed -n '1p')
  [ -n "$recovered_original" ] || fail 'install rollback failure deleted its original hook backup'
  [ "$(file_mode "$recovered_original")" = "$(file_mode "$original")" ] || \
    fail 'install recovery backup changed the original hook mode'
}

test_hook_transactions_roll_back_supported_signals() {
  local action signal repo hook snapshot other_hook stub_bin real_mv status
  real_mv=$(command -v mv)
  for action in install uninstall; do
    for signal in HUP INT QUIT PIPE TERM; do
      repo=$(new_repo "transaction-$action-$signal")
      hook="$repo/.git/hooks/applypatch-msg"
      cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-hook
EOF
      chmod 751 "$hook"
      if [ "$action" = uninstall ]; then
        (
          cd "$repo"
          HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            "$git_hook_pure" install >/dev/null
        )
      fi
      snapshot="$repo/$action-before-$signal"
      cp -p "$hook" "$snapshot"
      other_hook="$repo/.git/hooks/commit-msg"

      stub_bin="$repo/mv-bin"
      mkdir -p "$stub_bin"
      cat >"$stub_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
last_name=${last##*/}
"$REAL_MV" "$@" || exit $?
[ "$last_name" != "$TARGET_HOOK_NAME" ] || [ -e "$SIGNAL_ONCE_FILE" ] || {
  : >"$SIGNAL_ONCE_FILE"
  kill -s "$TEST_SIGNAL" "$PPID"
}
EOF
      chmod +x "$stub_bin/mv"

      set +e
      (
        trap - "$signal"
        cd "$repo"
        PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MV="$real_mv" TARGET_HOOK_NAME=applypatch-msg \
          SIGNAL_ONCE_FILE="$repo/$action-$signal-signalled" TEST_SIGNAL="$signal" \
          HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
          "$git_hook_pure" "$action" >/dev/null 2>&1
      )
      status=$?
      set -e
      [ "$status" -ne 0 ] || fail "$action ignored SIG$signal"
      assert_files_equal "$snapshot" "$hook"
      [ "$(file_mode "$hook")" = "$(file_mode "$snapshot")" ] || \
        fail "$action SIG$signal rollback changed the hook mode"
      if [ "$action" = install ]; then
        if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
          fail "install SIG$signal rollback left managed hook content"
        fi
        [ ! -e "$repo/.githooks" ] || fail "install SIG$signal rollback left .githooks"
      else
        grep -q 'git-hook-pure start' "$other_hook" || \
          fail "uninstall SIG$signal rollback lost another managed hook"
      fi
    done
  done
}

test_failed_handler_directory_creation_does_not_claim_foreign_state() {
  local repo stub_bin real_mkdir real_mv output status
  repo=$(new_repo handler-directory-race)
  stub_bin="$repo/mv-bin"
  mkdir -p "$stub_bin"
  real_mkdir=$(command -v mkdir)
  real_mv=$(command -v mv)
cat >"$stub_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
last_name=${last##*/}
if [ "$last_name" = .githooks ]; then
  "$REAL_MKDIR" "$TARGET_HANDLERS" || exit $?
  exit 70
fi
exec "$REAL_MV" "$@"
EOF
  chmod +x "$stub_bin/mv"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MKDIR="$real_mkdir" REAL_MV="$real_mv" \
      TARGET_HANDLERS="$repo/.githooks" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'handler directory race was reported as a successful install'
  [ -d "$repo/.githooks" ] || fail 'rollback deleted a handler directory it did not confirm creating'
  [ -z "$(find "$repo/.githooks" ! -path "$repo/.githooks" -print | sed -n '1p')" ] || \
    fail 'handler directory race left project content'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'handler directory race mutated a hook'
  fi
  case "$output" in *'failed to create handler directory'*) ;;
    *) fail 'handler directory race lost its root diagnostic' ;;
  esac
  case "$output" in *'rollback incomplete'*|*'recovery files kept'*)
    fail 'handler directory race falsely reported incomplete rollback' ;;
  esac
}

test_install_fails_if_preexisting_handler_directory_disappears() {
  local repo hook original original_mode handler original_handler handler_mode backup
  local stub_bin real_chmod real_mv injection output status residue

  repo=$(new_repo handler-directory-present-to-missing)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-user-hook
EOF
  chmod 751 "$hook"
  original="$repo/original-pre-commit"
  cp -p "$hook" "$original"
  original_mode=$(file_mode "$original")

  mkdir "$repo/.githooks"
  chmod 750 "$repo/.githooks"
  handler="$repo/.githooks/project-content"
  printf 'project-owned bytes  \nwithout final newline' >"$handler"
  chmod 640 "$handler"
  original_handler="$repo/original-project-content"
  cp -p "$handler" "$original_handler"
  handler_mode=$(file_mode "$original_handler")
  backup="$repo/.githooks.moved"
  injection="$repo/handler-move-injected"
  stub_bin="$repo/chmod-bin"
  real_chmod=$(command -v chmod)
  real_mv=$(command -v mv)
  mkdir "$stub_bin"
  cat >"$stub_bin/chmod" <<'EOF'
#!/bin/sh
"$REAL_CHMOD" "$@" || exit $?
target=
for argument do target=$argument; done
case "$target" in
  */.git-hook-pure-install.*/staged/applypatch-msg)
    if [ ! -e "$INJECTION_RECORD" ]; then
      "$REAL_MV" "$TARGET_HANDLERS" "$HANDLERS_BACKUP" || exit $?
      : >"$INJECTION_RECORD" || exit $?
    fi
    ;;
esac
EOF
  chmod +x "$stub_bin/chmod"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_CHMOD="$real_chmod" REAL_MV="$real_mv" \
      TARGET_HANDLERS="$repo/.githooks" HANDLERS_BACKUP="$backup" \
      INJECTION_RECORD="$injection" HOME="$repo/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e

  [ -f "$injection" ] || fail 'present-to-missing handler-directory injection did not run'
  [ "$status" -ne 0 ] || fail 'install ignored a missing pre-existing handler directory'
  case "$output" in *"[git-hook-pure] handler directory changed"*"$repo/.githooks"*) ;;
    *) fail 'handler-directory change had no actionable diagnostic' ;;
  esac
  case "$output" in *'parameter not set'*) fail 'handler-directory change leaked an unset-variable error' ;; esac
  case "$output" in *'installed hooks'*) fail 'handler-directory change printed install success' ;; esac
  [ ! -e "$repo/.githooks" ] || fail 'manager recreated the moved handler directory'
  [ -d "$backup" ] || fail 'injected handler-directory move lost the project directory'
  assert_files_equal "$original_handler" "$backup/project-content"
  [ "$(file_mode "$backup/project-content")" = "$handler_mode" ] ||
    fail 'handler-directory change altered project content mode'
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] ||
    fail 'handler-directory change altered the user hook mode'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'handler-directory change wrote managed hook content'
  fi
  for residue in "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "handler-directory change left operation residue: $residue"
  done
}

test_handler_directory_creation_signal_rolls_back_its_owned_directory() {
  local repo stub_bin real_mv status

  repo=$(new_repo handler-directory-signal)
  stub_bin="$repo/mv-bin"
  mkdir -p "$stub_bin"
  real_mv=$(command -v mv)
  cat >"$stub_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
last_name=${last##*/}
if [ "$last_name" = .githooks ]; then
  "$REAL_MV" "$@" || exit $?
  kill -QUIT "$PPID"
  exit 0
fi
exec "$REAL_MV" "$@"
EOF
  chmod +x "$stub_bin/mv"

  set +e
  (
    trap - QUIT
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MV="$real_mv" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install ignored a handler-directory creation signal'
  [ ! -e "$repo/.githooks" ] || fail 'handler-directory signal rollback left its owned directory'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'handler-directory signal rollback left managed hook content'
  fi
}

test_existing_hook_exit_cannot_bypass_managed_handlers() {
  local repo hook original trace
  repo=$(new_repo existing-exit)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' legacy >>"$TRACE"
exit 0
EOF
  chmod +x "$hook"
  original="$repo/original"
  cp -p "$hook" "$original"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  write_recording_handler "$repo/.githooks/pre-commit/managed"
  trace="$repo/trace"
  (cd "$repo" && TRACE="$trace" "$hook")
  cat >"$repo/expected" <<'EOF'
managed
legacy
EOF
  assert_files_equal "$repo/expected" "$trace"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  assert_files_equal "$original" "$hook"
}

test_dispatch_does_not_leak_state_into_an_existing_hook() {
  local repo hook trace
  repo=$(new_repo existing-state)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
  if [ -n "${projectRoot+x}${hookName+x}${hookFolderPath+x}${hookFilePath+x}${runtime_git_dir+x}" ] ||
    command -v executeAllFiles >/dev/null 2>&1; then
  printf '%s\n' leaked-state >>"$TRACE"
  exit 41
fi
if [ "${git_hook_pure_runtime_hook_name-}" != original-hook-name ] ||
  [ "${git_hook_pure_runtime_input-}" != original-input ] ||
  [ "${git_hook_pure_runtime_status-}" != original-status ]; then
  printf '%s\n' overwritten-runtime-environment >>"$TRACE"
  exit 42
fi
printf '%s\n' existing-clean >>"$TRACE"
EOF
  chmod +x "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  write_recording_handler "$repo/.githooks/pre-commit/managed"
  trace="$repo/trace"
  set +e
  (
    cd "$repo"
    TRACE="$trace" \
      git_hook_pure_runtime_hook_name=original-hook-name \
      git_hook_pure_runtime_input=original-input \
      git_hook_pure_runtime_status=original-status \
      "$hook"
  )
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "dispatcher state changed existing hook behavior (status $status)"
  cat >"$repo/expected" <<'EOF'
managed
existing-clean
EOF
  assert_files_equal "$repo/expected" "$trace"
}

test_runtime_preserves_caller_environment_for_handlers_and_existing_hook() {
  local repo hook handler payload trace status
  repo=$(new_repo runtime-caller-environment)
  hook="$repo/.git/hooks/pre-push"
  cat >"$hook" <<'EOF'
#!/bin/sh
if [ "${git_hook_pure_runtime_hook_name-}" != caller-hook ] ||
  [ "${git_hook_pure_runtime_input-}" != caller-input ] ||
  [ "${git_hook_pure_runtime_status-}" != caller-status ]; then
  exit 61
fi
cat >"$TRACE.existing"
EOF
  chmod +x "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  handler="$repo/.githooks/pre-push/environment-handler"
  mkdir -p "$(dirname -- "$handler")"
  cat >"$handler" <<'EOF'
#!/bin/sh
if [ "${git_hook_pure_runtime_hook_name-}" != caller-hook ] ||
  [ "${git_hook_pure_runtime_input-}" != caller-input ] ||
  [ "${git_hook_pure_runtime_status-}" != caller-status ]; then
  exit 62
fi
cat >"$TRACE.managed"
EOF
  chmod +x "$handler"
  payload="$repo/payload"
  printf 'first ref line\nsecond ref line without newline' >"$payload"
  trace="$repo/runtime-environment"

  set +e
  (
    cd "$repo"
    TRACE="$trace" \
      git_hook_pure_runtime_hook_name=caller-hook \
      git_hook_pure_runtime_input=caller-input \
      git_hook_pure_runtime_status=caller-status \
      "$hook" origin example.invalid <"$payload"
  )
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "runtime changed caller environment for a consumer (status $status)"
  assert_files_equal "$payload" "$trace.managed"
  assert_files_equal "$payload" "$trace.existing"
}

test_dispatch_restores_globbing_for_a_noglob_existing_hook() {
  local repo hook trace
  repo=$(new_repo existing-noglob)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh -f
printf '%s\n' existing-noglob >>"$TRACE"
EOF
  chmod +x "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  write_recording_handler "$repo/.githooks/pre-commit/managed-noglob"
  trace="$repo/trace"
  (cd "$repo" && TRACE="$trace" "$hook")
  cat >"$repo/expected" <<'EOF'
managed-noglob
existing-noglob
EOF
  assert_files_equal "$repo/expected" "$trace"
}

test_install_migrates_a_legacy_managed_only_hook() {
  local variant repo hook trace
  for variant in slice shift; do
    repo=$(new_repo "legacy-migration-$variant")
    hook="$repo/.git/hooks/commit-msg"
    write_v3_default_hook "$hook" "$variant"

    (
      cd "$repo"
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$git_hook_pure" install >/dev/null
    )
    [ "$(sed -n '1p' "$hook")" = '#!/bin/sh' ] || fail "$variant legacy hook was not given a shebang"
    [ "$(grep -c 'git-hook-pure start' "$hook")" -eq 1 ] || fail "$variant legacy hook was not replaced once"
    ! grep -q 'gitParams=' "$hook" || fail "$variant legacy dispatcher survived migration"
    write_recording_handler "$repo/.githooks/commit-msg/migrated-handler"
    trace="$repo/trace"
    (cd "$repo" && TRACE="$trace" "$hook" message-file)
    printf '%s\n' 'migrated-handler<message-file>' >"$repo/expected"
    assert_files_equal "$repo/expected" "$trace"

    (cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null)
    [ ! -e "$hook" ] || fail "uninstall retained a migrated $variant tool-owned hook"
  done
}

test_install_refuses_core_hooks_path_before_mutation() {
  local repo global_config included_config system_config conditional_value

  repo=$(new_repo core-hooks-path)
  git -C "$repo" config core.hooksPath custom-hooks
  assert_install_refused_without_mutation "$repo" local \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

  repo=$(new_repo core-hooks-path-empty)
  git -C "$repo" config core.hooksPath ''
  assert_install_refused_without_mutation "$repo" empty \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

  repo=$(new_repo core-hooks-path-global)
  global_config="$repo/global.gitconfig"
  git config --file "$global_config" core.hooksPath global-hooks
  assert_install_refused_without_mutation "$repo" global \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$global_config"

  repo=$(new_repo core-hooks-path-xdg)
  mkdir -p "$repo/xdg/git"
  git config --file "$repo/xdg/git/config" core.hooksPath xdg-hooks
  assert_install_refused_without_mutation "$repo" xdg-global \
    GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$repo/xdg"

  repo=$(new_repo core-hooks-path-system)
  system_config="$repo/system.gitconfig"
  git config --file "$system_config" core.hooksPath system-hooks
  assert_install_refused_without_mutation "$repo" system \
    GIT_CONFIG_SYSTEM="$system_config" GIT_CONFIG_GLOBAL=/dev/null

  repo=$(new_repo core-hooks-path-worktree)
  git -C "$repo" config extensions.worktreeConfig true
  git -C "$repo" config --worktree core.hooksPath worktree-hooks
  assert_install_refused_without_mutation "$repo" worktree \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

  repo=$(new_repo core-hooks-path-command)
  assert_install_refused_without_mutation "$repo" command \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=command-hooks

  repo=$(new_repo core-hooks-path-include)
  global_config="$repo/global.gitconfig"
  included_config="$repo/included.gitconfig"
  git config --file "$included_config" core.hooksPath included-hooks
  git config --file "$global_config" include.path "$included_config"
  assert_install_refused_without_mutation "$repo" include \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$global_config"

  repo=$(new_repo core-hooks-path-conditional-include)
  global_config="$repo/global.gitconfig"
  included_config="$repo/conditional-included.gitconfig"
  git config --file "$included_config" core.hooksPath conditional-included-hooks
  git config --file "$global_config" \
    "includeIf.gitdir/i:**/${repo##*/}/.git.path" "$included_config"
  conditional_value=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$repo" config --includes --get core.hooksPath)
  [ "$conditional_value" = conditional-included-hooks ] ||
    fail 'conditional-include fixture did not activate core.hooksPath'
  assert_install_refused_without_mutation "$repo" conditional-include \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$global_config"

  repo=$(new_repo core-hooks-path-malformed)
  global_config="$repo/global.gitconfig"
  printf '%s\n' '[broken' >"$global_config"
  assert_install_refused_without_mutation "$repo" malformed \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$global_config"
}

test_uninstall_never_follows_a_later_core_hooks_path() {
  local repo default_hook output status
  repo=$(new_repo uninstall-hooks-path)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  default_hook="$repo/.git/hooks/pre-commit"
  git -C "$repo" config core.hooksPath custom-hooks

  set +e
  output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    "$git_hook_pure" uninstall 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'uninstall followed a newly configured core.hooksPath'
  case "$output" in *core.hooksPath*) ;; *) fail 'uninstall conflict had no hooksPath diagnostic' ;; esac
  grep -q 'git-hook-pure start' "$default_hook" || fail 'refused uninstall mutated default hook'
  [ ! -e "$repo/custom-hooks" ] || fail 'refused uninstall created custom hooks path'

  git -C "$repo" config --unset-all core.hooksPath
  (cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    "$git_hook_pure" uninstall >/dev/null)
  [ ! -e "$default_hook" ] || fail 'uninstall after resolving hooksPath conflict failed'
}

test_uninstall_preflights_every_target_before_mutation() {
  local repo blocked_hook unaffected_hook original output status
  repo=$(new_repo uninstall-preflight)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  blocked_hook="$repo/.git/hooks/pre-commit"
  unaffected_hook="$repo/.git/hooks/commit-msg"
  original="$repo/original-commit-msg"
  cp -p "$unaffected_hook" "$original"
  rm -f "$blocked_hook"
  mkdir "$blocked_hook"

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'uninstall treated a target read error as no managed marker'
  case "$output" in *'regular file'*) ;; *) fail 'uninstall read failure had no actionable diagnostic' ;; esac
  [ -d "$blocked_hook" ] || fail 'uninstall modified its unreadable target'
  assert_files_equal "$original" "$unaffected_hook"
  [ "$(file_mode "$unaffected_hook")" = "$(file_mode "$original")" ] || \
    fail 'uninstall preflight failure changed an unaffected hook mode'
}

test_uninstall_symlink_failure_leaves_no_operation_residue() {
  local repo hook tmp output status residue
  repo=$(new_repo uninstall-symlink-cleanup)
  hook="$repo/.git/hooks/pre-commit"
  tmp="$repo/tmp"
  mkdir -p "$tmp"
  ln -s /dev/null "$hook"

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      TMPDIR="$tmp" "$git_hook_pure" uninstall 2>&1
  )
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'uninstall accepted a symbolic-link hook'
  case "$output" in *'symbolic link'*) ;;
    *) fail 'symbolic-link refusal had no actionable diagnostic' ;;
  esac
  for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "symbolic-link refusal left operation residue: $residue"
  done
}

test_uninstall_staging_failure_reports_and_leaves_no_residue() {
  local repo hook installed installed_mode tmp stub_bin output status residue
  repo=$(new_repo uninstall-staging-cleanup)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original
EOF
  chmod 751 "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  installed="$repo/installed-pre-commit"
  cp -p "$hook" "$installed"
  installed_mode=$(file_mode "$installed")
  tmp="$repo/tmp"
  stub_bin="$repo/cp-bin"
  mkdir -p "$tmp" "$stub_bin"
  cat >"$stub_bin/cp" <<'EOF'
#!/bin/sh
exit 73
EOF
  chmod +x "$stub_bin/cp"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" HOME="$repo/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$tmp" \
      "$git_hook_pure" uninstall 2>&1
  )
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'uninstall ignored a staging copy failure'
  case "$output" in *'failed to stage hook for uninstall'*) ;;
    *) fail 'uninstall staging failure had no actionable diagnostic' ;;
  esac
  assert_files_equal "$installed" "$hook"
  [ "$(file_mode "$hook")" = "$installed_mode" ] ||
    fail 'uninstall staging failure changed the hook mode'
  for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "uninstall staging failure left operation residue: $residue"
  done
}

test_install_staging_failures_preserve_hooks_and_status() {
  local repo hook original original_mode tmp stub_bin real_mktemp real_cp injection
  local preflight_record output status residue

  repo=$(new_repo install-missing-staged-state)
  hook=$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  hook=$hook/pre-commit
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-staged-state-hook
EOF
  chmod 751 "$hook"
  original="$repo/original-pre-commit"
  cp -p "$hook" "$original"
  original_mode=$(file_mode "$original")
  tmp="$repo/tmp"
  stub_bin="$repo/mktemp-bin"
  injection="$repo/state-removal-injected"
  preflight_record="$repo/preflight-dir-record"
  real_mktemp=$(command -v mktemp)
  mkdir -p "$tmp" "$stub_bin"
  cat >"$stub_bin/mktemp" <<'EOF'
#!/bin/sh
template=
for argument do template=$argument; done
created=$("$REAL_MKTEMP" "$@") || exit $?
case "$template" in
  *git-hook-pure-preflight.*.XXXXXX)
    printf '%s\n' "$created" >"$PREFLIGHT_RECORD" || exit $?
    ;;
  *.git-hook-pure-install.*.XXXXXX)
    IFS= read -r preflight <"$PREFLIGHT_RECORD" || exit $?
    state=$preflight/pre-commit.state
    [ -f "$state" ] || exit 74
    rm -f "$state" || exit $?
    : >"$INJECTION_RECORD" || exit $?
    ;;
esac
printf '%s\n' "$created"
EOF
  chmod +x "$stub_bin/mktemp"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MKTEMP="$real_mktemp" \
      PREFLIGHT_RECORD="$preflight_record" INJECTION_RECORD="$injection" HOME="$repo/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$tmp" \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e

  [ -f "$injection" ] || fail 'missing-state injection did not run'
  [ "$status" -ne 0 ] || fail 'install ignored a missing staged-state file'
  case "$output" in *"failed to stage hook for install: $hook"*) ;;
    *) fail 'missing staged state had no hook-specific staging diagnostic' ;;
  esac
  case "$output" in *'installed hooks'*) fail 'missing staged state printed install success' ;; esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] ||
    fail 'missing staged state changed the original hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'missing staged state created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'missing staged state wrote managed hook content'
  fi
  for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "missing staged state left operation residue: $residue"
  done

  repo=$(new_repo install-staging-status)
  hook=$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  hook=$hook/pre-commit
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-staging-status-hook
EOF
  chmod 751 "$hook"
  original="$repo/original-pre-commit"
  cp -p "$hook" "$original"
  original_mode=$(file_mode "$original")
  tmp="$repo/tmp"
  stub_bin="$repo/cp-bin"
  real_cp=$(command -v cp)
  mkdir -p "$tmp" "$stub_bin"
  cat >"$stub_bin/cp" <<'EOF'
#!/bin/sh
destination=
for argument do destination=$argument; done
case "$destination" in
  */.git-hook-pure-install.*/staged/pre-commit) exit 73 ;;
esac
exec "$REAL_CP" "$@"
EOF
  chmod +x "$stub_bin/cp"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_CP="$real_cp" HOME="$repo/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$tmp" \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 73 ] || fail "install staging failure exited $status instead of 73"
  case "$output" in *"failed to stage hook for install: $hook"*) ;;
    *) fail 'install staging failure had no hook-specific diagnostic' ;;
  esac
  case "$output" in *'installed hooks'*) fail 'install staging failure printed success' ;; esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] ||
    fail 'install staging failure changed the original hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'install staging failure created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'install staging failure wrote managed hook content'
  fi
  for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "install staging failure left operation residue: $residue"
  done
}

test_successful_operations_preserve_pid_reuse_recovery_siblings() {
  local action repo hook tmp wrapper sibling_record preflight_sibling transaction_sibling
  local preflight_expected transaction_expected preflight_mode transaction_mode residue

  for action in install uninstall; do
    repo=$(new_repo "pid-reuse-success-$action")
    hook="$repo/.git/hooks/pre-commit"
    cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original
EOF
    chmod 751 "$hook"
    if [ "$action" = uninstall ]; then
      (
        cd "$repo"
        HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
          "$git_hook_pure" install >/dev/null
      )
      rmdir "$repo/.githooks"
    fi

    tmp="$repo/tmp"
    wrapper="$repo/pid-reuse-wrapper"
    sibling_record="$repo/pid-reuse-siblings"
    preflight_expected="$repo/preflight-sentinel.expected"
    transaction_expected="$repo/transaction-sentinel.expected"
    mkdir -p "$tmp"
    printf 'preflight recovery bytes  \nwithout final newline' >"$preflight_expected"
    printf 'transaction recovery bytes\n' >"$transaction_expected"
    write_pid_reuse_wrapper "$wrapper"

    (
      cd "$repo"
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        TMPDIR="$tmp" "$wrapper" "$action" "$git_hook_pure" "$sibling_record" >/dev/null
    )

    preflight_sibling=$(path_in_shell_coordinates "$(sed -n '1p' "$sibling_record")")
    transaction_sibling=$(path_in_shell_coordinates "$(sed -n '2p' "$sibling_record")")
    preflight_mode=$(sed -n '3p' "$sibling_record")
    transaction_mode=$(sed -n '4p' "$sibling_record")
    assert_files_equal "$preflight_expected" "$preflight_sibling/sentinel"
    assert_files_equal "$transaction_expected" "$transaction_sibling/sentinel"
    [ "$(file_mode "$preflight_sibling/sentinel")" = "$preflight_mode" ] ||
      fail "$action changed the preflight recovery mode"
    [ "$(file_mode "$transaction_sibling/sentinel")" = "$transaction_mode" ] ||
      fail "$action changed the transaction recovery mode"
    for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
      case "$residue" in
        "$preflight_sibling"|"$transaction_sibling") continue ;;
      esac
      [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
        fail "$action left operation residue: $residue"
    done
  done
}

test_operation_cleans_mktemp_output_when_assignment_is_interrupted() {
  local action phase target repo hook snapshot snapshot_mode tmp stub_bin real_mktemp
  local record output status created expected_created residue other_hook wrapper sibling_record
  local preflight_sibling transaction_sibling preflight_expected transaction_expected
  local preflight_mode transaction_mode
  real_mktemp=$(command -v mktemp)

  for action in install uninstall; do
    for phase in preflight transaction; do
      repo=$(new_repo "mktemp-assignment-$action-$phase")
      hook="$repo/.git/hooks/pre-commit"
      cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original
EOF
      chmod 751 "$hook"
      if [ "$action" = uninstall ]; then
        (
          cd "$repo"
          HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            "$git_hook_pure" install >/dev/null
        )
        rmdir "$repo/.githooks"
      fi
      snapshot="$repo/hook-before-interruption"
      cp -p "$hook" "$snapshot"
      snapshot_mode=$(file_mode "$snapshot")
      other_hook="$repo/.git/hooks/commit-msg"
      tmp="$repo/tmp"
      stub_bin="$repo/mktemp-bin"
      record="$repo/created-mktemp-path"
      sibling_record="$repo/pid-reuse-siblings"
      wrapper="$repo/pid-reuse-wrapper"
      preflight_expected="$repo/preflight-sentinel.expected"
      transaction_expected="$repo/transaction-sentinel.expected"
      mkdir -p "$tmp" "$stub_bin"
      printf 'preflight recovery bytes  \nwithout final newline' >"$preflight_expected"
      printf 'transaction recovery bytes\n' >"$transaction_expected"
      write_pid_reuse_wrapper "$wrapper"
      case "$phase" in
        preflight) target=git-hook-pure-preflight ;;
        transaction) target=.git-hook-pure-$action ;;
      esac
      cat >"$stub_bin/mktemp" <<'EOF'
#!/bin/sh
template=
for argument do template=$argument; done
case "$template" in
  *"$MKTEMP_TARGET"*)
    created=${template%XXXXXX}DEF456
    mkdir "$created" || exit $?
    printf '%s\n' "$created" >"$MKTEMP_RECORD" || exit $?
    kill -TERM "$PPID"
    kill -TERM "$$"
    exit 143
    ;;
esac
exec "$REAL_MKTEMP" "$@"
EOF
      chmod +x "$stub_bin/mktemp"

      set +e
      output=$(
        cd "$repo"
        PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MKTEMP="$real_mktemp" \
          MKTEMP_TARGET="$target" MKTEMP_RECORD="$record" \
          HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
          TMPDIR="$tmp" "$wrapper" "$action" "$git_hook_pure" "$sibling_record" 2>&1
      )
      status=$?
      set -e

      [ "$status" -ne 0 ] || fail "$action $phase mktemp interruption was ignored: $output"
      [ -s "$record" ] ||
        fail "$action $phase mktemp interruption created no recorded path: $output"
      IFS= read -r created <"$record"
      created=$(path_in_shell_coordinates "$created")
      preflight_sibling=$(path_in_shell_coordinates "$(sed -n '1p' "$sibling_record")")
      transaction_sibling=$(path_in_shell_coordinates "$(sed -n '2p' "$sibling_record")")
      preflight_mode=$(sed -n '3p' "$sibling_record")
      transaction_mode=$(sed -n '4p' "$sibling_record")
      case "$phase" in
        preflight) expected_created=${preflight_sibling%.ABC123}.1.DEF456 ;;
        transaction) expected_created=${transaction_sibling%.ABC123}.1.DEF456 ;;
      esac
      [ "$created" = "$expected_created" ] ||
        fail "$action $phase selected unexpected operation namespace: $created"
      [ ! -e "$created" ] && [ ! -L "$created" ] ||
        fail "$action $phase mktemp interruption left its unassigned path: $created"
      assert_files_equal "$preflight_expected" "$preflight_sibling/sentinel"
      assert_files_equal "$transaction_expected" "$transaction_sibling/sentinel"
      [ "$(file_mode "$preflight_sibling/sentinel")" = "$preflight_mode" ] ||
        fail "$action $phase cleanup changed the preflight recovery mode"
      [ "$(file_mode "$transaction_sibling/sentinel")" = "$transaction_mode" ] ||
        fail "$action $phase cleanup changed the transaction recovery mode"
      assert_files_equal "$snapshot" "$hook"
      [ "$(file_mode "$hook")" = "$snapshot_mode" ] ||
        fail "$action $phase mktemp interruption changed the hook mode"
      [ ! -e "$repo/.githooks" ] ||
        fail "$action $phase mktemp interruption left .githooks"
      if [ "$action" = install ]; then
        if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
          fail "install $phase mktemp interruption left managed hook content"
        fi
      else
        grep -q 'git-hook-pure start' "$other_hook" ||
          fail "uninstall $phase mktemp interruption removed another managed hook"
      fi
      for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
        case "$residue" in
          "$preflight_sibling"|"$transaction_sibling") continue ;;
        esac
        [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
          fail "$action $phase mktemp interruption left operation residue: $residue"
      done
    done
  done
}

test_install_preserves_grep_errors_in_owned_marker_validation() {
  local repo hook original original_mode tmp stub_bin real_grep state output status residue
  repo=$(new_repo install-owned-marker-grep-error)
  hook="$repo/.git/hooks/pre-commit"
  write_v3_default_hook "$hook"
  printf '%s\n' '# git-hook-pure generated hook' >>"$hook"
  original="$repo/original-pre-commit"
  cp -p "$hook" "$original"
  original_mode=$(file_mode "$original")
  tmp="$repo/tmp"
  stub_bin="$repo/grep-bin"
  state="$repo/grep-count"
  real_grep=$(command -v grep)
  mkdir -p "$tmp" "$stub_bin"
  cat >"$stub_bin/grep" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -Eq ] && [ "${2:-}" = '^# ==* git-hook-pure (start|end) ==*$' ]; then
  count=0
  [ ! -f "$GREP_COUNT" ] || IFS= read -r count <"$GREP_COUNT"
  count=$((count + 1))
  printf '%s\n' "$count" >"$GREP_COUNT"
  if [ "$count" -eq 2 ]; then
    exit 2
  fi
fi
exec "$REAL_GREP" "$@"
EOF
  chmod +x "$stub_bin/grep"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GREP="$real_grep" GREP_COUNT="$state" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      TMPDIR="$tmp" "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "owned-marker grep error exited $status instead of 2"
  case "$output" in *'unable to inspect existing hook'*) ;;
    *) fail 'owned-marker grep error was misreported as invalid marker content' ;;
  esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] ||
    fail 'owned-marker grep error changed the hook mode'
  for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "owned-marker grep error left operation residue: $residue"
  done
}

test_uninstall_preserves_hook_when_shebang_grep_errors() {
  local repo hook original original_mode installed installed_mode tmp stub_bin real_grep
  local output status residue
  repo=$(new_repo uninstall-shebang-grep-error)
  hook="$repo/.git/hooks/pre-commit"
  printf '#!/bin/sh' >"$hook"
  chmod 751 "$hook"
  original="$repo/original-pre-commit"
  cp -p "$hook" "$original"
  original_mode=$(file_mode "$original")
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  installed="$repo/installed-pre-commit"
  cp -p "$hook" "$installed"
  installed_mode=$(file_mode "$installed")
  tmp="$repo/tmp"
  stub_bin="$repo/grep-bin"
  real_grep=$(command -v grep)
  mkdir -p "$tmp" "$stub_bin"
  cat >"$stub_bin/grep" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -q ] && [ "${2:-}" = '^#!' ]; then
  exit 2
fi
exec "$REAL_GREP" "$@"
EOF
  chmod +x "$stub_bin/grep"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GREP="$real_grep" HOME="$repo/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$tmp" \
      "$git_hook_pure" uninstall 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "shebang grep error exited $status instead of 2"
  case "$output" in *'unable to inspect hook'*) ;;
    *) fail 'shebang grep error was misreported as invalid marker content' ;;
  esac
  assert_files_equal "$installed" "$hook"
  [ "$(file_mode "$hook")" = "$installed_mode" ] ||
    fail 'shebang grep error changed the installed hook mode'
  for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "shebang grep error left operation residue: $residue"
  done

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] ||
    fail 'uninstall after a shebang grep error changed the original hook mode'
}

test_install_preserves_hook_when_blank_check_grep_errors() {
  local repo hook original original_mode tmp stub_bin real_grep output status residue
  repo=$(new_repo install-blank-check-grep-error)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original
EOF
  chmod 751 "$hook"
  original="$repo/original-pre-commit"
  cp -p "$hook" "$original"
  original_mode=$(file_mode "$original")
  tmp="$repo/tmp"
  stub_bin="$repo/grep-bin"
  real_grep=$(command -v grep)
  mkdir -p "$tmp" "$stub_bin"
  cat >"$stub_bin/grep" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -q ] && [ "${2:-}" = '[^[:space:]]' ]; then
  exit 2
fi
exec "$REAL_GREP" "$@"
EOF
  chmod +x "$stub_bin/grep"

  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GREP="$real_grep" HOME="$repo/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$tmp" \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "blank-check grep error exited $status instead of 2"
  case "$output" in *'unable to inspect existing hook'*) ;;
    *) fail 'blank-check grep error was misreported as a blank hook' ;;
  esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] ||
    fail 'blank-check grep error changed the hook mode'
  for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "blank-check grep error left operation residue: $residue"
  done
}

test_repository_resolution_preserves_git_failure_diagnostics() {
  local stub_bin real_git point expected repo tmp output status residue
  stub_bin="$suite_tmp/repository-git-error-bin"
  real_git=$(command -v git)
  mkdir -p "$stub_bin"
  cat >"$stub_bin/git" <<'EOF'
#!/bin/sh
case "$GIT_FAILURE_POINT:$*" in
  'repository:rev-parse --git-dir'|\
  'is-bare:rev-parse --is-bare-repository'|\
  'git-dir:rev-parse --path-format=absolute --git-dir'|\
  'worktree-config:config --local --get core.worktree'|\
  'toplevel:rev-parse --path-format=absolute --show-toplevel'|\
  'hooks:rev-parse --path-format=absolute --git-path hooks')
    printf 'injected %s failure\n' "$GIT_FAILURE_POINT" >&2
    exit 73
    ;;
esac
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$stub_bin/git"

  for point in repository is-bare git-dir worktree-config toplevel hooks; do
    repo=$(new_repo "repository-git-error-$point")
    tmp="$repo/tmp"
    mkdir -p "$tmp"
    case "$point" in
      repository) expected='unable to inspect the Git repository' ;;
      is-bare) expected='unable to determine whether the repository is bare' ;;
      git-dir) expected='unable to resolve the Git directory' ;;
      worktree-config) expected='unable to inspect the repository worktree configuration' ;;
      toplevel) expected='unable to resolve the worktree root' ;;
      hooks) expected='unable to resolve the Git hooks directory' ;;
    esac

    set +e
    output=$(
      cd "$repo"
      PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GIT="$real_git" GIT_FAILURE_POINT="$point" \
        HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        TMPDIR="$tmp" "$git_hook_pure" install 2>&1
    )
    status=$?
    set -e

    [ "$status" -eq 73 ] || fail "$point Git failure exited $status instead of 73"
    case "$output" in *"$expected"*) ;;
      *) fail "$point Git failure had no operation-specific diagnostic" ;;
    esac
    case "$output" in *"injected $point failure"*) ;;
      *) fail "$point Git failure discarded Git's diagnostic" ;;
    esac
    case "$output" in *'Git 2.31'*) fail "$point Git failure was misreported as a version failure" ;; esac
    [ ! -e "$repo/.githooks" ] || fail "$point Git failure created .githooks"
    if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
      fail "$point Git failure wrote managed hook content"
    fi
    for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
      [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
        fail "$point Git failure left operation residue: $residue"
    done
  done
}

test_repository_resolution_rejects_malformed_absolute_git_paths() {
  local stub_bin real_git point repo hook original original_mode handler original_handler
  local handler_mode tmp output status residue garbage_component

  stub_bin="$suite_tmp/absolute-path-git-bin"
  real_git=$(command -v git)
  mkdir -p "$stub_bin"
  write_absolute_path_git_stub "$stub_bin/git"
  garbage_component=$(printf '%s\n%s' '--path-format=absolute' '.git')

  for point in git-dir toplevel hooks; do
    repo=$(new_repo "malformed-absolute-$point")
    hook="$repo/.git/hooks/pre-commit"
    cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-user-hook
EOF
    chmod 751 "$hook"
    original="$repo/original-pre-commit"
    cp -p "$hook" "$original"
    original_mode=$(file_mode "$original")
    mkdir "$repo/.githooks"
    handler="$repo/.githooks/project-owned"
    printf 'project-owned handler bytes  \nwithout final newline' >"$handler"
    chmod 640 "$handler"
    original_handler="$repo/original-project-owned"
    cp -p "$handler" "$original_handler"
    handler_mode=$(file_mode "$original_handler")
    tmp="$repo/tmp"
    mkdir "$tmp"

    set +e
    output=$(
      cd "$repo"
      PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GIT="$real_git" \
        GIT_ABSOLUTE_PATH_MALFORMED_POINT="$point" HOME="$repo/home" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$tmp" \
        "$git_hook_pure" install 2>&1
    )
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "$point malformed absolute Git path was accepted"
    case "$output" in *'Git 2.31'*'absolute path'*) ;;
      *) fail "$point malformed absolute Git path had no capability diagnostic" ;;
    esac
    case "$output" in *'installed hooks'*) fail "$point malformed Git path printed success" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$original_mode" ] ||
      fail "$point malformed Git path changed the user hook mode"
    assert_files_equal "$original_handler" "$handler"
    [ "$(file_mode "$handler")" = "$handler_mode" ] ||
      fail "$point malformed Git path changed project handler mode"
    [ ! -e "$repo/$garbage_component" ] ||
      fail "$point malformed Git path created a garbage path"
    if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
      fail "$point malformed Git path wrote managed hook content"
    fi
    for residue in "$tmp"/git-hook-pure-* "$repo/.git/hooks"/.git-hook-pure-*; do
      [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
        fail "$point malformed Git path left operation residue: $residue"
    done
  done
}

test_runtime_rejects_malformed_absolute_git_paths_and_preserves_failures() {
  local repo hook trace stub_bin real_git point output status

  repo=$(new_repo runtime-absolute-path-capability)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' existing-hook >>"$TRACE"
EOF
  chmod 751 "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  write_recording_handler "$repo/.githooks/managed-handler"
  trace="$repo/runtime-capability-trace"
  stub_bin="$repo/git-bin"
  real_git=$(command -v git)
  mkdir "$stub_bin"
  write_absolute_path_git_stub "$stub_bin/git"

  for point in git-dir toplevel; do
    rm -f "$trace"
    set +e
    output=$(
      cd "$repo"
      PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GIT="$real_git" \
        GIT_ABSOLUTE_PATH_MALFORMED_POINT="$point" TRACE="$trace" \
        "$hook" 2>&1
    )
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "runtime accepted malformed absolute $point output"
    case "$output" in *'Git 2.31'*'absolute path'*) ;;
      *) fail "runtime malformed $point output had no capability diagnostic" ;;
    esac
    [ ! -s "$trace" ] || fail "runtime malformed $point output executed hook content"
  done

  rm -f "$trace"
  set +e
  output=$(
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GIT="$real_git" \
      GIT_ABSOLUTE_PATH_FAILURE_POINT=git-dir TRACE="$trace" "$hook" 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 73 ] || fail "runtime Git-directory failure exited $status instead of 73"
  case "$output" in *'unable to resolve the current Git directory'*) ;;
    *) fail 'runtime Git-directory failure lost its prefixed diagnostic' ;;
  esac
  case "$output" in *'injected runtime'*) fail 'runtime exposed suppressed Git stderr' ;; esac
  [ ! -s "$trace" ] || fail 'runtime Git-directory failure executed hook content'
}

test_repository_and_runtime_paths_may_contain_newlines() {
  local platform repo hook trace expected

  platform=$(uname -s)
  case "$platform" in
    MINGW*|MSYS*|CYGWIN*)
      printf '%s\n' 'SKIP: Windows paths cannot contain newlines'
      return 0
      ;;
  esac

  repo=$(new_repo "$(printf 'repository\nwith-newline')")
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  write_recording_handler "$repo/.githooks/newline-path-handler"
  hook="$repo/.git/hooks/pre-commit"
  trace="$repo/newline-path-trace"
  (
    cd "$repo"
    TRACE="$trace" "$hook"
  )
  expected="$repo/newline-path-expected"
  printf '%s\n' 'newline-path-handler<pre-commit>' >"$expected"
  assert_files_equal "$expected" "$trace"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  [ ! -e "$hook" ] || fail 'newline-path uninstall left a generated hook'
}

test_uninstall_transaction_rolls_back_a_replacement_time_signal() {
  local repo hook installed original_mode other_hook stub_bin real_mv status
  repo=$(new_repo uninstall-signal-transaction)
  hook="$repo/.git/hooks/applypatch-msg"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' original-applypatch
EOF
  chmod 751 "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  installed="$repo/installed-applypatch"
  cp -p "$hook" "$installed"
  original_mode=$(file_mode "$installed")
  other_hook="$repo/.git/hooks/commit-msg"
  [ -f "$other_hook" ] || fail 'uninstall transaction fixture has no generated hook'

  stub_bin="$repo/mv-bin"
  mkdir -p "$stub_bin"
  real_mv=$(command -v mv)
  cat >"$stub_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
last_name=${last##*/}
"$REAL_MV" "$@" || exit $?
[ "$last_name" != "$TARGET_HOOK_NAME" ] || [ -e "$SIGNAL_ONCE_FILE" ] || {
  : >"$SIGNAL_ONCE_FILE"
  kill -TERM "$PPID"
}
EOF
  chmod +x "$stub_bin/mv"

  set +e
  (
    cd "$repo"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_MV="$real_mv" TARGET_HOOK_NAME=applypatch-msg \
      SIGNAL_ONCE_FILE="$repo/uninstall-signalled" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'uninstall ignored a replacement-time signal'
  assert_files_equal "$installed" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] || fail 'uninstall signal rollback changed hook mode'
  grep -q 'git-hook-pure start' "$other_hook" || fail 'uninstall signal rollback lost another managed hook'
}

test_linked_worktree_uses_common_hooks_and_current_worktree_handlers() {
  local main linked hook trace private_git_dir
  main=$(new_repo worktree-main)
  linked="$suite_tmp/linked worktree"
  printf 'tracked\n' >"$main/tracked"
  git -C "$main" add tracked
  git -C "$main" commit -qm initial
  git -C "$main" worktree add -q -b linked-test "$linked"

  (
    cd "$linked"
    HOME="$linked/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  hook=$(git -C "$linked" rev-parse --path-format=absolute --git-path hooks)/commit-msg
  [ -x "$hook" ] || fail 'install did not write the common worktree hooks directory'
  write_recording_handler "$main/.githooks/commit-msg/main-handler"
  write_recording_handler "$linked/.githooks/commit-msg/linked-handler"

  trace="$suite_tmp/worktree-trace"
  (
    cd "$main"
    TRACE="$trace" "$hook" main-message
  )
  (
    cd "$linked"
    TRACE="$trace" "$hook" linked-message
  )

  hook=$(git -C "$linked" rev-parse --path-format=absolute --git-path hooks)/pre-receive
  private_git_dir=$(git -C "$linked" rev-parse --path-format=absolute --git-dir)
  write_recording_handler "$linked/.githooks/pre-receive/linked-server-handler"
  (
    cd "$private_git_dir"
    GIT_DIR=. TRACE="$trace" "$hook"
  )

  cat >"$suite_tmp/worktree-expected" <<'EOF'
main-handler<main-message>
linked-handler<linked-message>
linked-server-handler
EOF
  assert_files_equal "$suite_tmp/worktree-expected" "$trace"

  (
    cd "$linked"
    HOME="$linked/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  [ ! -e "$hook" ] || fail 'worktree uninstall left its generated common hook behind'
}

test_linked_worktree_receive_hook_fails_closed_when_mapping_cannot_be_read() {
  local main linked source handler stub_bin status ref_status private_git_dir

  main=$(new_repo linked-receive-main)
  linked="$suite_tmp/linked receive target"
  printf '%s\n' tracked >"$main/tracked"
  git -C "$main" add tracked
  git -C "$main" commit -qm initial
  git -C "$main" worktree add -q -b linked-receive "$linked"
  (
    cd "$linked"
    HOME="$linked/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  handler="$linked/.githooks/pre-receive/block-policy"
  mkdir -p "$(dirname -- "$handler")"
  cat >"$handler" <<'EOF'
#!/bin/sh
exit 73
EOF
  chmod +x "$handler"

  source=$(new_repo linked-receive-source)
  printf '%s\n' source >"$source/source"
  git -C "$source" add source
  git -C "$source" commit -qm source

  set +e
  git -C "$source" push -q "$linked" HEAD:refs/heads/policy-baseline >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'linked worktree receive policy did not reject the baseline push'

  stub_bin="$source/stub-bin"
  mkdir "$stub_bin"
  cat >"$stub_bin/sed" <<'EOF'
#!/bin/sh
exit 70
EOF
  chmod +x "$stub_bin/sed"
  set +e
  PATH="$(path_for_path_env "$stub_bin"):$PATH" \
    git -C "$source" push -q "$linked" HEAD:refs/heads/policy-fault >/dev/null 2>&1
  status=$?
  git -C "$main" rev-parse --verify refs/heads/policy-fault >/dev/null 2>&1
  ref_status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'linked worktree mapping failure bypassed the receive policy'
  [ "$ref_status" -ne 0 ] || fail 'linked worktree mapping failure created the protected ref'

  rm -f "$stub_bin/sed"
  cat >"$stub_bin/dirname" <<'EOF'
#!/bin/sh
exit 70
EOF
  chmod +x "$stub_bin/dirname"
  set +e
  PATH="$(path_for_path_env "$stub_bin"):$PATH" \
    git -C "$source" push -q "$linked" HEAD:refs/heads/policy-dirname-fault >/dev/null 2>&1
  status=$?
  git -C "$main" rev-parse --verify refs/heads/policy-dirname-fault >/dev/null 2>&1
  ref_status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'linked worktree dirname failure bypassed the receive policy'
  [ "$ref_status" -ne 0 ] || fail 'linked worktree dirname failure created the protected ref'

  rm -f "$stub_bin/dirname"
  private_git_dir=$(git -C "$linked" rev-parse --path-format=absolute --git-dir)
  printf '%s\n' "$suite_tmp/nonexistent-worktree/.git" >"$private_git_dir/gitdir"
  set +e
  git -C "$source" push -q "$linked" HEAD:refs/heads/policy-corrupt-map >/dev/null 2>&1
  status=$?
  git -C "$main" rev-parse --verify refs/heads/policy-corrupt-map >/dev/null 2>&1
  ref_status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'invalid linked worktree reverse mapping bypassed the receive policy'
  [ "$ref_status" -ne 0 ] || fail 'invalid linked worktree reverse mapping created the protected ref'
}

test_monorepo_subdirectory_installs_at_repository_root() {
  local repo nested hook trace
  repo=$(new_repo monorepo)
  nested="$repo/packages/example/app"
  mkdir -p "$nested"

  (
    cd "$nested"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  [ -d "$repo/.githooks" ] || fail 'nested install did not create root .githooks'
  [ ! -e "$nested/.githooks" ] || fail 'nested install created a package-local .githooks'
  hook=$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks)/pre-commit
  [ -x "$hook" ] || fail 'nested install did not use repository hooks'
  write_recording_handler "$repo/.githooks/pre-commit/root-handler"
  trace="$repo/trace"
  (
    cd "$nested"
    TRACE="$trace" "$hook"
  )
  printf '%s\n' 'root-handler' >"$repo/expected"
  assert_files_equal "$repo/expected" "$trace"
}

test_submodule_uses_its_git_hooks_and_its_own_handlers() {
  local source super submodule hook trace submodule_git_dir
  source=$(new_repo submodule-source)
  printf 'source\n' >"$source/source-file"
  git -C "$source" add source-file
  git -C "$source" commit -qm initial

  super=$(new_repo superproject)
  printf 'super\n' >"$super/super-file"
  git -C "$super" add super-file
  git -C "$super" commit -qm initial
  git -C "$super" -c protocol.file.allow=always submodule add -q "$source" modules/child
  submodule="$super/modules/child"

  (
    cd "$submodule"
    HOME="$super/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  hook=$(git -C "$submodule" rev-parse --path-format=absolute --git-path hooks)/commit-msg
  [ -x "$hook" ] || fail 'submodule install did not use the modules hooks directory'
  [ ! -e "$submodule/.git/hooks" ] || fail 'submodule install treated the .git file as a directory'
  write_recording_handler "$submodule/.githooks/commit-msg/submodule-handler"
  trace="$super/submodule-trace"
  (
    cd "$submodule"
    TRACE="$trace" "$hook" submodule-message
  )
  hook=$(git -C "$submodule" rev-parse --path-format=absolute --git-path hooks)/pre-receive
  submodule_git_dir=$(git -C "$submodule" rev-parse --path-format=absolute --git-dir)
  write_recording_handler "$submodule/.githooks/pre-receive/submodule-server-handler"
  (
    cd "$submodule_git_dir"
    GIT_DIR=. TRACE="$trace" "$hook"
  )
  cat >"$super/submodule-expected" <<'EOF'
submodule-handler<submodule-message>
submodule-server-handler
EOF
  assert_files_equal "$super/submodule-expected" "$trace"
}

test_install_preflights_every_target_before_mutation() {
  local repo hook original output status
  repo=$(new_repo preflight-githooks)
  printf 'occupied\n' >"$repo/.githooks"

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install accepted .githooks as a file'
  case "$output" in
    *.githooks*) ;;
    *) fail 'preflight failure did not identify .githooks' ;;
  esac
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail '.githooks preflight failure left managed hook content'
  fi

  repo=$(new_repo preflight-existing-hook)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/usr/bin/env python3
print('existing Python hook')
EOF
  chmod +x "$hook"
  original="$repo/original-python-hook"
  cp -p "$hook" "$original"

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install accepted an incompatible existing hook'
  case "$output" in
    *pre-commit*) ;;
    *) fail 'hook preflight failure did not identify pre-commit' ;;
  esac
  assert_files_equal "$original" "$hook"
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'hook preflight failure modified a different hook'
  fi
}

test_install_refuses_an_unowned_blank_hook_without_mutation() {
  local repo hook original output status
  repo=$(new_repo blank-existing-hook)
  hook="$repo/.git/hooks/pre-commit"
  printf ' \n\t\n' >"$hook"
  chmod 640 "$hook"
  original="$repo/original-blank-hook"
  cp -p "$hook" "$original"

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install claimed ownership of an existing blank hook'
  case "$output" in *'blank hook'*) ;; *) fail 'blank hook failure had no actionable diagnostic' ;; esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || fail 'blank hook refusal changed its mode'
  [ ! -e "$repo/.githooks" ] || fail 'blank hook refusal created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'blank hook refusal mutated another hook'
  fi
}

test_install_refuses_an_unowned_generated_marker_without_mutation() {
  local repo hook original output status
  repo=$(new_repo generated-marker-collision)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
# git-hook-pure generated hook
printf '%s\n' user-hook
EOF
  chmod 751 "$hook"
  original="$repo/original-marker-hook"
  cp -p "$hook" "$original"

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install accepted an unowned generated marker'
  case "$output" in *'generated marker'*) ;; *) fail 'marker collision had no actionable diagnostic' ;; esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || fail 'marker refusal changed hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'marker refusal created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'marker refusal mutated another hook'
  fi
}

test_install_refuses_unknown_balanced_markers_without_mutation() {
  local repo hook original previous output status command bytes previous_oid
  repo=$(new_repo balanced-marker-collision)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
cat <<'PAYLOAD' >>"$TRACE"
# ================== git-hook-pure start ==================
user-owned marker payload
# ================== git-hook-pure end ==================
PAYLOAD
EOF
  chmod 751 "$hook"
  original="$repo/original-marker-payload"
  cp -p "$hook" "$original"

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install claimed an unknown balanced marker block'
  case "$output" in *'marker'*) ;; *) fail 'balanced marker collision had no actionable diagnostic' ;; esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
    fail 'balanced marker refusal changed the original hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'balanced marker refusal created .githooks'

  repo=$(new_repo near-v4-marker-collision)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
# ================== git-hook-pure start ==================
# git-hook-pure managed format: v4
user-owned payload is not v4 state metadata
# ================== git-hook-pure end ==================
EOF
  chmod 751 "$hook"
  original="$repo/original-near-v4"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed a signature-only near-v4 block"
    case "$output" in *'marker'*) ;; *) fail "$command near-v4 refusal had no marker diagnostic" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$command near-v4 refusal changed the hook mode"
  done
  [ ! -e "$repo/.githooks" ] || fail 'near-v4 refusal created .githooks'

  repo=$(new_repo contradictory-v4-metadata)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
# ================== git-hook-pure start ==================
# git-hook-pure managed format: v4
# git-hook-pure state: generated
# git-hook-pure original shebang newline: missing
__git_hook_pure_managed_v4() {
return 0
}
# ================== git-hook-pure end ==================
EOF
  chmod 751 "$hook"
  original="$repo/original-contradictory-v4"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed contradictory v4 metadata"
    case "$output" in *'marker'*) ;; *) fail "$command contradictory-v4 refusal had no marker diagnostic" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$command contradictory-v4 refusal changed the hook mode"
  done
  [ ! -e "$repo/.githooks" ] || fail 'contradictory-v4 refusal created .githooks'

  repo=$(new_repo incomplete-v4-wrapper-collision)
  hook="$repo/.git/hooks/pre-commit"
  cat >"$hook" <<'EOF'
#!/bin/sh
cat <<'PAYLOAD' >>"$TRACE"
# ================== git-hook-pure start ==================
# git-hook-pure managed format: v4
# git-hook-pure state: generated
__git_hook_pure_managed_v4() {
user-owned payload is not the fixed managed wrapper
# ================== git-hook-pure end ==================
PAYLOAD
EOF
  chmod 751 "$hook"
  original="$repo/original-incomplete-v4-wrapper"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed an incomplete v4 wrapper"
    case "$output" in *'marker'*) ;; *) fail "$command incomplete-v4 refusal had no marker diagnostic" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$command incomplete-v4 refusal changed the hook mode"
  done
  [ ! -e "$repo/.githooks" ] || fail 'incomplete-v4 refusal created .githooks'

  repo=$(new_repo noncanonical-v4-banners)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  sed \
    -e 's/^# ================== git-hook-pure start ==================$/# == git-hook-pure start ==/' \
    -e 's/^# ================== git-hook-pure end ==================$/# == git-hook-pure end ==/' \
    "$hook" >"$hook.near"
  mv "$hook.near" "$hook"
  chmod 751 "$hook"
  original="$repo/original-noncanonical-v4"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed noncanonical v4 banners"
    case "$output" in *'marker'*) ;; *) fail "$command noncanonical-v4 refusal had no marker diagnostic" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$command noncanonical-v4 refusal changed the hook mode"
  done

  repo=$(new_repo tampered-v4-dispatcher)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  sed \
    's|^hookFolderPath=$projectRoot/.githooks$|hookFolderPath=$projectRoot/.other-hooks|' \
    "$hook" >"$hook.near"
  mv "$hook.near" "$hook"
  chmod 751 "$hook"
  original="$repo/original-tampered-v4-dispatcher"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed a tampered v4 dispatcher"
    case "$output" in *'marker'*) ;;
      *) fail "$command tampered-v4 refusal had no marker diagnostic" ;;
    esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] ||
      fail "$command tampered-v4 refusal changed the hook mode"
  done

  repo=$(new_repo tampered-v4-state)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  sed \
    's/^# git-hook-pure state: generated$/# git-hook-pure state: existing/' \
    "$hook" >"$hook.tampered"
  mv "$hook.tampered" "$hook"
  chmod 751 "$hook"
  original="$repo/original-tampered-v4-state"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed changed v4 state metadata"
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] ||
      fail "$command changed the mode of changed v4 state metadata"
  done

  repo=$(new_repo previous-v4-dispatcher)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  original="$repo/current-v4-dispatcher"
  cp -p "$hook" "$original"
  previous="$repo/previous-v4-dispatcher"
  cat >"$repo/previous-v4-content" <<'EOF'
# git-hook-pure state: generated
previous_git_hook_pure_wrapper() {
  :
}
previous_git_hook_pure_wrapper "$@" || exit $?
unset -f previous_git_hook_pure_wrapper
# ================== git-hook-pure end ==================
EOF
  previous_oid=$(git -C "$repo" hash-object --stdin <"$repo/previous-v4-content")
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# ================== git-hook-pure start =================='
    printf '%s\n' '# git-hook-pure managed format: v4'
    printf '# git-hook-pure content oid: %s\n' "$previous_oid"
    cat "$repo/previous-v4-content"
  } >"$previous"
  rm -f "$repo/previous-v4-content"
  chmod 751 "$previous"
  cp -p "$previous" "$hook"

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] ||
    fail 'install changed the mode while upgrading a complete previous v4 dispatcher'

  cp -p "$previous" "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  [ ! -e "$hook" ] || fail 'uninstall did not recognize a complete previous v4 dispatcher'

  repo=$(new_repo truncated-v4-content)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  bytes=$(wc -c <"$hook" | tr -d '[:space:]')
  dd if="$hook" of="$hook.truncated" bs=1 count=$((bytes - 1)) 2>/dev/null
  mv "$hook.truncated" "$hook"
  chmod 751 "$hook"
  original="$repo/original-truncated-v4"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed a v4 block without its final newline"
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] ||
      fail "$command changed the mode of a v4 block without its final newline"
  done

  repo=$(new_repo near-v3-marker-collision)
  hook="$repo/.git/hooks/pre-commit"
  write_v3_default_hook "$hook" shift
  awk '
    /^# ================== git-hook-pure end ==================$/ {
      print "user-owned payload makes this different from the historical v3 block"
    }
    { print }
  ' "$hook" >"$hook.near"
  mv "$hook.near" "$hook"
  chmod 751 "$hook"
  original="$repo/original-near-v3"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed a near-v3 block with extra payload"
    case "$output" in *'marker'*) ;; *) fail "$command near-v3 refusal had no marker diagnostic" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$command near-v3 refusal changed the hook mode"
  done
  [ ! -e "$repo/.githooks" ] || fail 'near-v3 refusal created .githooks'

  repo=$(new_repo truncated-v3-marker-collision)
  hook="$repo/.git/hooks/pre-commit"
  write_v3_default_hook "$hook" shift
  bytes=$(wc -c <"$hook" | tr -d '[:space:]')
  dd if="$hook" of="$hook.near" bs=1 count=$((bytes - 1)) 2>/dev/null
  mv "$hook.near" "$hook"
  chmod 751 "$hook"
  original="$repo/original-truncated-v3"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed a truncated historical v3 block"
    case "$output" in *'marker'*) ;; *) fail "$command truncated-v3 refusal had no marker diagnostic" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$command truncated-v3 refusal changed the hook mode"
  done
  [ ! -e "$repo/.githooks" ] || fail 'truncated-v3 refusal created .githooks'

  repo=$(new_repo incomplete-v3-generated-envelope)
  hook="$repo/.git/hooks/pre-commit"
  write_v3_default_hook "$hook" shift
  dd if="$hook" of="$hook.near" bs=1 skip=1 2>/dev/null
  mv "$hook.near" "$hook"
  chmod 751 "$hook"
  original="$repo/original-incomplete-v3-envelope"
  cp -p "$hook" "$original"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command claimed an incomplete v3 generated envelope"
    case "$output" in *'marker'*) ;; *) fail "$command incomplete-v3 refusal had no marker diagnostic" ;; esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$command incomplete-v3 refusal changed the hook mode"
  done
}

test_uninstall_preserves_user_content_added_to_a_generated_hook() {
  local repo hook expected
  repo=$(new_repo generated-hook-user-content)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  printf '%s\n' '# git-hook-pure generated hook' >>"$hook"
  expected="$repo/expected-user-content"
  printf '%s\n%s\n' '#!/bin/sh' '# git-hook-pure generated hook' >"$expected"

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  assert_files_equal "$expected" "$hook"
  [ -x "$hook" ] || fail 'uninstall changed the preserved user hook mode'
}

test_existing_hook_without_final_newline_round_trips_exactly() {
  local repo hook original installed tampered expected output status command
  repo=$(new_repo no-final-newline)
  hook="$repo/.git/hooks/pre-commit"
  printf '#!/bin/sh' >"$hook"
  chmod 751 "$hook"
  original="$repo/original-no-final-newline"
  cp -p "$hook" "$original"

  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  installed="$repo/installed-no-final-newline"
  cp -p "$hook" "$installed"
  sed \
    '/^# git-hook-pure original shebang newline: missing$/d' \
    "$hook" >"$hook.tampered"
  mv "$hook.tampered" "$hook"
  chmod 751 "$hook"
  tampered="$repo/tampered-no-final-newline-metadata"
  cp -p "$hook" "$tampered"
  for command in install uninstall; do
    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" "$command" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$command accepted changed original-newline metadata"
    case "$output" in *'marker'*) ;;
      *) fail "$command changed original-newline metadata had no marker diagnostic" ;;
    esac
    assert_files_equal "$tampered" "$hook"
  done
  cp -p "$installed" "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  assert_files_equal "$installed" "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )

  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
    fail 'no-final-newline round trip changed the original hook mode'

  repo=$(new_repo no-final-newline-with-user-content)
  hook="$repo/.git/hooks/pre-commit"
  printf '#!/bin/sh' >"$hook"
  chmod 751 "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  printf '%s\n' 'printf user-added-content' >>"$hook"
  expected="$repo/expected-user-content-after-missing-newline"
  printf '%s\n%s\n' '#!/bin/sh' 'printf user-added-content' >"$expected"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  assert_files_equal "$expected" "$hook"

  repo=$(new_repo body-without-final-newline)
  hook="$repo/.git/hooks/pre-commit"
  printf '#!/bin/sh\nprintf body-without-newline' >"$hook"
  chmod 751 "$hook"
  original="$repo/original-body-without-final-newline"
  cp -p "$hook" "$original"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  installed="$repo/installed-body-without-final-newline"
  cp -p "$hook" "$installed"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  assert_files_equal "$installed" "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
    fail 'body-without-final-newline round trip changed the original hook mode'

  repo=$(new_repo shebang-with-final-newline)
  hook="$repo/.git/hooks/pre-commit"
  printf '#!/bin/sh\n' >"$hook"
  chmod 751 "$hook"
  original="$repo/original-shebang-with-final-newline"
  cp -p "$hook" "$original"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  installed="$repo/installed-shebang-with-final-newline"
  cp -p "$hook" "$installed"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  assert_files_equal "$installed" "$hook"
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
    fail 'single-line final-newline round trip changed the original hook mode'
}

test_legacy_existing_hooks_round_trip_exactly() {
  local ending repo hook original block

  for ending in newline none; do
    repo=$(new_repo "legacy-existing-$ending")
    hook="$repo/.git/hooks/pre-commit"
    if [ "$ending" = newline ]; then
      printf '%s\n%s\n' '#!/usr/bin/env bash' 'printf old-body' >"$hook"
    else
      printf '%s\n%s' '#!/usr/bin/env bash' 'printf old-body' >"$hook"
    fi
    chmod 751 "$hook"
    original="$repo/original-existing"
    cp -p "$hook" "$original"

    printf '\n' >>"$hook"
    block="$repo/v3-default-block"
    write_v3_default_hook "$block" shift
    sed -n '3,$p' "$block" >>"$hook"

    (
      cd "$repo"
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$git_hook_pure" install >/dev/null
    )
    (
      cd "$repo"
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$git_hook_pure" uninstall >/dev/null
    )
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] || \
      fail "$ending legacy-existing round trip changed the original hook mode"
  done
}

test_install_does_not_trust_cleanup_paths_from_the_environment() {
  local repo victim output status
  repo=$(new_repo cleanup-environment)
  printf '%s\n' occupied >"$repo/.githooks"
  victim="$suite_tmp/environment-owned-victim"
  mkdir -p "$victim"
  printf '%s\n' keep-me >"$victim/sentinel"

  set +e
  output=$(
    cd "$repo"
    git_hook_pure_preflight_dir="$victim" \
      git_hook_pure_transaction_dir="$victim" \
      git_hook_pure_transaction_active=true \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'environment cleanup fixture unexpectedly installed'
  [ -f "$victim/sentinel" ] || fail 'install deleted an environment-controlled cleanup path'
  case "$output" in *.githooks*) ;; *) fail 'environment cleanup refusal lost its root diagnostic' ;; esac
}

test_install_refuses_nonregular_hooks_without_blocking() {
  local repo hook output_file status_file pid status attempt
  repo=$(new_repo fifo-existing-hook)
  hook="$repo/.git/hooks/pre-commit"
  rm -f "$hook"
  if ! mkfifo "$hook" 2>/dev/null; then
    printf '%s\n' 'SKIP: filesystem FIFOs are unavailable'
    return 0
  fi
  chmod 755 "$hook"
  output_file="$repo/install-output"
  status_file="$repo/install-status"

  (
    set +e
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >"$output_file" 2>&1
    printf '%s\n' "$?" >"$status_file"
  ) &
  pid=$!
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -f "$status_file" ] && break
    sleep 0.05
  done
  if [ ! -f "$status_file" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail 'install blocked while reading a FIFO hook'
  fi
  wait "$pid"
  IFS= read -r status <"$status_file"
  [ "$status" -ne 0 ] || fail 'install accepted a FIFO hook'
  grep -q 'regular file' "$output_file" || fail 'FIFO hook refusal had no actionable diagnostic'
  [ -p "$hook" ] || fail 'FIFO hook refusal replaced its target'
  [ ! -e "$repo/.githooks" ] || fail 'FIFO hook refusal created .githooks'
}

test_help_version_and_explicit_commands_are_independent_of_npm_skip() {
  local outside repo hook output status
  outside="$suite_tmp/not-a-repository"
  mkdir -p "$outside"

  (
    cd "$outside"
    "$git_hook_pure" --help >/dev/null
    [ "$("$git_hook_pure" --version)" = "$package_version" ] ||
      fail 'CLI version does not match package.json'
  )
  set +e
  output=$(cd "$outside" && "$git_hook_pure" unknown 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "unknown command exited $status instead of 2"
  case "$output" in *unknown*) ;; *) fail 'unknown command had no diagnostic' ;; esac

  repo=$(new_repo explicit-install-with-npm-skip)
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_HOOK_PURE_SKIP_INSTALL=1 "$git_hook_pure" install >/dev/null
  )
  hook="$repo/.git/hooks/pre-commit"
  grep -q 'git-hook-pure start' "$hook" ||
    fail 'npm automatic-install skip control disabled explicit install'
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_HOOK_PURE_SKIP_INSTALL=1 "$git_hook_pure" uninstall >/dev/null
  )
  [ ! -e "$hook" ] || fail 'npm automatic-install skip control disabled explicit uninstall'
}

test_install_rejects_extra_arguments_before_mutation() {
  local repo hook original original_mode argument output status
  repo=$(new_repo install-extra-argument)
  hook="$repo/.git/hooks/pre-commit"
  original="$repo/original-pre-commit"
  argument="$repo/unexpected-argument"
  cat >"$hook" <<'EOF'
#!/bin/sh
printf '%s\n' existing-hook
EOF
  chmod 751 "$hook"
  cp "$hook" "$original"
  original_mode=$(file_mode "$hook")
  cat >"$argument" <<'EOF'
#!/bin/sh
:
EOF

  set +e
  output=$(
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install "$argument" 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "install with an extra argument exited $status instead of 2"
  case "$output" in *'Usage:'*) ;;
    *) fail 'install extra-argument refusal did not print usage' ;;
  esac
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$original_mode" ] ||
    fail 'install extra-argument refusal changed the existing hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'install extra-argument refusal created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'install extra-argument refusal wrote managed hook content'
  fi
}

test_version_and_help_reject_extra_arguments_on_stderr() {
  local outside command stdout stderr status help_output

  outside="$suite_tmp/cli-extra-arguments"
  mkdir "$outside"
  for command in version --version help -h --help; do
    stdout="$outside/$command.stdout"
    stderr="$outside/$command.stderr"
    set +e
    (
      cd "$outside"
      "$git_hook_pure" "$command" unexpected >"$stdout" 2>"$stderr"
    )
    status=$?
    set -e

    [ "$status" -eq 2 ] || fail "$command extra argument exited $status instead of 2"
    [ ! -s "$stdout" ] || fail "$command extra argument wrote to stdout"
    grep -q 'Usage:' "$stderr" || fail "$command extra argument omitted Usage on stderr"
  done

  help_output="$outside/help-output"
  (
    cd "$outside"
    "$git_hook_pure" --help >"$help_output"
  )
  grep -Fq 'help, -h, --help' "$help_output" || fail 'help output omits a supported help alias'
}

test_existing_hooks_require_a_compatible_shell_shebang() {
  local repo hook original original_mode shebang output status

  for shebang in '#!/usr/bin/env sh' '#!/usr/bin/env -S sh -eu'; do
    repo=$(new_repo "compatible-shell-$(printf '%s' "$shebang" | tr -cd '[:alnum:]' | tail -c 20)")
    hook="$repo/.git/hooks/pre-commit"
    printf '%s\n%s\n' "$shebang" ':' >"$hook"
    chmod 751 "$hook"
    original="$repo/original-pre-commit"
    cp -p "$hook" "$original"
    (
      cd "$repo"
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$git_hook_pure" install >/dev/null
      "$hook"
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$git_hook_pure" uninstall >/dev/null
    )
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] ||
      fail "compatible existing hook mode changed for $shebang"
  done

  for shebang in '#!/usr/bin/env node sh' '#!/usr/bin/env -S python3 -X sh' '#!/bin/sh -c'; do
    repo=$(new_repo "incompatible-shell-$(printf '%s' "$shebang" | tr -cd '[:alnum:]' | tail -c 20)")
    hook="$repo/.git/hooks/pre-commit"
    printf '%s\n%s\n' "$shebang" ':' >"$hook"
    chmod 751 "$hook"
    original="$repo/original-pre-commit"
    cp -p "$hook" "$original"
    original_mode=$(file_mode "$hook")

    set +e
    output=$(cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "install accepted an incompatible shell shebang: $shebang"
    case "$output" in *'compatible shell'*) ;;
      *) fail "incompatible shell refusal had no actionable diagnostic: $shebang" ;;
    esac
    assert_files_equal "$original" "$hook"
    [ "$(file_mode "$hook")" = "$original_mode" ] ||
      fail "incompatible shell refusal changed the hook mode: $shebang"
    [ ! -e "$repo/.githooks" ] || fail "incompatible shell refusal created .githooks: $shebang"
    if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
      fail "incompatible shell refusal wrote managed hook content: $shebang"
    fi
  done
}

test_receive_hook_resolves_non_bare_repository_root() {
  local target source trace
  target=$(new_repo receive-target)
  printf 'target\n' >"$target/target-file"
  git -C "$target" add target-file
  git -C "$target" commit -qm initial
  (
    cd "$target"
    HOME="$target/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  write_recording_handler "$target/.githooks/pre-receive/server-handler"

  source=$(new_repo receive-source)
  printf 'source\n' >"$source/source-file"
  git -C "$source" add source-file
  git -C "$source" commit -qm initial
  trace="$target/receive-trace"
  TRACE="$trace" git -C "$source" push -q "$target" HEAD:refs/heads/incoming >/dev/null 2>&1
  printf '%s\n' server-handler >"$target/receive-expected"
  assert_files_equal "$target/receive-expected" "$trace"
}

test_receive_hook_replays_stdin_to_every_handler_and_existing_policy() {
  local target source hook trace status handler ref_exists
  target=$(new_repo receive-stdin-target)
  printf 'target\n' >"$target/target-file"
  git -C "$target" add target-file
  git -C "$target" commit -qm initial
  hook="$target/.git/hooks/pre-receive"
  cat >"$hook" <<'EOF'
#!/bin/sh
cat >"${TRACE}.existing"
if [ -s "${TRACE}.existing" ]; then
  exit 23
fi
exit 0
EOF
  chmod +x "$hook"
  (
    cd "$target"
    HOME="$target/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  for handler in universal-a universal-b; do
    mkdir -p "$target/.githooks"
    cat >"$target/.githooks/$handler" <<'EOF'
#!/bin/sh
cat >"${TRACE}.$(basename "$0")"
EOF
    chmod +x "$target/.githooks/$handler"
  done
  for handler in specific-a specific-b; do
    mkdir -p "$target/.githooks/pre-receive"
    cat >"$target/.githooks/pre-receive/$handler" <<'EOF'
#!/bin/sh
cat >"${TRACE}.$(basename "$0")"
EOF
    chmod +x "$target/.githooks/pre-receive/$handler"
  done

  source=$(new_repo receive-stdin-source)
  printf 'source\n' >"$source/source-file"
  git -C "$source" add source-file
  git -C "$source" commit -qm initial
  trace="$target/receive-input"
  set +e
  TRACE="$trace" git -C "$source" push -q "$target" HEAD:refs/heads/incoming >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'managed stdin consumption bypassed the existing receive policy'

  [ -s "$trace.universal-a" ] || fail 'first universal receive handler got empty stdin'
  for handler in universal-b specific-a specific-b existing; do
    assert_files_equal "$trace.universal-a" "$trace.$handler"
  done
  set +e
  git -C "$target" rev-parse --verify refs/heads/incoming >/dev/null 2>&1
  ref_exists=$?
  set -e
  [ "$ref_exists" -ne 0 ] || fail 'existing receive policy rejection did not protect the ref'
}

test_replayable_hooks_copy_exact_stdin_to_every_consumer() {
  local repo trace tmp payload empty hook handler output expected payload_output empty_output
  repo=$(new_repo 'replay hooks')
  trace="$repo/trace with spaces"
  tmp="$repo/tmp with spaces"
  mkdir -p "$trace" "$tmp"

  for hook in pre-push pre-receive post-receive post-rewrite; do
    cat >"$repo/.git/hooks/$hook" <<'EOF'
#!/bin/sh
cat >"$TRACE/${0##*/}.existing"
printf '%s' existing
for argument do
  printf '<%s>' "$argument"
done
printf '\n'
EOF
    chmod +x "$repo/.git/hooks/$hook"
  done
  (
    cd "$repo"
    HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )

  for handler in 'universal a' 'universal b'; do
    cat >"$repo/.githooks/$handler" <<'EOF'
#!/bin/sh
hook_name=$1
cat >"$TRACE/$hook_name.${0##*/}"
printf '%s' "${0##*/}"
for argument do
  printf '<%s>' "$argument"
done
printf '\n'
EOF
    chmod +x "$repo/.githooks/$handler"
  done
  for hook in pre-push pre-receive post-receive post-rewrite; do
    mkdir -p "$repo/.githooks/$hook"
    for handler in 'specific a' 'specific b'; do
      cat >"$repo/.githooks/$hook/$handler" <<'EOF'
#!/bin/sh
hook_name=$(basename "$(dirname "$0")")
cat >"$TRACE/$hook_name.${0##*/}"
printf '%s' "${0##*/}"
for argument do
  printf '<%s>' "$argument"
done
printf '\n'
EOF
      chmod +x "$repo/.githooks/$hook/$handler"
    done
  done

  payload="$repo/two-line-payload"
  printf 'first line with spaces \\ and tab\tend\nsecond line keeps trailing spaces  \n' >"$payload"
  empty="$repo/empty-payload"
  : >"$empty"

  for hook in pre-push pre-receive post-receive post-rewrite; do
    case "$hook" in
      pre-push) set -- origin example.invalid ;;
      post-rewrite) set -- rebase ;;
      *) set -- ;;
    esac
    expected="$repo/$hook.expected-output"
    payload_output="$repo/$hook.payload-output"
    empty_output="$repo/$hook.empty-output"
    {
      write_argument_trace_line 'universal a' "$hook" "$@"
      write_argument_trace_line 'universal b' "$hook" "$@"
      write_argument_trace_line 'specific a' "$@"
      write_argument_trace_line 'specific b' "$@"
      write_argument_trace_line existing "$@"
    } >"$expected"
    (cd "$repo" && TMPDIR="$tmp" TRACE="$trace" \
      "$repo/.git/hooks/$hook" "$@" <"$payload") >"$payload_output"
    assert_files_equal "$expected" "$payload_output"
    for output in 'universal a' 'universal b' 'specific a' 'specific b' existing; do
      assert_files_equal "$payload" "$trace/$hook.$output"
    done

    (cd "$repo" && TMPDIR="$tmp" TRACE="$trace" \
      "$repo/.git/hooks/$hook" "$@" <"$empty") >"$empty_output"
    assert_files_equal "$expected" "$empty_output"
    for output in 'universal a' 'universal b' 'specific a' 'specific b' existing; do
      [ ! -s "$trace/$hook.$output" ] || fail "$hook did not replay empty stdin to $output"
    done
  done
  [ -z "$(find "$tmp" -name 'git-hook-pure-stdin.*' -print | sed -n '1p')" ] || \
    fail 'stdin replay left a temporary file'
}

test_install_rejects_a_separate_git_directory_before_mutation() {
  local target metadata output status invalid_worktree
  target="$suite_tmp/separate-worktree"
  metadata="$suite_tmp/separate-metadata"
  mkdir -p "$target/home"
  git init -q --separate-git-dir="$metadata" "$target"
  git -C "$target" config user.name 'Git Hook Pure Tests'
  git -C "$target" config user.email 'git-hook-pure@example.invalid'

  set +e
  output=$(
    cd "$target"
    HOME="$target/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install accepted a separate Git directory it cannot dispatch safely'
  case "$output" in
    *'separate Git directory'*) ;;
    *) fail 'separate Git directory failure had no actionable diagnostic' ;;
  esac
  [ ! -e "$target/.githooks" ] || fail 'separate Git directory failure created .githooks'
  if grep -Rqs 'git-hook-pure start' "$metadata/hooks"; then
    fail 'separate Git directory failure mutated hooks'
  fi

  invalid_worktree="$suite_tmp/missing-configured-worktree"
  git --git-dir="$metadata" config core.worktree "$invalid_worktree"
  set +e
  output=$(
    cd "$target"
    HOME="$target/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install accepted a nonexistent configured worktree'
  case "$output" in
    *'configured worktree'*) ;;
    *) fail 'invalid configured worktree failure had no actionable diagnostic' ;;
  esac
  [ ! -e "$target/.githooks" ] || fail 'invalid configured worktree created .githooks'
  if grep -Rqs 'git-hook-pure start' "$metadata/hooks"; then
    fail 'invalid configured worktree mutated hooks'
  fi
}

test_mapped_separate_git_directory_uses_its_configured_worktree() {
  local target metadata hook trace payload stub_bin real_git
  target="$suite_tmp/mapped-separate-worktree"
  metadata="$suite_tmp/mapped-separate-metadata"
  mkdir -p "$target/home"
  git init -q --separate-git-dir="$metadata" "$target"
  git --git-dir="$metadata" config core.worktree "$target"
  git -C "$target" config user.name 'Git Hook Pure Tests'
  git -C "$target" config user.email 'git-hook-pure@example.invalid'

  (
    cd "$target"
    HOME="$target/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install >/dev/null
  )
  write_recording_handler "$target/.githooks/pre-receive/mapped-handler"
  hook="$metadata/hooks/pre-receive"
  trace="$target/mapped-separate-trace"
  payload="$target/mapped-separate-input"
  printf '%s\n' '0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 refs/heads/test' >"$payload"
  (
    cd "$metadata"
    GIT_DIR=. TRACE="$trace" "$hook" <"$payload"
  )
  stub_bin="$target/git-bin"
  mkdir -p "$stub_bin"
  real_git=$(command -v git)
  cat >"$stub_bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = rev-parse ]; then
  for argument do
    [ "$argument" != --show-toplevel ] || exit 70
  done
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$stub_bin/git"
  (
    cd "$metadata"
    PATH="$(path_for_path_env "$stub_bin"):$PATH" REAL_GIT="$real_git" GIT_DIR=. TRACE="$trace" \
      "$hook" <"$payload"
  )
  printf '%s\n%s\n' mapped-handler mapped-handler >"$target/mapped-separate-expected"
  assert_files_equal "$target/mapped-separate-expected" "$trace"

  (
    cd "$target"
    HOME="$target/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" uninstall >/dev/null
  )
  [ ! -e "$hook" ] || fail 'mapped separate Git directory uninstall left a generated hook'
}

test_install_rejects_a_bare_repository_before_mutation() {
  local repo output status
  repo="$suite_tmp/bare-repository.git"
  git init -q --bare "$repo"
  set +e
  output=$(
    cd "$repo"
    HOME="$suite_tmp/bare-home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$git_hook_pure" install 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'install accepted a bare repository without project-owned handlers'
  case "$output" in *'bare repositories'*) ;; *) fail 'bare repository failure had no actionable diagnostic' ;; esac
  if grep -Rqs 'git-hook-pure start' "$repo/hooks"; then
    fail 'bare repository failure mutated hooks'
  fi
}

run_git_hook_pure_integration_tests() {
  run_test test_install_staging_failures_preserve_hooks_and_status
  run_test test_install_fails_if_preexisting_handler_directory_disappears
  run_test test_repository_resolution_rejects_malformed_absolute_git_paths
  run_test test_runtime_rejects_malformed_absolute_git_paths_and_preserves_failures
  run_test test_repository_and_runtime_paths_may_contain_newlines
  run_test test_version_and_help_reject_extra_arguments_on_stderr
  run_test test_dispatch_ignores_hidden_and_directory_entries
  run_test test_dispatch_preserves_every_argument_for_every_handler
  run_test test_dispatch_uses_c_filename_order_without_changing_handler_locale
  run_test test_dispatch_fails_closed_and_preserves_handler_status
  run_test test_install_rejects_extra_arguments_before_mutation
  run_test test_install_is_idempotent_and_uninstall_restores_owned_state
  run_test test_successful_uninstall_preserves_populated_handler_directory
  run_test test_managed_content_identity_uses_the_repository_object_format
  run_test test_install_preserves_update_instead_dirty_worktree_rejection
  run_test test_install_only_manages_composable_hook_protocols
  run_test test_nonreplayable_hooks_fan_out_by_protocol_category
  run_test test_install_transaction_rolls_back_a_replacement_time_signal
  run_test test_install_transaction_preserves_backups_when_rollback_fails
  run_test test_hook_transactions_roll_back_supported_signals
  run_test test_failed_handler_directory_creation_does_not_claim_foreign_state
  run_test test_handler_directory_creation_signal_rolls_back_its_owned_directory
  run_test test_existing_hook_exit_cannot_bypass_managed_handlers
  run_test test_dispatch_does_not_leak_state_into_an_existing_hook
  run_test test_runtime_preserves_caller_environment_for_handlers_and_existing_hook
  run_test test_dispatch_restores_globbing_for_a_noglob_existing_hook
  run_test test_install_migrates_a_legacy_managed_only_hook
  run_test test_install_refuses_core_hooks_path_before_mutation
  run_test test_uninstall_never_follows_a_later_core_hooks_path
  run_test test_uninstall_preflights_every_target_before_mutation
  run_test test_uninstall_symlink_failure_leaves_no_operation_residue
  run_test test_uninstall_staging_failure_reports_and_leaves_no_residue
  run_test test_successful_operations_preserve_pid_reuse_recovery_siblings
  run_test test_operation_cleans_mktemp_output_when_assignment_is_interrupted
  run_test test_install_preserves_grep_errors_in_owned_marker_validation
  run_test test_uninstall_preserves_hook_when_shebang_grep_errors
  run_test test_install_preserves_hook_when_blank_check_grep_errors
  run_test test_repository_resolution_preserves_git_failure_diagnostics
  run_test test_uninstall_transaction_rolls_back_a_replacement_time_signal
  run_test test_linked_worktree_uses_common_hooks_and_current_worktree_handlers
  run_test test_linked_worktree_receive_hook_fails_closed_when_mapping_cannot_be_read
  run_test test_monorepo_subdirectory_installs_at_repository_root
  run_test test_submodule_uses_its_git_hooks_and_its_own_handlers
  run_test test_install_preflights_every_target_before_mutation
  run_test test_install_refuses_an_unowned_blank_hook_without_mutation
  run_test test_install_refuses_an_unowned_generated_marker_without_mutation
  run_test test_install_refuses_unknown_balanced_markers_without_mutation
  run_test test_uninstall_preserves_user_content_added_to_a_generated_hook
  run_test test_existing_hook_without_final_newline_round_trips_exactly
  run_test test_legacy_existing_hooks_round_trip_exactly
  run_test test_install_does_not_trust_cleanup_paths_from_the_environment
  run_test test_install_refuses_nonregular_hooks_without_blocking
  run_test test_help_version_and_explicit_commands_are_independent_of_npm_skip
  run_test test_existing_hooks_require_a_compatible_shell_shebang
  run_test test_receive_hook_resolves_non_bare_repository_root
  run_test test_receive_hook_replays_stdin_to_every_handler_and_existing_policy
  run_test test_replayable_hooks_copy_exact_stdin_to_every_consumer
  run_test test_install_rejects_a_separate_git_directory_before_mutation
  run_test test_mapped_separate_git_directory_uses_its_configured_worktree
  run_test test_install_rejects_a_bare_repository_before_mutation
}
