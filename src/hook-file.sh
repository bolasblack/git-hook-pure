git_hook_pure_validate_markers() {
  awk \
    -v start="$git_hook_pure_start_marker" \
    -v end="$git_hook_pure_end_marker" '
    /^# ==* git-hook-pure (start|end) ==*$/ {
      if ($0 != start && $0 != end) invalid = 1
    }
    $0 == start {
      if (inside) invalid = 1
      starts++
      inside = 1
      next
    }
    $0 == end {
      if (!inside) invalid = 1
      ends++
      inside = 0
      next
    }
    END { if (inside || invalid || starts != 1 || ends != 1) exit 1 }
  ' "$1"
}

git_hook_pure_has_reserved_marker() {
  grep -Eq '^# ==* git-hook-pure (start|end) ==*$' "$1"
}

git_hook_pure_current_block_metadata() {
  awk \
    -v start="$git_hook_pure_start_marker" \
    -v end="$git_hook_pure_end_marker" \
    -v signature="$git_hook_pure_managed_signature" \
    -v generated="$git_hook_pure_generated_state" \
    -v existing="$git_hook_pure_existing_state" \
    -v missing="$git_hook_pure_no_shebang_newline_marker" \
    -v oid_prefix="$git_hook_pure_content_oid_prefix" '
    function read_oid(value, candidate) {
      if (index(value, oid_prefix) != 1) return 0
      candidate = substr(value, length(oid_prefix) + 1)
      if (candidate !~ /^[0-9a-f]+$/) return 0
      oid = candidate
      return 1
    }
    $0 == start {
      inside = 1
      line = 0
      next
    }
    $0 == end {
      if (inside) end_line = NR
      inside = 0
      next
    }
    inside {
      line++
      if (line == 1 && $0 != signature) exit 1
      if (line == 2) {
        if (!read_oid($0)) exit 1
        content_line = NR + 1
        next
      }
      if (line == 3) {
        if ($0 == generated) state = "generated"
        else if ($0 == existing) state = "existing"
        else exit 1
        newline = "present"
        next
      }
      if (line == 4 && $0 == missing) {
        if (state != "existing") exit 1
        newline = "missing"
      }
    }
    END {
      if (!state || !oid || !content_line || !end_line || content_line >= end_line) exit 1
      print state, newline, oid, content_line, end_line
    }
  ' "$1"
}

git_hook_pure_has_current_managed_block() {
  local input=$1
  local scratch=$2
  local metadata state newline_state expected_oid content_line end_line actual_oid total_lines
  local content=$scratch.v4.content
  local IFS=' '
  local status

  if metadata=$(git_hook_pure_current_block_metadata "$input"); then
    :
  else
    status=$?
    return "$status"
  fi
  set -- $metadata
  state=$1
  newline_state=$2
  expected_oid=$3
  content_line=$4
  end_line=$5
  case "$state $newline_state" in
    'generated present'|'existing present') ;;
    'existing missing') ;;
    *) return 1 ;;
  esac

  if total_lines=$(awk 'END { print NR }' "$input"); then
    :
  else
    status=$?
    return "$status"
  fi
  if [ "$end_line" -eq "$total_lines" ] &&
    [ "$(tail -c 1 "$input" | wc -l | tr -d '[:space:]')" != 1 ]; then
    return 1
  fi
  if sed -n "${content_line},${end_line}p" "$input" >"$content"; then
    :
  else
    status=$?
    rm -f "$content" || :
    return "$status"
  fi
  if actual_oid=$(git hash-object --stdin <"$content"); then
    :
  else
    status=$?
    rm -f "$content" || :
    return "$status"
  fi
  rm -f "$content" || return $?
  [ "$actual_oid" = "$expected_oid" ]
}

git_hook_pure_write_legacy_default_block() {
  local variant=$1

  cat <<'EOF'
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
EOF
  if [ "$variant" = slice ]; then
    cat <<'EOF'
        "$hookFilePath" "${@:2}" || exit 1
EOF
  else
    cat <<'EOF'
        shift 2
        "$hookFilePath" "$@" || exit 1
EOF
  fi
  cat <<'EOF'
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
}

