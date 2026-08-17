#!/bin/sh

set -eu

script_path=$0
while [ -L "$script_path" ]; do
  link_dir=$(CDPATH= cd -P -- "$(dirname -- "$script_path")" && pwd)
  link_target=$(readlink "$script_path")
  case "$link_target" in
    /*) script_path=$link_target ;;
    *) script_path=$link_dir/$link_target ;;
  esac
done
script_dir=$(CDPATH= cd -P -- "$(dirname -- "$script_path")" && pwd)
package_root=$(CDPATH= cd -P -- "$script_dir/.." && pwd)
bundle=$package_root/dist/git-hook-pure

npm_help() {
  "$bundle" --help
  printf '%s\n' \
    '' \
    'npm package command:' \
    '  install-standalone [<repository-relative-path>]' \
    '                             Vendor the packaged executable into this repository'
}

case "${1:-}" in
  '')
    npm_help
    exit 0
    ;;
  help|-h|--help)
    [ "$#" -eq 1 ] || {
      printf '%s\n' 'Usage: npx git-hook-pure [help|-h|--help]' >&2
      exit 2
    }
    npm_help
    exit 0
    ;;
esac

if [ "${1:-}" = install-standalone ]; then
  shift
  case "${1:-}" in
    help|-h|--help)
      [ "$#" -eq 1 ] || {
        printf '%s\n' \
          'Usage: npx git-hook-pure install-standalone [<repository-relative-path>]' >&2
        exit 2
      }
      printf '%s\n' \
        'Usage: npx git-hook-pure install-standalone [<repository-relative-path>]' \
        '' \
        'Vendor the packaged executable into the current Git repository.' \
        'The default destination is tools/git-hook-pure.'
      exit 0
      ;;
  esac
  if [ "$#" -gt 1 ]; then
    printf '%s\n' \
      'Usage: npx git-hook-pure install-standalone [<repository-relative-path>]' >&2
    exit 2
  fi

  if [ "$#" -eq 0 ]; then
    install_path=tools/git-hook-pure
  else
    install_path=$1
    if [ -z "$install_path" ]; then
      printf '%s\n' '[git-hook-pure] standalone path must not be empty' >&2
      exit 2
    fi
  fi
  case "$install_path" in
    */)
      printf '%s\n' '[git-hook-pure] standalone path must name a file, not a directory' >&2
      exit 2
      ;;
    *\\*)
      printf '%s\n' \
        '[git-hook-pure] standalone path must use / as its directory separator' >&2
      exit 2
      ;;
  esac
  case "$install_path" in
    ''|/*|[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:/*)
      printf '%s\n' '[git-hook-pure] standalone path must be relative to the repository' >&2
      exit 2
      ;;
  esac
  case "/$install_path/" in
    */../*)
      printf '%s\n' '[git-hook-pure] standalone path must not contain ..' >&2
      exit 2
      ;;
  esac

  repo_root=$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || {
    printf '%s\n' '[git-hook-pure] not inside a Git worktree' >&2
    exit 1
  }
  version=$("$bundle" --version)
  GIT_HOOK_PURE_VERSION=$version \
    INSTALL_PATH=$repo_root/$install_path \
    sh "$package_root/install-standalone.sh" --source-executable "$bundle"
  exit
fi

exec "$bundle" "$@"
