#!/bin/sh

set -eu

build_usage() {
  cat <<'EOF'
Usage: scripts/build.sh [--output <path>]

Build the self-contained git-hook-pure executable.
The default output is dist/git-hook-pure.
EOF
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
src_dir=$repo_root/src
module_manifest=$src_dir/modules.list
package_file=$repo_root/package.json
output=$repo_root/dist/git-hook-pure
. "$script_dir/version.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || {
        printf '%s\n' '[build] --output requires a path' >&2
        build_usage >&2
        exit 2
      }
      output=$2
      shift 2
      ;;
    -h|--help)
      build_usage
      exit 0
      ;;
    *)
      printf '[build] unknown argument: %s\n' "$1" >&2
      build_usage >&2
      exit 2
      ;;
  esac
done

[ -f "$module_manifest" ] || { printf '[build] missing module manifest: %s\n' "$module_manifest" >&2; exit 1; }
[ -f "$package_file" ] || { printf '[build] missing package manifest: %s\n' "$package_file" >&2; exit 1; }

if ! version=$(git_hook_pure_read_package_version "$package_file"); then
  printf '%s\n' '[build] package.json must contain exactly one valid semantic version' >&2
  exit 1
fi

placeholder_count=0
module_count=0
while IFS= read -r module; do
  [ -n "$module" ] || continue
  source_file=$src_dir/$module
  [ -f "$source_file" ] || { printf '[build] missing source module: %s\n' "$source_file" >&2; exit 1; }
  module_placeholders=$(
    awk '{ count += gsub(/@GIT_HOOK_PURE_VERSION@/, "") } END { print count + 0 }' "$source_file"
  )
  placeholder_count=$((placeholder_count + module_placeholders))
  module_count=$((module_count + 1))
done <"$module_manifest"
[ "$module_count" -gt 0 ] || { printf '%s\n' '[build] module manifest is empty' >&2; exit 1; }
if [ "$placeholder_count" -ne 1 ]; then
  printf '[build] expected one version placeholder across source modules, found %s\n' \
    "$placeholder_count" >&2
  exit 1
fi

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir"
if [ -d "$output" ] || [ -L "$output" ] ||
  { [ -e "$output" ] && [ ! -f "$output" ]; }; then
  printf '[build] output must be a regular file path: %s\n' "$output" >&2
  exit 1
fi
stage_prefix=$output_dir/.git-hook-pure-build.$$
cleanup_stage() {
  rm -f "$stage_prefix".??????
}
trap cleanup_stage EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 141' PIPE
trap 'exit 143' TERM
stage=$(mktemp "$stage_prefix.XXXXXX")

printf '#!/bin/sh\n\nset -eu\n\n' >"$stage"
while IFS= read -r module; do
  [ -n "$module" ] || continue
  LC_ALL=C sed "s/@GIT_HOOK_PURE_VERSION@/$version/" "$src_dir/$module" >>"$stage"
  printf '\n' >>"$stage"
done <"$module_manifest"
printf '%s\n' 'git_hook_pure_main "$@"' >>"$stage"
chmod 755 "$stage"
sh -n "$stage"
actual_version=$("$stage" --version)
if [ "$actual_version" != "$version" ]; then
  printf '[build] artifact version mismatch: expected %s, got %s\n' \
    "$version" "$actual_version" >&2
  exit 1
fi

mv -f "$stage" "$output"
trap - EXIT HUP INT QUIT PIPE TERM
printf '[build] wrote %s\n' "$output"
