#!/bin/sh

# HIDDEN CONTEXT: Automatic hook setup is best-effort and must not fail npm installation.
set -u

if [ "${npm_command:-}" = exec ]; then
  printf '%s\n' \
    '[git-hook-pure] automatic Git hook installation skipped for npm exec/npx.'
  exit 0
fi

if [ "${GIT_HOOK_PURE_SKIP_INSTALL:-}" = 1 ]; then
  printf '%s\n' \
    '[git-hook-pure] automatic Git hook installation skipped.' \
    '[git-hook-pure] Install later with: npx git-hook-pure install'
  exit 0
fi

if [ "${npm_config_global:-false}" = true ]; then
  printf '%s\n' '[git-hook-pure] automatic Git hook installation skipped for a global npm install.'
  exit 0
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cli=$script_dir/../dist/git-hook-pure

if "$cli" install; then
  printf '%s\n' \
    '[git-hook-pure] Git hooks installed automatically.' \
    '[git-hook-pure] Uninstall them with: npx git-hook-pure uninstall' \
    '[git-hook-pure] Skip automatic installation with: GIT_HOOK_PURE_SKIP_INSTALL=1 npm install'
  exit 0
fi

printf '%s\n' \
  '[git-hook-pure] automatic Git hook installation did not take effect.' \
  '[git-hook-pure] Fix the reported problem, then run: npx git-hook-pure install' \
  '[git-hook-pure] Skip automatic installation with: GIT_HOOK_PURE_SKIP_INSTALL=1 npm install' >&2
exit 0
