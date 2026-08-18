#!/bin/sh

set -eu

version=${GIT_HOOK_PURE_VERSION:-}
release_base_url=${GIT_HOOK_PURE_RELEASE_BASE_URL:-https://github.com/bolasblack/git-hook-pure/releases/download}
install_path=${INSTALL_PATH:-./scripts/git-hook-pure}
semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

git_hook_pure_is_absolute_path() {
  case "$1" in
    /*|[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:/*) return 0 ;;
  esac
  return 1
}

git_hook_pure_resolve_git_path() {
  git_hook_pure_git_path_label=$1
  shift
  if git_hook_pure_git_path=$(git "$@" 2>&1); then
    :
  else
    git_hook_pure_git_path_status=$?
    printf '[git-hook-pure] unable to resolve the Git %s\n' \
      "$git_hook_pure_git_path_label" >&2
    [ -z "$git_hook_pure_git_path" ] || printf '%s\n' "$git_hook_pure_git_path" >&2
    return "$git_hook_pure_git_path_status"
  fi
  if ! git_hook_pure_is_absolute_path "$git_hook_pure_git_path"; then
    printf '[git-hook-pure] Git 2.31 or newer must provide an absolute %s\n' \
      "$git_hook_pure_git_path_label" >&2
    return 1
  fi
}

git_hook_pure_physicalize_directory() {
  git_hook_pure_directory_label=$1
  git_hook_pure_directory_input=$2
  if git_hook_pure_physical_directory=$(
    CDPATH= cd -P -- "$git_hook_pure_directory_input" 2>/dev/null && pwd -P
  ); then
    :
  else
    git_hook_pure_directory_status=$?
    printf '[git-hook-pure] resolved Git %s is not an accessible directory: %s\n' \
      "$git_hook_pure_directory_label" "$git_hook_pure_directory_input" >&2
    return "$git_hook_pure_directory_status"
  fi
}

git_hook_pure_preflight_destination() {
  git_hook_pure_install_path=$1

  git_hook_pure_resolve_git_path 'worktree root' \
    rev-parse --path-format=absolute --show-toplevel || return $?
  git_hook_pure_physicalize_directory 'worktree root' "$git_hook_pure_git_path" || return $?
  git_hook_pure_repo_root=$git_hook_pure_physical_directory

  git_hook_pure_resolve_git_path 'directory' \
    rev-parse --path-format=absolute --git-dir || return $?
  git_hook_pure_physicalize_directory 'directory' "$git_hook_pure_git_path" || return $?
  git_hook_pure_git_dir=$git_hook_pure_physical_directory

  git_hook_pure_resolve_git_path 'common directory' \
    rev-parse --path-format=absolute --git-common-dir || return $?
  git_hook_pure_physicalize_directory 'common directory' "$git_hook_pure_git_path" || return $?
  git_hook_pure_common_dir=$git_hook_pure_physical_directory

  if git_hook_pure_caller_cwd=$(pwd -P); then
    :
  else
    git_hook_pure_cwd_status=$?
    printf '%s\n' '[git-hook-pure] unable to resolve the caller working directory' >&2
    return "$git_hook_pure_cwd_status"
  fi

  git_hook_pure_folded_git_dir=$(
    printf '%s\n' "$git_hook_pure_git_dir" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  ) || return $?
  git_hook_pure_folded_common_dir=$(
    printf '%s\n' "$git_hook_pure_common_dir" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  ) || return $?

  case "$git_hook_pure_install_path" in
    //*)
      git_hook_pure_normalized_destination=//
      git_hook_pure_remaining_destination=${git_hook_pure_install_path#//}
      ;;
    /*)
      git_hook_pure_normalized_destination=/
      git_hook_pure_remaining_destination=${git_hook_pure_install_path#/}
      ;;
    [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:/*)
      git_hook_pure_normalized_destination=${git_hook_pure_install_path%%/*}/
      git_hook_pure_remaining_destination=${git_hook_pure_install_path#*/}
      ;;
    *)
      git_hook_pure_normalized_destination=$git_hook_pure_caller_cwd
      git_hook_pure_remaining_destination=$git_hook_pure_install_path
      ;;
  esac

  while [ -n "$git_hook_pure_remaining_destination" ]; do
    case "$git_hook_pure_remaining_destination" in
      */*)
        git_hook_pure_component=${git_hook_pure_remaining_destination%%/*}
        git_hook_pure_remaining_destination=${git_hook_pure_remaining_destination#*/}
        ;;
      *)
        git_hook_pure_component=$git_hook_pure_remaining_destination
        git_hook_pure_remaining_destination=
        ;;
    esac
    # HIDDEN CONTEXT: Case variants alias Git administrative paths on supported filesystems.
    case "$git_hook_pure_component" in
      .[gG][iI][tT])
        printf '[git-hook-pure] install target must be outside Git administrative directories: %s\n' \
          "$git_hook_pure_install_path" >&2
        return 1
        ;;
      ''|.) continue ;;
      ..)
        git_hook_pure_normalized_destination=$(dirname -- "$git_hook_pure_normalized_destination") ||
          return $?
        continue
        ;;
    esac
    case "$git_hook_pure_normalized_destination" in
      /|//|*/) git_hook_pure_next_destination=$git_hook_pure_normalized_destination$git_hook_pure_component ;;
      *) git_hook_pure_next_destination=$git_hook_pure_normalized_destination/$git_hook_pure_component ;;
    esac
    if [ -L "$git_hook_pure_next_destination" ]; then
      printf '[git-hook-pure] install target must not traverse a symlink: %s\n' \
        "$git_hook_pure_next_destination" >&2
      return 1
    fi
    if [ -d "$git_hook_pure_next_destination" ]; then
      if git_hook_pure_physical_component=$(
        CDPATH= cd -P -- "$git_hook_pure_next_destination" 2>/dev/null && pwd -P
      ); then
        git_hook_pure_next_destination=$git_hook_pure_physical_component
      else
        git_hook_pure_component_status=$?
        printf '[git-hook-pure] install target directory is not accessible: %s\n' \
          "$git_hook_pure_next_destination" >&2
        return "$git_hook_pure_component_status"
      fi
    elif [ -e "$git_hook_pure_next_destination" ] &&
      [ -n "$git_hook_pure_remaining_destination" ]; then
      printf '[git-hook-pure] install target parent must be a directory: %s\n' \
        "$git_hook_pure_next_destination" >&2
      return 1
    fi
    git_hook_pure_folded_component_path=$(
      printf '%s\n' "$git_hook_pure_next_destination" |
        LC_ALL=C tr '[:upper:]' '[:lower:]'
    ) || return $?
    case "$git_hook_pure_folded_component_path" in
      "$git_hook_pure_folded_git_dir"|"$git_hook_pure_folded_git_dir"/*|"$git_hook_pure_folded_common_dir"|"$git_hook_pure_folded_common_dir"/*)
        printf '[git-hook-pure] install target must be outside Git administrative directories: %s\n' \
          "$git_hook_pure_install_path" >&2
        return 1
        ;;
    esac
    git_hook_pure_normalized_destination=$git_hook_pure_next_destination
  done

  case "$git_hook_pure_repo_root" in
    /)
      case "$git_hook_pure_normalized_destination" in /*) ;; *) return 1 ;; esac
      ;;
    *)
      case "$git_hook_pure_normalized_destination" in
        "$git_hook_pure_repo_root"|"$git_hook_pure_repo_root"/*) ;;
        *)
          printf '[git-hook-pure] install target must be inside the current Git worktree: %s\n' \
            "$git_hook_pure_install_path" >&2
          return 1
          ;;
      esac
      ;;
  esac

  if [ -d "$git_hook_pure_normalized_destination" ] ||
    [ -L "$git_hook_pure_normalized_destination" ] ||
    { [ -e "$git_hook_pure_normalized_destination" ] &&
      [ ! -f "$git_hook_pure_normalized_destination" ]; }; then
    printf '[git-hook-pure] install target must be a regular file path: %s\n' \
      "$git_hook_pure_install_path" >&2
    return 1
  fi
}

source_mode=false
source_executable=
if [ "$#" -ne 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != --source-executable ]; then
    printf '%s\n' 'Usage: install-standalone.sh [--source-executable <path>]' >&2
    exit 2
  fi
  if [ -z "$2" ]; then
    printf '%s\n' '[git-hook-pure] --source-executable requires a non-empty path' >&2
    exit 2
  fi
  source_mode=true
  source_executable=$2
fi

if [ -z "$version" ]; then
  printf '%s\n' \
    '[git-hook-pure] GIT_HOOK_PURE_VERSION is required (for example: 4.0.0)' >&2
  exit 2
fi
if ! printf '%s\n' "$version" | grep -Eq "$semver_pattern"; then
  printf '[git-hook-pure] invalid GIT_HOOK_PURE_VERSION: %s\n' "$version" >&2
  exit 2
fi
case "$install_path" in
  -*)
    printf '%s\n' '[git-hook-pure] install target must not start with -' >&2
    exit 2
    ;;
  */)
    printf '%s\n' '[git-hook-pure] install target must name a file, not a directory' >&2
    exit 2
    ;;
  *\\*)
    printf '%s\n' '[git-hook-pure] install target must use / as its directory separator' >&2
    exit 2
    ;;
