release_asset_entry_count() {
  local directory=$1 entry count=0

  for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

write_release_asset() {
  local path=$1

  printf '%s\n' '#!/bin/sh' 'printf release-asset' >"$path"
  chmod 755 "$path"
}

assert_no_release_asset_staging() {
  local directory=$1 residue

  for residue in "$directory"/.git-hook-pure-release-assets.*; do
    [ ! -e "$residue" ] && [ ! -L "$residue" ] ||
      fail "release asset preparation left staging state: $residue"
  done
}

test_prepare_release_assets_replaces_an_old_manifest_atomically() {
  local prepare assets old_manifest
  prepare="$repo_root/scripts/prepare-release-assets.sh"
  assets="$suite_tmp/release assets valid"
  mkdir -p "$assets"
  write_release_asset "$assets/git-hook-pure"
  printf '%s\n' old-manifest >"$assets/SHA256SUMS"
  old_manifest="$suite_tmp/old-release-manifest"
  cp -p "$assets/SHA256SUMS" "$old_manifest"

  (cd "$suite_tmp" && "$prepare" 'release assets valid' >/dev/null)

  [ -f "$assets/git-hook-pure" ] && [ ! -L "$assets/git-hook-pure" ] ||
    fail 'release preparation lost its executable asset'
  [ -x "$assets/git-hook-pure" ] || fail 'release preparation made its asset non-executable'
  [ -f "$assets/SHA256SUMS" ] && [ ! -L "$assets/SHA256SUMS" ] ||
    fail 'release preparation did not publish a regular checksum manifest'
  [ "$(release_asset_entry_count "$assets")" -eq 2 ] ||
    fail 'prepared release directory does not contain exactly two assets'
  if cmp -s "$old_manifest" "$assets/SHA256SUMS"; then
    fail 'release preparation did not replace the old checksum manifest'
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$assets" && sha256sum -c SHA256SUMS >/dev/null)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$assets" && shasum -a 256 -c SHA256SUMS >/dev/null)
  else
    fail 'test host has no SHA-256 verifier'
  fi
  assert_no_release_asset_staging "$assets"
}

test_prepare_release_assets_rejects_invalid_inventory_without_touching_manifest() {
  local prepare kind assets manifest manifest_snapshot manifest_mode target output status
  prepare="$repo_root/scripts/prepare-release-assets.sh"

  for kind in \
    missing-binary binary-directory binary-symlink non-executable \
    extra-file extra-directory extra-symlink hidden-file hidden-directory \
    manifest-symlink; do
    assets="$suite_tmp/release-assets-invalid-$kind"
    mkdir -p "$assets"
    manifest="$assets/SHA256SUMS"
    if [ "$kind" = manifest-symlink ]; then
      target="$suite_tmp/$kind-target"
      printf '%s\n' "old-$kind-manifest" >"$target"
      chmod 640 "$target"
      ln -s "$target" "$manifest"
      manifest_snapshot="$suite_tmp/$kind-manifest-snapshot"
      cp -p "$target" "$manifest_snapshot"
      manifest_mode=$(file_mode "$target")
    else
      printf '%s\n' "old-$kind-manifest" >"$manifest"
      chmod 640 "$manifest"
      manifest_snapshot="$suite_tmp/$kind-manifest-snapshot"
      cp -p "$manifest" "$manifest_snapshot"
      manifest_mode=$(file_mode "$manifest")
    fi

    case "$kind" in
      missing-binary) ;;
      binary-directory) mkdir "$assets/git-hook-pure" ;;
      binary-symlink)
        target="$suite_tmp/$kind-target-binary"
        write_release_asset "$target"
        ln -s "$target" "$assets/git-hook-pure"
        ;;
      non-executable)
        printf '%s\n' '#!/bin/sh' ':' >"$assets/git-hook-pure"
        chmod 644 "$assets/git-hook-pure"
        ;;
      *) write_release_asset "$assets/git-hook-pure" ;;
    esac
    case "$kind" in
      extra-file) printf '%s\n' extra >"$assets/extra" ;;
      extra-directory) mkdir "$assets/extra" ;;
      extra-symlink)
        printf '%s\n' extra >"$suite_tmp/$kind-target"
        ln -s "$suite_tmp/$kind-target" "$assets/extra"
        ;;
      hidden-file) printf '%s\n' hidden >"$assets/.hidden" ;;
      hidden-directory) mkdir "$assets/.hidden" ;;
    esac

    set +e
    output=$("$prepare" "$assets" 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "release preparation accepted invalid inventory: $kind"
    case "$output" in *'[release-assets]'*) ;;
      *) fail "invalid release inventory had no prefixed diagnostic ($kind): $output" ;;
    esac
    if [ "$kind" = manifest-symlink ]; then
      [ -L "$manifest" ] || fail 'release preparation replaced an old-manifest symlink'
      assert_files_equal "$manifest_snapshot" "$target"
      [ "$(file_mode "$target")" = "$manifest_mode" ] ||
        fail 'release preparation changed an old-manifest symlink target mode'
    else
      assert_files_equal "$manifest_snapshot" "$manifest"
      [ "$(file_mode "$manifest")" = "$manifest_mode" ] ||
        fail "release preparation changed old manifest mode after rejecting $kind"
    fi
    assert_no_release_asset_staging "$assets"
  done
}

