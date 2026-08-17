git_hook_pure_preflight_install() {
  local hook_name hook_path clean state_file parsed_state first_line status

  if [ -L "$git_hook_pure_handlers_dir" ]; then
    git_hook_pure_error ".githooks must not be a symbolic link: $git_hook_pure_handlers_dir"
    return 1
  fi
  if [ -e "$git_hook_pure_handlers_dir" ] && [ ! -d "$git_hook_pure_handlers_dir" ]; then
    git_hook_pure_error ".githooks exists but is not a directory: $git_hook_pure_handlers_dir"
    return 1
  fi

  git_hook_pure_preflight_prefix=$(git_hook_pure_select_operation_prefix \
    "${TMPDIR:-/tmp}/git-hook-pure-preflight.$$") || return $?
  git_hook_pure_preflight_dir=$(mktemp -d "$git_hook_pure_preflight_prefix.XXXXXX") || return 1
  for hook_name in $git_hook_pure_hook_names; do
    hook_path=$git_hook_pure_hooks_dir/$hook_name
    if [ -L "$hook_path" ]; then
      git_hook_pure_error "existing hook must not be a symbolic link: $hook_path"
      return 1
    fi
    if [ -d "$hook_path" ]; then
      git_hook_pure_error "existing hook is a directory: $hook_path"
      return 1
    fi
    [ -e "$hook_path" ] || continue
    if [ ! -f "$hook_path" ]; then
      git_hook_pure_error "existing hook must be a regular file: $hook_path"
      return 1
    fi

    if git_hook_pure_has_reserved_marker "$hook_path"; then
      if git_hook_pure_validate_owned_markers \
        "$hook_path" "$git_hook_pure_preflight_dir/$hook_name.validation"; then
        :
      else
        status=$?
        if [ "$status" -eq 1 ]; then
          git_hook_pure_error "existing hook contains an unowned or malformed git-hook-pure marker: $hook_path"
        else
          git_hook_pure_error "unable to inspect existing hook: $hook_path"
        fi
        return "$status"
      fi
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        git_hook_pure_error "unable to inspect existing hook markers: $hook_path"
        return "$status"
      fi
    fi

    if grep -Fqx "$git_hook_pure_legacy_generated_marker" "$hook_path"; then
      if git_hook_pure_has_managed_block \
        "$hook_path" "$git_hook_pure_preflight_dir/$hook_name.ownership"; then
        :
      else
        status=$?
        if [ "$status" -eq 1 ]; then
          git_hook_pure_error "existing hook contains the reserved generated marker without a managed block: $hook_path"
        else
          git_hook_pure_error "unable to inspect existing hook: $hook_path"
        fi
        return "$status"
      fi
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        git_hook_pure_error "unable to inspect existing hook: $hook_path"
        return "$status"
      fi
    fi

    clean=$git_hook_pure_preflight_dir/$hook_name
    state_file=$git_hook_pure_preflight_dir/$hook_name.state
    if git_hook_pure_parse_hook "$hook_path" "$clean" "$state_file"; then
      :
    else
      status=$?
      if [ "$status" -eq 1 ]; then
        git_hook_pure_error "existing hook has an unowned or malformed git-hook-pure marker: $hook_path"
      else
        git_hook_pure_error "unable to inspect existing hook: $hook_path"
      fi
      return "$status"
    fi
    IFS= read -r parsed_state <"$state_file" || return $?
    if git_hook_pure_is_blank "$clean"; then
      if [ "$parsed_state" = generated ]; then
        continue
      fi
      git_hook_pure_error "existing blank hook has no git-hook-pure ownership marker: $hook_path"
      return 1
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        git_hook_pure_error "unable to inspect existing hook: $hook_path"
        return "$status"
      fi
    fi
    if [ "$parsed_state" != generated ] && [ ! -x "$hook_path" ]; then
      git_hook_pure_error "existing hook is not executable: $hook_path"
      return 1
    fi
    IFS= read -r first_line <"$clean" || true
    if [ "$parsed_state" = generated ]; then
      continue
    elif git_hook_pure_is_shell_shebang "$first_line"; then
      :
    else
      status=$?
      if [ "$status" -eq 1 ]; then
        git_hook_pure_error "existing hook is not a compatible shell script: $hook_path"
      else
        git_hook_pure_error "unable to inspect existing hook: $hook_path"
      fi
      return "$status"
    fi
  done
}

