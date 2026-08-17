#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' 'Usage: scripts/prepare-release-assets.sh <asset-directory>' >&2
  exit 2
fi

asset_dir=$1
asset=$asset_dir/git-hook-pure
manifest=$asset_dir/SHA256SUMS

if [ ! -d "$asset_dir" ] || [ -L "$asset_dir" ]; then
  printf '[release-assets] asset directory must be an ordinary directory: %s\n' \
    "$asset_dir" >&2
  exit 1
fi

validate_asset_inventory() {
  inventory_manifest_required=$1
  inventory_asset_seen=false
  inventory_manifest_seen=false

  for inventory_entry in \
    "$asset_dir"/* "$asset_dir"/.[!.]* "$asset_dir"/..?*; do
    [ -e "$inventory_entry" ] || [ -L "$inventory_entry" ] || continue
    inventory_name=${inventory_entry##*/}
    case "$inventory_name" in
      git-hook-pure)
        if [ ! -f "$inventory_entry" ] || [ -L "$inventory_entry" ] ||
          [ ! -x "$inventory_entry" ]; then
          printf '[release-assets] git-hook-pure must be a regular executable: %s\n' \
            "$inventory_entry" >&2
          return 1
        fi
        inventory_asset_seen=true
        ;;
      SHA256SUMS)
        if [ ! -f "$inventory_entry" ] || [ -L "$inventory_entry" ]; then
          printf '[release-assets] existing checksum manifest must be a regular file: %s\n' \
            "$inventory_entry" >&2
          return 1
        fi
        inventory_manifest_seen=true
        ;;
      *)
        printf '[release-assets] unexpected release asset: %s\n' "$inventory_entry" >&2
        return 1
        ;;
    esac
  done

  if [ "$inventory_asset_seen" != true ]; then
    printf '[release-assets] missing git-hook-pure release asset: %s\n' "$asset" >&2
    return 1
  fi
  if [ "$inventory_manifest_required" = true ] &&
    [ "$inventory_manifest_seen" != true ]; then
    printf '[release-assets] missing checksum manifest: %s\n' "$manifest" >&2
    return 1
  fi
}

validate_asset_inventory false || exit $?

if command -v sha256sum >/dev/null 2>&1; then
  checksum_kind=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  checksum_kind=shasum
else
  printf '%s\n' '[release-assets] sha256sum or shasum is required' >&2
  exit 1
fi

stage=$(mktemp "$asset_dir/.git-hook-pure-release-assets.XXXXXX") || {
  printf '[release-assets] unable to stage checksum manifest in %s\n' "$asset_dir" >&2
  exit 1
}
cleanup_stage() {
  status=$?
  trap - 0 HUP INT QUIT PIPE TERM
  [ -z "$stage" ] || rm -f "$stage"
  exit "$status"
}
trap cleanup_stage 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 141' PIPE
trap 'exit 143' TERM

if [ "$checksum_kind" = sha256sum ]; then
  if ! (cd "$asset_dir" && sha256sum git-hook-pure) >"$stage"; then
    printf '%s\n' '[release-assets] unable to generate SHA-256 manifest' >&2
    exit 1
  fi
else
  if ! (cd "$asset_dir" && shasum -a 256 git-hook-pure) >"$stage"; then
    printf '%s\n' '[release-assets] unable to generate SHA-256 manifest' >&2
    exit 1
  fi
fi
stage_name=${stage##*/}
if [ "$checksum_kind" = sha256sum ]; then
  if ! (cd "$asset_dir" && sha256sum -c "$stage_name") >/dev/null; then
    printf '%s\n' '[release-assets] staged SHA-256 manifest did not verify' >&2
    exit 1
  fi
else
  if ! (cd "$asset_dir" && shasum -a 256 -c "$stage_name") >/dev/null; then
    printf '%s\n' '[release-assets] staged SHA-256 manifest did not verify' >&2
    exit 1
  fi
fi
chmod 644 "$stage" || {
  printf '%s\n' '[release-assets] unable to set checksum manifest mode' >&2
  exit 1
}
mv -f "$stage" "$manifest" || {
  printf '[release-assets] unable to publish checksum manifest: %s\n' "$manifest" >&2
  exit 1
}
stage=
trap - 0 HUP INT QUIT PIPE TERM
validate_asset_inventory true || exit $?
printf '[release-assets] prepared git-hook-pure and SHA256SUMS in %s\n' "$asset_dir"