git_hook_pure_has_legacy_default_block() {
  local input=$1
  local scratch=$2
  local actual=$scratch.legacy.actual
  local expected=$scratch.legacy.expected
  local variant matched=false
  local status

  if sed -n \
    '/^# ================== git-hook-pure start ==================$/,/^# ================== git-hook-pure end ==================$/p' \
    "$input" >"$actual"; then
    :
  else
    status=$?
    return "$status"
  fi
  for variant in shift slice; do
    if git_hook_pure_write_legacy_default_block "$variant" >"$expected"; then
      :
    else
      status=$?
      rm -f "$actual" "$expected" || :
      return "$status"
    fi
    if cmp -s "$actual" "$expected"; then
      matched=true
      break
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        rm -f "$actual" "$expected" || :
        return "$status"
      fi
    fi
  done
  rm -f "$actual" "$expected" || return $?
  [ "$matched" = true ]
}

git_hook_pure_is_exact_legacy_generated_hook() {
  local input=$1
  local scratch=$2
  local expected=$scratch.legacy-generated.expected
  local variant matched=false
  local status

  for variant in shift slice; do
    printf '\n\n' >"$expected" || return $?
    if git_hook_pure_write_legacy_default_block "$variant" >>"$expected"; then
      :
    else
      status=$?
      rm -f "$expected" || :
      return "$status"
    fi
    if cmp -s "$input" "$expected"; then
      matched=true
      break
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        rm -f "$expected" || :
        return "$status"
      fi
    fi
  done
  rm -f "$expected" || return $?
  [ "$matched" = true ]
}

git_hook_pure_validate_owned_markers() {
  local status

  if git_hook_pure_validate_markers "$1"; then
    :
  else
    status=$?
    return "$status"
  fi
  if git_hook_pure_has_current_managed_block "$1" "$2"; then
    return 0
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
  fi
  git_hook_pure_has_legacy_default_block "$1" "$2"
}

git_hook_pure_has_managed_block() {
  local status

  if git_hook_pure_has_reserved_marker "$1"; then
    git_hook_pure_validate_owned_markers "$1" "$2"
  else
    status=$?
    return "$status"
  fi
}

git_hook_pure_remove_final_newline() {
  local file=$1
  local bytes trimmed

  bytes=$(wc -c <"$file" | tr -d '[:space:]') || return $?
  [ "$bytes" -gt 0 ] || return 1
  [ "$(tail -c 1 "$file" | wc -l | tr -d '[:space:]')" = 1 ] || return 1
  trimmed=$file.without-final-newline
  dd if="$file" of="$trimmed" bs=1 count=$((bytes - 1)) 2>/dev/null || return $?
  cat "$trimmed" >"$file" || return $?
  rm -f "$trimmed"
}

git_hook_pure_remove_legacy_envelope_newline() {
  local input=$1
  local output=$2
  local prefix=$output.legacy-prefix
  local spliced=$output.legacy-spliced
  local prefix_bytes status

  if sed -n \
    '/^# ================== git-hook-pure start ==================$/q; p' \
    "$input" >"$prefix"; then
    :
  else
    status=$?
    return "$status"
  fi
  prefix_bytes=$(wc -c <"$prefix" | tr -d '[:space:]') || return $?
  if [ "$prefix_bytes" -le 0 ] ||
    [ "$(tail -c 1 "$prefix" | wc -l | tr -d '[:space:]')" != 1 ]; then
    rm -f "$prefix" "$spliced"
    return 1
  fi
  if dd if="$output" of="$spliced" bs=1 count=$((prefix_bytes - 1)) 2>/dev/null; then
    :
  else
    status=$?
    rm -f "$prefix" "$spliced" || :
    return "$status"
  fi
  if dd if="$output" bs=1 skip="$prefix_bytes" 2>/dev/null >>"$spliced"; then
    :
  else
    status=$?
    rm -f "$prefix" "$spliced" || :
    return "$status"
  fi
  if cat "$spliced" >"$output"; then
    :
  else
    status=$?
    rm -f "$prefix" "$spliced" || :
    return "$status"
  fi
  rm -f "$prefix" "$spliced" || return $?
}