git_hook_pure_write_staged_hook() {
  local hook_name=$1
  local hook_path=$git_hook_pure_hooks_dir/$hook_name
  local clean=$git_hook_pure_preflight_dir/$hook_name
  local state_file=$git_hook_pure_preflight_dir/$hook_name.state
  local staged=$git_hook_pure_transaction_dir/staged/$hook_name
  local state=generated first_line original_missing_shebang_newline=false status

  if [ -e "$hook_path" ]; then
    [ -e "$clean" ] || return 1
    IFS= read -r state <"$state_file" || return $?
    [ "$state" = generated ] || state=existing
  else
    : >"$clean" || return 1
  fi

  if [ "$state" = generated ]; then
    printf '%s\n' '#!/bin/sh' >"$staged" || return 1
    chmod 755 "$staged" || return 1
    git_hook_pure_append_managed_block "$staged" generated false || return 1
  else
    cp -p "$hook_path" "$staged" || return $?
    if git_hook_pure_shebang_has_newline "$clean"; then
      :
    else
      status=$?
      if [ "$status" -eq 1 ]; then
        original_missing_shebang_newline=true
      else
        return "$status"
      fi
    fi
    IFS= read -r first_line <"$clean" || true
    printf '%s\n' "$first_line" >"$staged" || return 1
    git_hook_pure_append_managed_block "$staged" existing "$original_missing_shebang_newline" || return 1
    sed '1d' "$clean" >>"$staged" || return 1
  fi
}

git_hook_pure_write_uninstall_stage() {
  local hook_name=$1
  local hook_path=$git_hook_pure_hooks_dir/$hook_name
  local clean=$git_hook_pure_preflight_dir/$hook_name
  local state_file=$git_hook_pure_preflight_dir/$hook_name.state
  local backup=$git_hook_pure_transaction_dir/backups/$hook_name
  local output=$git_hook_pure_transaction_dir/staged/$hook_name
  local parsed_state

  IFS= read -r parsed_state <"$state_file" || return $?
  cp -p "$hook_path" "$backup" || return $?
  if [ "$parsed_state" = generated ]; then
    : >"$git_hook_pure_transaction_dir/delete/$hook_name" || return $?
  else
    cp -p "$hook_path" "$output" || return $?
    cat "$clean" >"$output" || return $?
  fi
}

git_hook_pure_restore_transaction() {
  local hook_name hook_path backup restore failed=false handlers_owned=false nested_marker

  mkdir -p "$git_hook_pure_transaction_dir/restore" || failed=true
  if [ -f "$git_hook_pure_transaction_dir/ledger" ]; then
    while IFS= read -r hook_name; do
      [ -n "$hook_name" ] || continue
      hook_path=$git_hook_pure_hooks_dir/$hook_name
      backup=$git_hook_pure_transaction_dir/backups/$hook_name
      restore=$git_hook_pure_transaction_dir/restore/$hook_name
      if [ -e "$backup" ]; then
        if ! cp -p "$backup" "$restore" || ! mv -f "$restore" "$hook_path"; then
          printf '[git-hook-pure] failed to restore hook: %s\n' "$hook_path" >&2
          failed=true
        fi
      elif ! rm -f "$hook_path"; then
        printf '[git-hook-pure] failed to remove partially managed hook: %s\n' "$hook_path" >&2
        failed=true
      fi
    done <"$git_hook_pure_transaction_dir/ledger"
  fi

  if [ -n "${git_hook_pure_transaction_handlers_marker:-}" ]; then
    nested_marker=$git_hook_pure_transaction_handlers_marker/$git_hook_pure_transaction_handlers_owner_name
    if [ -d "$nested_marker" ]; then
      if ! rmdir "$nested_marker" "$git_hook_pure_transaction_handlers_marker" 2>/dev/null; then
        printf '[git-hook-pure] failed to remove transaction staging from the handler directory: %s\n' \
          "$git_hook_pure_transaction_handlers_marker" >&2
        failed=true
      fi
    elif [ -d "$git_hook_pure_transaction_handlers_marker" ]; then
      handlers_owned=true
      if ! rmdir "$git_hook_pure_transaction_handlers_marker" 2>/dev/null; then
        printf '[git-hook-pure] failed to remove the handler-directory ownership marker: %s\n' \
          "$git_hook_pure_transaction_handlers_marker" >&2
        failed=true
      fi
    elif [ -f "$git_hook_pure_transaction_dir/handlers-owned" ]; then
      handlers_owned=true
    fi
  fi
  if [ "$handlers_owned" = true ] &&
    ! rmdir "$git_hook_pure_handlers_dir" 2>/dev/null; then
      printf '[git-hook-pure] failed to remove the transaction-created handler directory: %s\n' \
        "$git_hook_pure_handlers_dir" >&2
      failed=true
  fi

  if [ "$failed" = true ]; then
    printf '[git-hook-pure] rollback incomplete; recovery files kept at %s\n' \
      "$git_hook_pure_transaction_dir" >&2
    return 1
  fi
}

