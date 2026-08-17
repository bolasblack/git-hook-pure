test_release_identity_requires_matching_tag_version_and_note() {
  local check output status mismatch_version mismatch_tag
  check="$repo_root/scripts/check-release.sh"
  "$check" "$package_tag" >/dev/null

  mismatch_version=0.0.0
  [ "$mismatch_version" != "$package_version" ] || mismatch_version=0.0.1
  mismatch_tag=v$mismatch_version

  set +e
  output=$("$check" "$mismatch_tag" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'release check accepted a tag that mismatches package.json'
  case "$output" in *"$package_version"*"$mismatch_version"*|*"$mismatch_version"*"$package_version"*) ;;
    *) fail 'release mismatch diagnostic omitted the two versions' ;;
  esac

  set +e
  "$check" "$package_version" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail 'release check accepted a tag without the v prefix'

  set +e
  "$check" v01.2.3 >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail 'release check accepted a non-semantic tag version'
}

test_tagged_release_identity_requires_the_exact_tag_commit() {
  local fixture check output status
  fixture="$suite_tmp/tagged-release-identity"
  mkdir -p "$fixture/scripts" "$fixture/docs/releases"
  cp -p "$repo_root/scripts/check-release.sh" "$fixture/scripts/check-release.sh"
  cp -p "$repo_root/scripts/version.sh" "$fixture/scripts/version.sh"
  cp -p "$repo_root/package.json" "$fixture/package.json"
  cp -p "$repo_root/docs/releases/$package_tag.md" \
    "$fixture/docs/releases/$package_tag.md"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Git Hook Pure Tests'
  git -C "$fixture" config user.email 'git-hook-pure@example.invalid'
  git -C "$fixture" add .
  git -C "$fixture" commit -qm 'release identity fixture'
  check="$fixture/scripts/check-release.sh"

  "$check" "$package_tag" >/dev/null
  set +e
  output=$("$check" --tagged "$package_tag" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'tagged release check accepted a missing tag'
  case "$output" in *'[release]'*tag*) ;;
    *) fail "missing release tag had no actionable diagnostic: $output" ;;
  esac

  git -C "$fixture" tag -a "$package_tag" -m "$package_tag"
  "$check" --tagged "$package_tag" >/dev/null

  printf '%s\n' 'post-tag change' >"$fixture/post-tag-change"
  git -C "$fixture" add post-tag-change
  git -C "$fixture" commit -qm 'commit after release tag'
  set +e
  output=$("$check" --tagged "$package_tag" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'tagged release check accepted HEAD after the tag commit'
  case "$output" in *'[release]'*HEAD*"$package_tag"*) ;;
    *) fail "tag/HEAD mismatch had no actionable diagnostic: $output" ;;
  esac
}

run_check_release_integration_tests() {
  run_test test_release_identity_requires_matching_tag_version_and_note
  run_test test_tagged_release_identity_requires_the_exact_tag_commit
}
