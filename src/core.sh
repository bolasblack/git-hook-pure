git_hook_pure_embedded_version='@GIT_HOOK_PURE_VERSION@'
git_hook_pure_start_marker='# ================== git-hook-pure start =================='
git_hook_pure_end_marker='# ================== git-hook-pure end =================='
git_hook_pure_managed_signature='# git-hook-pure managed format: v4'
git_hook_pure_generated_state='# git-hook-pure state: generated'
git_hook_pure_existing_state='# git-hook-pure state: existing'
git_hook_pure_no_shebang_newline_marker='# git-hook-pure original shebang newline: missing'
git_hook_pure_content_oid_prefix='# git-hook-pure content oid: '
git_hook_pure_legacy_generated_marker='# git-hook-pure generated hook'
git_hook_pure_hook_names='applypatch-msg
commit-msg
post-applypatch
post-checkout
post-commit
post-index-change
post-merge
post-receive
post-rewrite
post-update
pre-applypatch
pre-auto-gc
pre-commit
pre-merge-commit
pre-push
pre-rebase
pre-receive
prepare-commit-msg
sendemail-validate
update'

git_hook_pure_error() {
  printf '[git-hook-pure] %s\n' "$*" >&2 || :
}

git_hook_pure_report_git_failure() {
  git_hook_pure_error "$1"
  [ -z "$2" ] || printf '%s\n' "$2" >&2 || :
}

git_hook_pure_usage() {
  cat <<'EOF'
Usage: git-hook-pure <command>

Commands:
  install             Install dispatchers into this repository's hooks
  uninstall           Remove dispatchers installed by git-hook-pure
  version, --version  Print the git-hook-pure version
  help, -h, --help    Show this help
EOF
}

git_hook_pure_version() {
  printf '%s\n' "$git_hook_pure_embedded_version"
}

git_hook_pure_is_absolute_path() {
  case "$1" in
    /*|[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:/*) return 0 ;;
    *) return 1 ;;
  esac
}

git_hook_pure_assert_no_hooks_path() {
  local configured status

  if configured=$(git config --includes --show-origin --show-scope --get-all core.hooksPath 2>&1); then
    printf '%s\n' \
      '[git-hook-pure] operation refused: core.hooksPath is configured:' \
      "$configured" >&2
    return 1
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      printf '%s\n' \
        '[git-hook-pure] unable to inspect core.hooksPath:' \
        "$configured" >&2
      return "$status"
    fi
  fi
}

git_hook_pure_resolve_repository() {
  local bare git_dir git_output configured_worktree status local_worktree_configured=false

  git_hook_pure_assert_no_hooks_path || return $?

  if git_output=$(git rev-parse --git-dir 2>&1); then
    :
  else
    status=$?
    git_hook_pure_report_git_failure 'unable to inspect the Git repository' "$git_output"
    return "$status"
  fi

  if bare=$(git rev-parse --is-bare-repository 2>&1); then
    :
  else
    status=$?
    git_hook_pure_report_git_failure \
      'unable to determine whether the repository is bare' "$bare"
    return "$status"
  fi
  if [ "$bare" = true ]; then
    git_hook_pure_error 'bare repositories are not supported because they have no project .githooks directory'
    return 1
  fi

  if git_dir=$(git rev-parse --path-format=absolute --git-dir 2>&1); then
    :
  else
    status=$?
    git_hook_pure_report_git_failure 'unable to resolve the Git directory' "$git_dir"
    return "$status"
  fi
  if ! git_hook_pure_is_absolute_path "$git_dir"; then
    git_hook_pure_error 'Git 2.31 or newer is required: the Git directory did not resolve to an absolute path'
    return 1
  fi
  if configured_worktree=$(git config --local --get core.worktree 2>&1); then
    local_worktree_configured=true
    [ -n "$configured_worktree" ] || {
      git_hook_pure_error 'configured worktree is empty'
      return 1
    }
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      git_hook_pure_report_git_failure \
        'unable to inspect the repository worktree configuration' "$configured_worktree"
      return "$status"
    fi
  fi
  if git_hook_pure_repo_root=$(git rev-parse --path-format=absolute --show-toplevel 2>&1); then
    :
  else
    status=$?
    git_hook_pure_report_git_failure \
      'unable to resolve the worktree root' "$git_hook_pure_repo_root"
    return "$status"
  fi
  if ! git_hook_pure_is_absolute_path "$git_hook_pure_repo_root"; then
    git_hook_pure_error 'Git 2.31 or newer is required: the worktree root did not resolve to an absolute path'
    return 1
  fi
  git_hook_pure_repo_root=$(CDPATH= cd -- "$git_hook_pure_repo_root" 2>/dev/null && pwd) || {
    if [ "$local_worktree_configured" = true ]; then
      git_hook_pure_error "configured worktree is not an accessible directory: $configured_worktree"
    else
      git_hook_pure_error 'resolved worktree root is not an accessible directory'
    fi
    return 1
  }
  if [ -f "$git_hook_pure_repo_root/.git" ] && [ ! -f "$git_dir/commondir" ]; then
    [ "$local_worktree_configured" = true ] || {
      git_hook_pure_error 'a separate Git directory is not supported because receive hooks cannot recover the project worktree'
      return 1
    }
  fi
  if git_hook_pure_hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks 2>&1); then
    :
  else
    status=$?
    git_hook_pure_report_git_failure \
      'unable to resolve the Git hooks directory' "$git_hook_pure_hooks_dir"
    return "$status"
  fi
  if ! git_hook_pure_is_absolute_path "$git_hook_pure_hooks_dir"; then
    git_hook_pure_error 'Git 2.31 or newer is required: the Git hooks directory did not resolve to an absolute path'
    return 1
  fi
  git_hook_pure_handlers_dir=$git_hook_pure_repo_root/.githooks
}

git_hook_pure_reset_operation_state() {
  git_hook_pure_repo_root=
  git_hook_pure_hooks_dir=
  git_hook_pure_handlers_dir=
  git_hook_pure_preflight_dir=
  git_hook_pure_preflight_prefix=
  git_hook_pure_transaction_dir=
  git_hook_pure_transaction_prefix=
  git_hook_pure_transaction_active=false
  git_hook_pure_transaction_handlers_marker=
  git_hook_pure_transaction_handlers_owner_name=
}