git_hook_pure_remove_operation_paths() {
  local label=$1
  local prefix=$2
  local path failed=false

  [ -n "$prefix" ] || return 0
  # HIDDEN CONTEXT: The selected empty namespace survives an interrupted mktemp assignment.
  for path in "$prefix".??????; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    if ! rm -rf "$path"; then
      printf '[git-hook-pure] failed to remove %s: %s\n' "$label" "$path" >&2
      failed=true
    fi
  done
  [ "$failed" = false ]
}

git_hook_pure_select_operation_prefix() {
  local base=$1
  local candidate=$1
  local suffix=0 path occupied

  while :; do
    occupied=false
    for path in "$candidate".??????; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        occupied=true
        break
      fi
    done
    if [ "$occupied" = false ]; then
      printf '%s\n' "$candidate"
      return
    fi
    suffix=$((suffix + 1))
    candidate=$base.$suffix
  done
}

git_hook_pure_cleanup_operation() {
  local failed=false

  if [ "${git_hook_pure_transaction_active:-false}" = true ]; then
    if git_hook_pure_restore_transaction; then
      git_hook_pure_transaction_active=false
    else
      failed=true
    fi
  fi
  if [ "${git_hook_pure_transaction_active:-false}" = false ] &&
    [ -n "${git_hook_pure_transaction_prefix:-}" ]; then
    if git_hook_pure_remove_operation_paths \
      'operation staging' "$git_hook_pure_transaction_prefix"; then
      git_hook_pure_transaction_dir=
      git_hook_pure_transaction_prefix=
    else
      failed=true
    fi
  fi
  if [ -n "${git_hook_pure_preflight_prefix:-}" ]; then
    if git_hook_pure_remove_operation_paths \
      'operation preflight data' "$git_hook_pure_preflight_prefix"; then
      git_hook_pure_preflight_dir=
      git_hook_pure_preflight_prefix=
    else
      failed=true
    fi
  fi
  [ "$failed" = false ]
}

git_hook_pure_operation_exit() {
  local status=$?

  trap - 0 HUP INT QUIT PIPE TERM
  git_hook_pure_cleanup_operation || status=1
  exit "$status"
}

git_hook_pure_begin_operation() {
  git_hook_pure_reset_operation_state
  trap git_hook_pure_operation_exit 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 141' PIPE
  trap 'exit 143' TERM
}

git_hook_pure_finish_operation() {
  git_hook_pure_cleanup_operation || return 1
  trap - 0 HUP INT QUIT PIPE TERM
}

git_hook_pure_begin_transaction() {
  git_hook_pure_transaction_active=true
}

git_hook_pure_commit_transaction() {
  if [ -n "${git_hook_pure_transaction_handlers_marker:-}" ] &&
    [ -d "$git_hook_pure_transaction_handlers_marker" ]; then
    : >"$git_hook_pure_transaction_dir/handlers-owned" || return 1
    rmdir "$git_hook_pure_transaction_handlers_marker" || return 1
  fi
  git_hook_pure_transaction_active=false
  git_hook_pure_finish_operation
}