git_hook_pure_is_only_shebang_and_space() {
  awk '
    NR == 1 && /^#!/ { next }
    /^[[:space:]]*$/ { next }
    { invalid = 1 }
    END { if (invalid) exit 1 }
  ' "$1"
}

git_hook_pure_parse_hook() {
  local input=$1
  local output=$2
  local state_file=$3
  local parsed_state current_metadata metadata_remainder newline_state status
  local restore_missing_newline=false

  if git_hook_pure_has_reserved_marker "$input"; then
    :
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
    cp "$input" "$output" || return $?
    printf '%s\n' unmanaged >"$state_file" || return $?
    return
  fi
  git_hook_pure_validate_owned_markers "$input" "$output" || return $?
  if current_metadata=$(git_hook_pure_current_block_metadata "$input"); then
    parsed_state=${current_metadata%% *}
    metadata_remainder=${current_metadata#* }
    newline_state=${metadata_remainder%% *}
    [ "$newline_state" = missing ] && restore_missing_newline=true
  else
    status=$?
    if [ "$status" -eq 1 ]; then
      parsed_state=legacy
    else
      return "$status"
    fi
  fi
  LC_ALL=C sed \
    '/^# ==* git-hook-pure start ==*$/,/^# ==* git-hook-pure end ==*$/d' \
    "$input" >"$output" || return $?
  if [ "$parsed_state" = legacy ]; then
    git_hook_pure_remove_legacy_envelope_newline "$input" "$output" || return $?
  elif [ "$restore_missing_newline" = true ]; then
    if [ "$(wc -l <"$output" | tr -d '[:space:]')" = 1 ]; then
      if grep -q '^#!' "$output"; then
        if [ "$(tail -c 1 "$output" | wc -l | tr -d '[:space:]')" = 1 ]; then
          git_hook_pure_remove_final_newline "$output" || return $?
        fi
      else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
      fi
    fi
  fi

  case "$parsed_state" in
    generated)
      if git_hook_pure_is_only_shebang_and_space "$output"; then
        parsed_state=generated
      else
        status=$?
        if [ "$status" -eq 1 ]; then
          parsed_state=existing
        else
          return "$status"
        fi
      fi
      ;;
    existing) ;;
    legacy)
      if git_hook_pure_is_blank "$output"; then
        git_hook_pure_is_exact_legacy_generated_hook "$input" "$output" || return $?
        parsed_state=generated
      else
        status=$?
        if [ "$status" -eq 1 ]; then
          parsed_state=existing
        else
          return "$status"
        fi
      fi
      ;;
  esac
  printf '%s\n' "$parsed_state" >"$state_file" || return $?
}

git_hook_pure_is_blank() {
  local status

  if grep -q '[^[:space:]]' "$1"; then
    return 1
  else
    status=$?
    [ "$status" -eq 1 ] && return 0
    return "$status"
  fi
}

