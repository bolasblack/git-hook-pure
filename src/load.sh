#!/bin/sh

git_hook_pure_load() {
  local root module manifest

  if [ "$#" -ne 1 ]; then
    printf '%s\n' '[git-hook-pure] source loader requires the src directory' >&2
    return 2
  fi

  root=$1
  manifest=$root/modules.list
  if [ ! -f "$manifest" ]; then
    printf '[git-hook-pure] missing source module manifest: %s\n' "$manifest" >&2
    return 1
  fi
  while IFS= read -r module; do
    [ -n "$module" ] || continue
    if [ ! -f "$root/$module" ]; then
      printf '[git-hook-pure] missing source module: %s\n' "$root/$module" >&2
      return 1
    fi
    . "$root/$module"
  done <"$manifest"
}