git_hook_pure_install() {
  local hook_name hook_path handlers_stage status

  git_hook_pure_begin_operation
  git_hook_pure_resolve_repository || return $?
  git_hook_pure_preflight_install || return $?

  mkdir -p "$git_hook_pure_hooks_dir" || return 1
  git_hook_pure_transaction_prefix=$(git_hook_pure_select_operation_prefix \
    "$git_hook_pure_hooks_dir/.git-hook-pure-install.$$") || return $?
  git_hook_pure_transaction_dir=$(mktemp -d "$git_hook_pure_transaction_prefix.XXXXXX") || return 1
  if ! mkdir "$git_hook_pure_transaction_dir/staged" \
    "$git_hook_pure_transaction_dir/backups" \
    "$git_hook_pure_transaction_dir/restore"; then
    return 1
  fi
  if ! : >"$git_hook_pure_transaction_dir/ledger"; then
    return 1
  fi

  git_hook_pure_transaction_handlers_owner_name=
  git_hook_pure_transaction_handlers_marker=
  if [ ! -e "$git_hook_pure_handlers_dir" ]; then
    git_hook_pure_transaction_handlers_owner_name=.git-hook-pure-owner-$(
      basename -- "$git_hook_pure_transaction_dir"
    )
    handlers_stage=$git_hook_pure_transaction_dir/$git_hook_pure_transaction_handlers_owner_name
    git_hook_pure_transaction_handlers_marker=$git_hook_pure_handlers_dir/$git_hook_pure_transaction_handlers_owner_name
    if ! mkdir -p "$handlers_stage/$git_hook_pure_transaction_handlers_owner_name"; then
      return 1
    fi
  fi

  for hook_name in $git_hook_pure_hook_names; do
    hook_path=$git_hook_pure_hooks_dir/$hook_name
    if git_hook_pure_write_staged_hook "$hook_name"; then
      :
    else
      status=$?
      git_hook_pure_error "failed to stage hook for install: $hook_path"
      return "$status"
    fi
    if [ -e "$hook_path" ]; then
      cp -p "$hook_path" "$git_hook_pure_transaction_dir/backups/$hook_name" || return $?
    fi
  done

  git_hook_pure_begin_transaction
  # HIDDEN CONTEXT: Only the preplanned marker can prove this operation created
  # .githooks, so rollback never removes foreign content; live existence cannot reassign it.
  if [ -n "$git_hook_pure_transaction_handlers_marker" ]; then
    if ! mv "$handlers_stage" "$git_hook_pure_handlers_dir"; then
      git_hook_pure_error "failed to create handler directory: $git_hook_pure_handlers_dir"
      return 1
    fi
    if [ ! -d "$git_hook_pure_transaction_handlers_marker" ] ||
      [ -d "$git_hook_pure_transaction_handlers_marker/$git_hook_pure_transaction_handlers_owner_name" ]; then
      git_hook_pure_error "handler directory changed while it was being created: $git_hook_pure_handlers_dir"
      return 1
    fi
  elif [ ! -d "$git_hook_pure_handlers_dir" ] || [ -L "$git_hook_pure_handlers_dir" ]; then
    git_hook_pure_error "handler directory changed after preflight: $git_hook_pure_handlers_dir"
    return 1
  fi

  for hook_name in $git_hook_pure_hook_names; do
    hook_path=$git_hook_pure_hooks_dir/$hook_name
    printf '%s\n' "$hook_name" >>"$git_hook_pure_transaction_dir/ledger" || return 1
    if ! mv -f "$git_hook_pure_transaction_dir/staged/$hook_name" "$hook_path"; then
      git_hook_pure_error "failed to install hook: $hook_path"
      return 1
    fi
  done

  git_hook_pure_commit_transaction || return $?
  printf '[git-hook-pure] installed hooks in %s\n' "$git_hook_pure_hooks_dir"
}