git_hook_pure_is_shell_shebang() {
  printf '%s\n' "$1" | awk '
    function base(path) { sub(/^.*\//, "", path); return path }
    function shell(name) {
      return name == "sh" || name == "ash" || name == "bash" ||
        name == "dash" || name == "ksh" || name == "zsh"
    }
    function option(value) { return value ~ /^-[eufxv]+$/ }
    {
      if (substr($0, 1, 2) != "#!") exit 1
      line = substr($0, 3)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      count = split(line, field, /[[:space:]]+/)
      interpreter = field[1]
      if (interpreter !~ /^\//) exit 1
      if (shell(base(interpreter))) {
        if (count == 1 || (count == 2 && option(field[2]))) exit 0
        exit 1
      }
      if (base(interpreter) != "env") exit 1
      if (count == 2 && shell(field[2])) exit 0
      if (count < 3 || field[2] != "-S" || !shell(field[3])) exit 1
      for (i = 4; i <= count; i++) {
        if (!option(field[i])) exit 1
      }
      exit 0
    }
  '
}

git_hook_pure_write_runtime_prefix() {
  cat <<'EOF'
__git_hook_pure_managed_v4() {
case "${KSH_VERSION:-}${ZSH_VERSION:-}" in
  ?*) typeset __git_hook_pure_v4_hook_name __git_hook_pure_v4_input __git_hook_pure_v4_status ;;
  *) local __git_hook_pure_v4_hook_name __git_hook_pure_v4_input __git_hook_pure_v4_status ;;
esac
__git_hook_pure_v4_hook_name=$(basename "$0") || exit $?
__git_hook_pure_v4_input=
case "$__git_hook_pure_v4_hook_name" in
  pre-push|pre-receive|post-receive|post-rewrite)
    __git_hook_pure_v4_input=$(
      umask 077
      mktemp "${TMPDIR:-/tmp}/git-hook-pure-stdin.XXXXXX"
    ) || {
      __git_hook_pure_v4_status=$?
      printf '%s\n' '[git-hook-pure] unable to create temporary stdin storage' >&2
      exit "$__git_hook_pure_v4_status"
    }
    if [ -z "$__git_hook_pure_v4_input" ]; then
      printf '%s\n' '[git-hook-pure] temporary stdin storage has no path' >&2
      exit 1
    fi
    trap 'rm -f "$__git_hook_pure_v4_input"' 0
    trap 'trap - 0 HUP INT QUIT PIPE TERM; rm -f "$__git_hook_pure_v4_input"; kill -s HUP "$$"; exit 1' HUP
    trap 'trap - 0 HUP INT QUIT PIPE TERM; rm -f "$__git_hook_pure_v4_input"; kill -s INT "$$"; exit 1' INT
    trap 'trap - 0 HUP INT QUIT PIPE TERM; rm -f "$__git_hook_pure_v4_input"; kill -s QUIT "$$"; exit 1' QUIT
    trap 'trap - 0 HUP INT QUIT PIPE TERM; rm -f "$__git_hook_pure_v4_input"; kill -s PIPE "$$"; exit 1' PIPE
    trap 'trap - 0 HUP INT QUIT PIPE TERM; rm -f "$__git_hook_pure_v4_input"; kill -s TERM "$$"; exit 1' TERM
    cat >"$__git_hook_pure_v4_input" || {
      __git_hook_pure_v4_status=$?
      printf '%s\n' '[git-hook-pure] unable to snapshot hook stdin' >&2
      exit "$__git_hook_pure_v4_status"
    }
    ;;
esac

(
if [ -n "$__git_hook_pure_v4_input" ]; then
  exec <"$__git_hook_pure_v4_input" || exit $?
fi
EOF
}

git_hook_pure_write_dispatcher_body() {
  cat <<'EOF'
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt NULL_GLOB
else
  set +f
fi

git_hook_pure_runtime_is_absolute_path() {
  case "$1" in
    /*|[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:/*) return 0 ;;
    *) return 1 ;;
  esac
}

git_hook_pure_resolve_project_root() {
  runtime_git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || {
    runtime_git_dir_status=$?
    printf '%s\n' '[git-hook-pure] unable to resolve the current Git directory' >&2
    return "$runtime_git_dir_status"
  }
  if ! git_hook_pure_runtime_is_absolute_path "$runtime_git_dir"; then
    printf '%s\n' \
      '[git-hook-pure] Git 2.31 or newer is required: the current Git directory did not resolve to an absolute path' >&2
    return 1
  fi
  if project_root=$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null); then
    if ! git_hook_pure_runtime_is_absolute_path "$project_root"; then
      printf '%s\n' \
        '[git-hook-pure] Git 2.31 or newer is required: the worktree root did not resolve to an absolute path' >&2
      return 1
    fi
  else
    project_root=$runtime_git_dir
  fi

  if [ "$project_root" = "$runtime_git_dir" ]; then
    if [ -f "$runtime_git_dir/gitdir" ]; then
      linked_git_file=$(sed -n '1p' "$runtime_git_dir/gitdir") || {
        linked_git_file_status=$?
        printf '%s\n' '[git-hook-pure] unable to read the linked worktree mapping' >&2
        return "$linked_git_file_status"
      }
      if [ -z "$linked_git_file" ]; then
        printf '%s\n' '[git-hook-pure] linked worktree mapping is empty' >&2
        return 1
      fi
      if ! git_hook_pure_runtime_is_absolute_path "$linked_git_file"; then
        linked_git_file=$runtime_git_dir/$linked_git_file
      fi
      project_root=$(dirname -- "$linked_git_file") || {
        linked_git_file_status=$?
        printf '%s\n' '[git-hook-pure] unable to resolve the linked worktree root' >&2
        return "$linked_git_file_status"
      }
      project_root=$(CDPATH= cd -- "$project_root" 2>/dev/null && pwd) || {
        linked_git_file_status=$?
        printf '%s\n' '[git-hook-pure] linked worktree root does not exist' >&2
        return "$linked_git_file_status"
      }
      if [ ! -f "$linked_git_file" ]; then
        printf '%s\n' '[git-hook-pure] linked worktree .git file does not exist' >&2
        return 1
      fi
      linked_forward_git_dir=$(sed -n '1s/^gitdir: //p' "$linked_git_file") || {
        linked_git_file_status=$?
        printf '%s\n' '[git-hook-pure] unable to read the linked worktree .git file' >&2
        return "$linked_git_file_status"
      }
      if [ -z "$linked_forward_git_dir" ]; then
        printf '%s\n' '[git-hook-pure] linked worktree .git file is malformed' >&2
        return 1
      fi
      if ! git_hook_pure_runtime_is_absolute_path "$linked_forward_git_dir"; then
        linked_forward_git_dir=$project_root/$linked_forward_git_dir
      fi
      linked_forward_git_dir=$(CDPATH= cd -- "$linked_forward_git_dir" 2>/dev/null && pwd) || {
        linked_git_file_status=$?
        printf '%s\n' '[git-hook-pure] linked worktree Git directory does not exist' >&2
        return "$linked_git_file_status"
      }
      linked_runtime_git_dir=$(CDPATH= cd -- "$runtime_git_dir" 2>/dev/null && pwd) || {
        linked_git_file_status=$?
        printf '%s\n' '[git-hook-pure] current linked Git directory cannot be resolved' >&2
        return "$linked_git_file_status"
      }
      if [ "$linked_forward_git_dir" != "$linked_runtime_git_dir" ]; then
        printf '%s\n' '[git-hook-pure] linked worktree mapping does not point back to the current Git directory' >&2
        return 1
      fi
    else
      if configured_worktree=$(git config --path --get core.worktree 2>/dev/null); then
        if [ -z "$configured_worktree" ]; then
          printf '%s\n' '[git-hook-pure] configured worktree is empty' >&2
          return 1
        fi
        if ! git_hook_pure_runtime_is_absolute_path "$configured_worktree"; then
          configured_worktree=$runtime_git_dir/$configured_worktree
        fi
        project_root=$(CDPATH= cd -- "$configured_worktree" 2>/dev/null && pwd) || {
          printf '%s\n' '[git-hook-pure] configured worktree cannot be resolved' >&2
          return 1
        }
      else
        configured_worktree_status=$?
        if [ "$configured_worktree_status" -ne 1 ]; then
          printf '%s\n' '[git-hook-pure] unable to inspect the configured worktree' >&2
          return "$configured_worktree_status"
        fi
        case "$runtime_git_dir" in
          */.git) project_root=${runtime_git_dir%/.git} ;;
          *)
            printf '%s\n' '[git-hook-pure] unable to map this server hook to a worktree' >&2
            return 1
            ;;
        esac
      fi
    fi
  fi

  printf '%s\n' "$project_root"
}

projectRoot=$(git_hook_pure_resolve_project_root) || exit $?
hookName=$__git_hook_pure_v4_hook_name

executeAllFiles() {
  hookFolderPath=$1
  shift

  if [ "${LC_ALL+x}" = x ]; then
    __git_hook_pure_v4_lc_all_set=true
    __git_hook_pure_v4_lc_all=$LC_ALL
  else
    __git_hook_pure_v4_lc_all_set=false
    __git_hook_pure_v4_lc_all=
  fi
  LC_ALL=C
  export LC_ALL
  for hookFilePath in "$hookFolderPath"/*; do
    if [ "$__git_hook_pure_v4_lc_all_set" = true ]; then
      LC_ALL=$__git_hook_pure_v4_lc_all
      export LC_ALL
    else
      unset LC_ALL
    fi
    if [ ! -e "$hookFilePath" ] && [ ! -L "$hookFilePath" ]; then
      continue
    fi
    if [ -d "$hookFilePath" ]; then
      continue
    fi
    if [ ! -x "$hookFilePath" ]; then
      printf '[git-hook-pure] handler is not executable: %s\n' "$hookFilePath" >&2
      return 1
    fi
    if [ -n "$__git_hook_pure_v4_input" ]; then
      "$hookFilePath" "$@" <"$__git_hook_pure_v4_input" || return $?
    else
      "$hookFilePath" "$@" || return $?
    fi
  done
  if [ "$__git_hook_pure_v4_lc_all_set" = true ]; then
    LC_ALL=$__git_hook_pure_v4_lc_all
    export LC_ALL
  else
    unset LC_ALL
  fi
}

hookFolderPath=$projectRoot/.githooks
if [ -d "$hookFolderPath" ]; then
  executeAllFiles "$hookFolderPath" "$hookName" "$@" || exit $?
fi
if [ -d "$hookFolderPath/$hookName" ]; then
  executeAllFiles "$hookFolderPath/$hookName" "$@" || exit $?
fi
EOF
}

git_hook_pure_write_runtime_suffix() {
  cat <<'EOF'
)
__git_hook_pure_v4_status=$?
if [ "$__git_hook_pure_v4_status" -ne 0 ]; then
  exit "$__git_hook_pure_v4_status"
fi

if [ -n "$__git_hook_pure_v4_input" ]; then
  exec <"$__git_hook_pure_v4_input" || {
    __git_hook_pure_v4_status=$?
    exit "$__git_hook_pure_v4_status"
  }
  rm -f "$__git_hook_pure_v4_input" || {
    __git_hook_pure_v4_status=$?
    printf '%s\n' '[git-hook-pure] unable to remove temporary stdin storage' >&2
    exit "$__git_hook_pure_v4_status"
  }
  trap - 0 HUP INT QUIT PIPE TERM
fi
return 0
}
__git_hook_pure_managed_v4 "$@" || exit $?
unset -f __git_hook_pure_managed_v4
EOF
}

git_hook_pure_write_managed_content() {
  local state=$1
  local original_missing_shebang_newline=$2

  case "$state:$original_missing_shebang_newline" in
    generated:false)
      printf '%s\n' "$git_hook_pure_generated_state" || return 1
      ;;
    existing:false)
      printf '%s\n' "$git_hook_pure_existing_state" || return 1
      ;;
    existing:true)
      printf '%s\n' "$git_hook_pure_existing_state" || return 1
      printf '%s\n' "$git_hook_pure_no_shebang_newline_marker" || return 1
      ;;
    *) return 1 ;;
  esac
  git_hook_pure_write_runtime_prefix || return 1
  git_hook_pure_write_dispatcher_body || return 1
  git_hook_pure_write_runtime_suffix || return 1
  printf '%s\n' "$git_hook_pure_end_marker"
}

git_hook_pure_shebang_has_newline() {
  local lines

  lines=$(wc -l <"$1") || return $?
  [ "$lines" -gt 0 ]
}

git_hook_pure_append_managed_block() {
  local output=$1
  local state=$2
  local original_missing_shebang_newline=${3:-false}
  local content=$output.git-hook-pure-content
  local content_oid

  case "$state:$original_missing_shebang_newline" in
    generated:false|existing:false|existing:true) ;;
    *) return 1 ;;
  esac

  git_hook_pure_write_managed_content \
    "$state" "$original_missing_shebang_newline" >"$content" || {
    rm -f "$content"
    return 1
  }
  content_oid=$(git hash-object --stdin <"$content") || {
    rm -f "$content"
    return 1
  }
  case "$content_oid" in
    ''|*[!0-9a-f]*)
      rm -f "$content"
      return 1
      ;;
  esac

  {
    printf '%s\n' "$git_hook_pure_start_marker" &&
      printf '%s\n' "$git_hook_pure_managed_signature" &&
      printf '%s%s\n' "$git_hook_pure_content_oid_prefix" "$content_oid" &&
      cat "$content"
  } >>"$output" || {
    rm -f "$content"
    return 1
  }
  rm -f "$content"
}