esac

install_path_display=$install_path
git_hook_pure_preflight_destination "$install_path" || exit $?
install_path=$git_hook_pure_normalized_destination
install_dir=$(dirname -- "$install_path")
mkdir -p "$install_dir"
stage_prefix=$install_dir/.git-hook-pure-download.$$
cleanup_stage() {
  status=$?
  trap - EXIT HUP INT QUIT PIPE TERM
  rm -rf "$stage_prefix".??????
  exit "$status"
}
trap cleanup_stage EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 141' PIPE
trap 'exit 143' TERM
stage_dir=$(mktemp -d "$stage_prefix.XXXXXX")

if [ "$source_mode" = true ]; then
  if [ ! -f "$source_executable" ] || [ -L "$source_executable" ]; then
    printf '[git-hook-pure] executable source must be a regular file: %s\n' \
      "$source_executable" >&2
    exit 1
  fi
  cp "$source_executable" "$stage_dir/git-hook-pure"
else
  asset_url=$release_base_url/v$version
  curl -fsSL "$asset_url/git-hook-pure" -o "$stage_dir/git-hook-pure"
  curl -fsSL "$asset_url/SHA256SUMS" -o "$stage_dir/SHA256SUMS"

  expected_lines=$(awk '
    {
      name = $2
      sub(/\r$/, "", name)
      sub(/^\*/, "", name)
      if (name == "git-hook-pure") print $1
    }
  ' "$stage_dir/SHA256SUMS")
  expected=$(printf '%s\n' "$expected_lines" | sed -n '1p')
  extra_expected=$(printf '%s\n' "$expected_lines" | sed -n '2p')
  if [ -z "$expected" ] || [ -n "$extra_expected" ] ||
    ! printf '%s\n' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$'; then
    printf '%s\n' '[git-hook-pure] SHA256SUMS has no unique git-hook-pure entry' >&2
    exit 1
  fi
  expected=$(printf '%s\n' "$expected" | tr '[:upper:]' '[:lower:]')

  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$stage_dir/git-hook-pure" | awk '{ print $1 }')
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$stage_dir/git-hook-pure" | awk '{ print $1 }')
  else
    printf '%s\n' '[git-hook-pure] sha256sum or shasum is required' >&2
    exit 1
  fi

  if [ "$actual" != "$expected" ]; then
    printf '%s\n' '[git-hook-pure] downloaded executable failed SHA-256 verification' >&2
    exit 1
  fi
fi

chmod 755 "$stage_dir/git-hook-pure"
actual_version=$("$stage_dir/git-hook-pure" --version)
if [ "$actual_version" != "$version" ]; then
  printf '[git-hook-pure] staged executable version mismatch: expected %s, got %s\n' \
    "$version" "$actual_version" >&2
  exit 1
fi

"$stage_dir/git-hook-pure" install
mv -f "$stage_dir/git-hook-pure" "$install_path"
rm -rf "$stage_dir"
trap - EXIT HUP INT QUIT PIPE TERM
printf '[git-hook-pure] installed executable at %s\n' "$install_path_display"