test_prepare_release_assets_verifies_before_publishing_the_manifest() {
  local prepare fake_bin real_checksum real_kind behavior assets manifest snapshot
  local manifest_mode output status
  prepare="$repo_root/scripts/prepare-release-assets.sh"
  fake_bin="$suite_tmp/release-checksum-bin"
  mkdir -p "$fake_bin"
  if command -v sha256sum >/dev/null 2>&1; then
    real_checksum=$(command -v sha256sum)
    real_kind=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    real_checksum=$(command -v shasum)
    real_kind=shasum
  else
    fail 'test host has no SHA-256 command for mismatch verification'
  fi
  cat >"$fake_bin/sha256sum" <<'EOF'
#!/bin/sh
case "$TEST_CHECKSUM_BEHAVIOR" in
  generation-failure) exit 74 ;;
  check-failure)
    [ "${1:-}" != -c ] || exit 75
    ;;
  mismatch)
    if [ "${1:-}" != -c ]; then
      printf '%064d  git-hook-pure\n' 0
      exit 0
    fi
    ;;
esac
if [ "$REAL_CHECKSUM_KIND" = sha256sum ]; then
  exec "$REAL_CHECKSUM" "$@"
fi
if [ "${1:-}" = -c ]; then
  shift
  exec "$REAL_CHECKSUM" -a 256 -c "$@"
fi
exec "$REAL_CHECKSUM" -a 256 "$@"
EOF
  chmod +x "$fake_bin/sha256sum"

  for behavior in mismatch check-failure generation-failure; do
    assets="$suite_tmp/release-checksum-$behavior"
    mkdir -p "$assets"
    write_release_asset "$assets/git-hook-pure"
    manifest="$assets/SHA256SUMS"
    printf '%s\n' "old-$behavior-manifest" >"$manifest"
    chmod 640 "$manifest"
    snapshot="$suite_tmp/$behavior-manifest-snapshot"
    cp -p "$manifest" "$snapshot"
    manifest_mode=$(file_mode "$manifest")

    set +e
    output=$(
      PATH="$fake_bin:$PATH" \
        REAL_CHECKSUM="$real_checksum" REAL_CHECKSUM_KIND="$real_kind" \
        TEST_CHECKSUM_BEHAVIOR="$behavior" \
        "$prepare" "$assets" 2>&1
    )
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "release preparation accepted checksum $behavior"
    case "$output" in *'[release-assets]'*) ;;
      *) fail "checksum $behavior had no prefixed diagnostic: $output" ;;
    esac
    assert_files_equal "$snapshot" "$manifest"
    [ "$(file_mode "$manifest")" = "$manifest_mode" ] ||
      fail "checksum $behavior changed the old manifest mode"
    assert_no_release_asset_staging "$assets"
  done
}

run_prepare_release_assets_integration_tests() {
  run_test test_prepare_release_assets_replaces_an_old_manifest_atomically
  run_test test_prepare_release_assets_rejects_invalid_inventory_without_touching_manifest
  run_test test_prepare_release_assets_verifies_before_publishing_the_manifest
}