git_hook_pure_uninstall() {
  local hook_name hook_path clean state_file found=false status

  git_hook_pure_begin_operation
  git_hook_pure_resolve_repository || return $?
  git_hook_pure_preflight_prefix=$(git_hook_pure_select_operation_prefix \
    "${TMPDIR:-/tmp}/git-hook-pure-preflight.$$") || return $?
  git_hook_pure_preflight_dir=$(mktemp -d "$git_hook_pure_preflight_prefix.XXXXXX") || return 1

  for hook_name in $git_hook_pure_hook_names; do
    hook_path=$git_hook_pure_hooks_dir/$hook_name
    [ -e "$hook_path" ] || continue
    if [ -L "$hook_path" ]; then
      git_hook_pure_error "hook must not be a symbolic link: $hook_path"
      return 1
    fi
    if [ ! -f "$hook_path" ]; then
      git_hook_pure_error "hook must be a regular file: $hook_path"
      return 1
    fi
    if [ ! -r "$hook_path" ]; then
      git_hook_pure_error "hook is not readable: $hook_path"
      return 1
    fi
    if git_hook_pure_has_reserved_marker "$hook_path"; then
      clean=$git_hook_pure_preflight_dir/$hook_name
      state_file=$git_hook_pure_preflight_dir/$hook_name.state
      if git_hook_pure_parse_hook "$hook_path" "$clean" "$state_file"; then
        :
      else
        status=$?
        if [ "$status" -eq 1 ]; then
          git_hook_pure_error "hook has an unowned or malformed git-hook-pure marker: $hook_path"
        else
          git_hook_pure_error "unable to inspect hook: $hook_path"
        fi
        return "$status"
      fi
      found=true
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        git_hook_pure_error "unable to inspect hook markers: $hook_path"
        return "$status"
      fi
    fi
  done

  if [ "$found" = false ]; then
    git_hook_pure_finish_operation || return $?
    printf '[git-hook-pure] no installed hooks found in %s\n' "$git_hook_pure_hooks_dir"
    return 0
  fi

  git_hook_pure_transaction_prefix=$(git_hook_pure_select_operation_prefix \
    "$git_hook_pure_hooks_dir/.git-hook-pure-uninstall.$$") || return $?
  git_hook_pure_transaction_dir=$(mktemp -d "$git_hook_pure_transaction_prefix.XXXXXX") || return 1
  if ! mkdir "$git_hook_pure_transaction_dir/staged" \
    "$git_hook_pure_transaction_dir/backups" \
    "$git_hook_pure_transaction_dir/delete" \
    "$git_hook_pure_transaction_dir/restore"; then
    return 1
  fi
  if ! : >"$git_hook_pure_transaction_dir/ledger"; then
    return 1
  fi

  for hook_name in $git_hook_pure_hook_names; do
    hook_path=$git_hook_pure_hooks_dir/$hook_name
    state_file=$git_hook_pure_preflight_dir/$hook_name.state
    [ -e "$state_file" ] || continue
    if git_hook_pure_write_uninstall_stage "$hook_name"; then
      :
    else
      status=$?
      git_hook_pure_error "failed to stage hook for uninstall: $hook_path"
      return "$status"
    fi
  done

  git_hook_pure_begin_transaction
  for hook_name in $git_hook_pure_hook_names; do
    hook_path=$git_hook_pure_hooks_dir/$hook_name
    [ -e "$git_hook_pure_transaction_dir/backups/$hook_name" ] || continue
    printf '%s\n' "$hook_name" >>"$git_hook_pure_transaction_dir/ledger" || return 1
    if [ -e "$git_hook_pure_transaction_dir/delete/$hook_name" ]; then
      if ! rm -f "$hook_path"; then
        git_hook_pure_error "failed to remove managed hook: $hook_path"
        return 1
      fi
    elif ! mv -f "$git_hook_pure_transaction_dir/staged/$hook_name" "$hook_path"; then
      git_hook_pure_error "failed to restore existing hook content: $hook_path"
      return 1
    fi
  done

  git_hook_pure_commit_transaction || return $?
  printf '[git-hook-pure] uninstalled hooks from %s\n' "$git_hook_pure_hooks_dir"
}
