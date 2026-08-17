write_sha256_manifest() {
  local file=$1
  local manifest=$2
  local name
  name=$(basename -- "$file")

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname -- "$file")" && sha256sum "$name") >"$manifest"
  else
    printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{ print $1 }')" "$name" >"$manifest"
  fi
}

ensure_standalone_destination_source() {
  if [ -z "${standalone_destination_source:-}" ]; then
    standalone_destination_source="$suite_tmp/standalone-destination-source"
    "$repo_root/scripts/build.sh" --output "$standalone_destination_source" >/dev/null
  fi
}

assert_no_standalone_install_side_effects() {
  local repo=$1
  local output=$2
  local git_dir

  case "$output" in
    *'installed hooks'*|*'installed executable'*)
      fail "rejected standalone destination printed success: $output"
      ;;
  esac
  [ ! -e "$repo/.githooks" ] || fail 'rejected standalone destination created .githooks'
  git_dir=$(git -C "$repo" rev-parse --absolute-git-dir)
  if grep -Rqs 'git-hook-pure start' "$git_dir/hooks"; then
    fail 'rejected standalone destination installed managed hooks'
  fi
  [ -z "$(find "$repo" -name '.git-hook-pure-download.*' -print | sed -n '1p')" ] ||
    fail 'rejected standalone destination left staging state'
}

prepare_standalone_rejection_fixture() {
  local repo=$1
  local label=$2

  standalone_fixture_git_dir=$(git -C "$repo" rev-parse --absolute-git-dir)
  standalone_fixture_config="$standalone_fixture_git_dir/config"
  standalone_fixture_config_snapshot="$suite_tmp/$label.config"
  cp -p "$standalone_fixture_config" "$standalone_fixture_config_snapshot"
  standalone_fixture_config_mode=$(file_mode "$standalone_fixture_config")

  standalone_fixture_hook="$standalone_fixture_git_dir/hooks/pre-commit"
  standalone_fixture_hook_snapshot="$suite_tmp/$label.hook"
  printf '%s\n' '#!/bin/sh' "# $label" 'exit 29' >"$standalone_fixture_hook"
  chmod 751 "$standalone_fixture_hook"
  cp -p "$standalone_fixture_hook" "$standalone_fixture_hook_snapshot"
  standalone_fixture_hook_mode=$(file_mode "$standalone_fixture_hook")
}

run_standalone_source_install() {
  local repo=$1
  local caller_cwd=$2
  local target=$3

  ensure_standalone_destination_source
  set +e
  standalone_install_output=$(
    cd "$caller_cwd"
    GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH="$target" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" \
      --source-executable "$standalone_destination_source" 2>&1
  )
  standalone_install_status=$?
  set -e
}

assert_standalone_rejection_preserved() {
  local repo=$1
  local output=$2

  [ "$standalone_install_status" -ne 0 ] ||
    fail "standalone installer accepted an unsafe destination: $output"
  printf '%s\n' "$output" | grep -Eq '^\[git-hook-pure\] .+' ||
    fail "unsafe standalone destination lacked a prefixed actionable diagnostic: $output"
  assert_files_equal "$standalone_fixture_config_snapshot" "$standalone_fixture_config"
  [ "$(file_mode "$standalone_fixture_config")" = "$standalone_fixture_config_mode" ] ||
    fail 'rejected standalone destination changed Git config mode'
  assert_files_equal "$standalone_fixture_hook_snapshot" "$standalone_fixture_hook"
  [ "$(file_mode "$standalone_fixture_hook")" = "$standalone_fixture_hook_mode" ] ||
    fail 'rejected standalone destination changed the user hook mode'
  git -C "$repo" status >/dev/null || fail 'rejected standalone destination broke Git'
  assert_no_standalone_install_side_effects "$repo" "$output"
}

test_install_standalone_rejects_git_config_before_side_effects() {
  local repo source config original_config hook original_hook output status
  ensure_standalone_destination_source
  source=$standalone_destination_source
  repo=$(new_repo standalone-git-config-destination)
  config="$repo/.git/config"
  original_config="$suite_tmp/standalone-git-config.original"
  cp -p "$config" "$original_config"
  hook="$repo/.git/hooks/pre-commit"
  original_hook="$suite_tmp/standalone-git-config-hook.original"
  printf '%s\n' '#!/bin/sh' 'exit 29' >"$hook"
  chmod 751 "$hook"
  cp -p "$hook" "$original_hook"

  set +e
  output=$(
    cd "$repo"
    GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH=.git/config \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable "$source" 2>&1
  )
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'standalone installer accepted .git/config as its target'
  case "$output" in *'Git administrative'*) ;;
    *) fail "Git administrative destination had no actionable diagnostic: $output" ;;
  esac
  assert_files_equal "$original_config" "$config"
  [ "$(file_mode "$config")" = "$(file_mode "$original_config")" ] ||
    fail 'rejected .git/config destination changed config mode'
  assert_files_equal "$original_hook" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original_hook")" ] ||
    fail 'rejected .git/config destination changed hook mode'
  git -C "$repo" status >/dev/null || fail 'rejected .git/config destination broke Git'
  assert_no_standalone_install_side_effects "$repo" "$output"
}

test_install_standalone_rejects_absent_and_case_varied_git_admin_paths() {
  local repo target case_alias

  repo=$(new_repo standalone-absent-git-admin-destination)
  prepare_standalone_rejection_fixture "$repo" standalone-absent-git-admin
  target="$repo/.git/info/git-hook-pure"
  [ ! -e "$target" ] || fail 'absent Git-admin fixture unexpectedly exists'
  run_standalone_source_install "$repo" "$repo" .git/info/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ ! -e "$target" ] || fail 'rejected absent Git-admin target was created'

  repo=$(new_repo standalone-case-varied-git-admin-destination)
  prepare_standalone_rejection_fixture "$repo" standalone-case-varied-git-admin
  case_alias=false
  [ ! -e "$repo/.GIT/config" ] || case_alias=true
  run_standalone_source_install "$repo" "$repo" .GIT/config
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  if [ "$case_alias" = false ]; then
    [ ! -e "$repo/.GIT" ] || fail 'case-varied Git-admin rejection created .GIT'
  fi
}

test_install_standalone_rejects_git_admin_components_before_dot_dot() {
  local repo spelling target

  for spelling in .git .GIT; do
    repo=$(new_repo "standalone-git-admin-before-dot-dot-${spelling#.}")
    target="$repo/tools/git-hook-pure"
    prepare_standalone_rejection_fixture \
      "$repo" "standalone-git-admin-before-dot-dot-${spelling#.}"
    run_standalone_source_install "$repo" "$repo" "$spelling/../tools/git-hook-pure"
    assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
    [ ! -e "$target" ] || fail "Git-admin component before .. created its target: $spelling"
  done
}

test_install_standalone_rejects_separate_git_admin_paths() {
  local repo metadata case_alias
  repo="$suite_tmp/standalone-separate-git-admin-destination"
  metadata="$repo/.metadata"
  mkdir -p "$repo/home"
  git init -q --separate-git-dir="$metadata" "$repo"
  git -C "$repo" config user.name 'Git Hook Pure Tests'
  git -C "$repo" config user.email 'git-hook-pure@example.invalid'
  git -C "$repo" config core.worktree "$repo"

  prepare_standalone_rejection_fixture "$repo" standalone-separate-git-admin
  run_standalone_source_install "$repo" "$repo" .metadata/config
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"

  run_standalone_source_install "$repo" "$repo" .metadata/../tools/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ ! -e "$repo/tools/git-hook-pure" ] ||
    fail 'separate Git-admin component before .. created its target'

  case_alias=false
  [ ! -e "$repo/.METADATA/config" ] || case_alias=true
  run_standalone_source_install "$repo" "$repo" .METADATA/config
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  if [ "$case_alias" = false ]; then
    [ ! -e "$repo/.METADATA" ] ||
      fail 'case-varied separate Git-admin rejection created .METADATA'
  fi
}

test_install_standalone_rejects_escaping_and_symlink_paths() {
  local repo outside target

  repo=$(new_repo standalone-symlink-ancestor)
  outside="$suite_tmp/standalone-symlink-outside"
  mkdir -p "$outside"
  ln -s "$outside" "$repo/tools"
  prepare_standalone_rejection_fixture "$repo" standalone-symlink-ancestor
  run_standalone_source_install "$repo" "$repo" tools/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ ! -e "$outside/git-hook-pure" ] || fail 'installer traversed an ancestor symlink'

  repo=$(new_repo standalone-relative-escape)
  outside="$suite_tmp/standalone-relative-outside"
  mkdir -p "$outside"
  prepare_standalone_rejection_fixture "$repo" standalone-relative-escape
  run_standalone_source_install \
    "$repo" "$repo" ../standalone-relative-outside/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ ! -e "$outside/git-hook-pure" ] || fail 'relative escape wrote outside the worktree'

  repo=$(new_repo standalone-prefix-boundary)
  outside="$repo-outside"
  mkdir -p "$outside"
  target="$outside/git-hook-pure"
  prepare_standalone_rejection_fixture "$repo" standalone-prefix-boundary
  run_standalone_source_install "$repo" "$repo" "$target"
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ ! -e "$target" ] || fail 'same-prefix absolute escape wrote outside the worktree'

  repo=$(new_repo standalone-compound-symlink-escape)
  outside="$suite_tmp/standalone-compound-link-target"
  mkdir -p "$outside"
  ln -s "$outside" "$repo/link"
  prepare_standalone_rejection_fixture "$repo" standalone-compound-symlink-escape
  run_standalone_source_install "$repo" "$repo" link/../escape/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  case "$standalone_install_output" in *symlink*) ;;
    *) fail 'compound path did not reject its symlink before processing ..' ;;
  esac
  [ ! -e "$repo/escape" ] || fail 'compound symlink path created its lexical target'
  [ ! -e "$outside/git-hook-pure" ] || fail 'compound symlink path wrote outside'
}

test_install_standalone_rejects_invalid_existing_destination_nodes() {
  local repo outside parent_snapshot parent_mode symlink_target directory_mode

  repo=$(new_repo standalone-nondirectory-parent)
  printf '%s\n' project-file >"$repo/tools"
  chmod 640 "$repo/tools"
  parent_snapshot="$suite_tmp/standalone-nondirectory-parent.snapshot"
  cp -p "$repo/tools" "$parent_snapshot"
  parent_mode=$(file_mode "$repo/tools")
  prepare_standalone_rejection_fixture "$repo" standalone-nondirectory-parent
  run_standalone_source_install "$repo" "$repo" tools/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  assert_files_equal "$parent_snapshot" "$repo/tools"
  [ "$(file_mode "$repo/tools")" = "$parent_mode" ] ||
    fail 'non-directory parent mode was changed'

  repo=$(new_repo standalone-final-symlink)
  outside="$suite_tmp/standalone-final-symlink-outside"
  mkdir -p "$repo/tools" "$outside"
  ln -s "$outside/target" "$repo/tools/git-hook-pure"
  symlink_target=$(readlink "$repo/tools/git-hook-pure")
  prepare_standalone_rejection_fixture "$repo" standalone-final-symlink
  run_standalone_source_install "$repo" "$repo" tools/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ -L "$repo/tools/git-hook-pure" ] || fail 'final destination symlink was replaced'
  [ "$(readlink "$repo/tools/git-hook-pure")" = "$symlink_target" ] ||
    fail 'final destination symlink target was changed'
  [ ! -e "$outside/target" ] || fail 'final destination symlink was followed'

  repo=$(new_repo standalone-final-directory)
  mkdir -p "$repo/tools/git-hook-pure"
  printf '%s\n' project-content >"$repo/tools/git-hook-pure/sentinel"
  chmod 750 "$repo/tools/git-hook-pure"
  directory_mode=$(file_mode "$repo/tools/git-hook-pure")
  prepare_standalone_rejection_fixture "$repo" standalone-final-directory
  run_standalone_source_install "$repo" "$repo" tools/git-hook-pure
  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ -d "$repo/tools/git-hook-pure" ] || fail 'final destination directory was replaced'
  [ "$(cat "$repo/tools/git-hook-pure/sentinel")" = project-content ] ||
    fail 'final destination directory content was changed'
  [ "$(file_mode "$repo/tools/git-hook-pure")" = "$directory_mode" ] ||
    fail 'final destination directory mode was changed'
}

test_install_standalone_rejects_before_download() {
  local repo target stub_bin curl_called mkdir_called real_mkdir
  repo=$(new_repo standalone-unsafe-before-download)
  target="$repo/.git/info/git-hook-pure"
  stub_bin="$suite_tmp/standalone-curl-sentinel-bin"
  curl_called="$suite_tmp/standalone-unsafe-curl-called"
  mkdir_called="$suite_tmp/standalone-unsafe-mkdir-called"
  real_mkdir=$(command -v mkdir)
  mkdir -p "$stub_bin"
  cat >"$stub_bin/curl" <<'EOF'
#!/bin/sh
: >"$CURL_CALLED"
exit 73
EOF
  chmod +x "$stub_bin/curl"
  cat >"$stub_bin/mkdir" <<'EOF'
#!/bin/sh
: >"$MKDIR_CALLED"
exec "$REAL_MKDIR" "$@"
EOF
  chmod +x "$stub_bin/mkdir"
  prepare_standalone_rejection_fixture "$repo" standalone-unsafe-before-download

  set +e
  standalone_install_output=$(
    cd "$repo"
    PATH="$stub_bin:$PATH" CURL_CALLED="$curl_called" \
      MKDIR_CALLED="$mkdir_called" REAL_MKDIR="$real_mkdir" \
      GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH=.git/info/git-hook-pure \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" 2>&1
  )
  standalone_install_status=$?
  set -e

  assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
  [ ! -e "$curl_called" ] || fail 'unsafe standalone destination reached curl'
  [ ! -e "$mkdir_called" ] || fail 'unsafe standalone destination reached mkdir'
  [ ! -e "$target" ] || fail 'unsafe download destination was created'
}

test_install_standalone_preserves_direct_path_semantics() {
  local repo caller target outside absolute_spelling
  ensure_standalone_destination_source

  repo=$(new_repo standalone-nested-relative-success)
  caller="$repo/nested/caller"
  target="$caller/bin/git-hook-pure"
  mkdir -p "$caller"
  run_standalone_source_install "$repo" "$caller" bin/git-hook-pure
  [ "$standalone_install_status" -eq 0 ] ||
    fail "nested cwd-relative standalone install failed: $standalone_install_output"
  assert_files_equal "$standalone_destination_source" "$target"
  [ ! -e "$repo/bin/git-hook-pure" ] ||
    fail 'direct relative standalone path was incorrectly repository-relative'
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" ||
    fail 'nested cwd-relative standalone install did not set up hooks'

  repo=$(new_repo standalone-benign-dot-dot-success)
  caller="$repo/nested/caller"
  target="$repo/nested/bin/git-hook-pure"
  mkdir -p "$caller"
  run_standalone_source_install "$repo" "$caller" ../tools/../bin/git-hook-pure
  [ "$standalone_install_status" -eq 0 ] ||
    fail "benign .. standalone install failed: $standalone_install_output"
  assert_files_equal "$standalone_destination_source" "$target"
  [ ! -e "$repo/nested/tools" ] || fail 'benign .. path created an intermediate directory'
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" ||
    fail 'benign .. standalone install did not set up hooks'

  repo=$(new_repo standalone-absolute-normalized-success)
  outside="$repo-outside"
  mkdir -p "$outside"
  target="$repo/bin/git-hook-pure"
  absolute_spelling="${repo%/*}//${repo##*/}-outside/../${repo##*/}/temporary/../bin/git-hook-pure"
  run_standalone_source_install "$repo" "$repo" "$absolute_spelling"
  [ "$standalone_install_status" -eq 0 ] ||
    fail "normalized absolute standalone install failed: $standalone_install_output"
  assert_files_equal "$standalone_destination_source" "$target"
  [ ! -e "$outside/git-hook-pure" ] ||
    fail 'normalized absolute path published into its transient outside component'
  [ ! -e "$repo/temporary" ] ||
    fail 'normalized absolute path created an intermediate directory'
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" ||
    fail 'normalized absolute standalone install did not set up hooks'
}

test_install_standalone_rejects_malformed_successful_git_paths() {
  local source shim_bin real_git real_cp real_mkdir query repo target marker
  local copy_marker mkdir_marker
  ensure_standalone_destination_source
  source=$standalone_destination_source
  shim_bin="$suite_tmp/standalone-old-git-bin"
  real_git=$(command -v git)
  real_cp=$(command -v cp)
  real_mkdir=$(command -v mkdir)
  mkdir -p "$shim_bin"
  cat >"$shim_bin/git" <<'EOF'
#!/bin/sh
if [ "$#" -eq 3 ] && [ "$1" = rev-parse ] &&
  [ "$2" = --path-format=absolute ] && [ "$3" = "$INJECT_QUERY" ]; then
  : >"$INJECTION_MARKER"
  printf '%s\n' --path-format=absolute
  "$REAL_GIT" rev-parse "$3" || exit $?
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$shim_bin/git"
  cat >"$shim_bin/cp" <<'EOF'
#!/bin/sh
: >"$COPY_MARKER"
exec "$REAL_CP" "$@"
EOF
  chmod +x "$shim_bin/cp"
  cat >"$shim_bin/mkdir" <<'EOF'
#!/bin/sh
: >"$MKDIR_MARKER"
exec "$REAL_MKDIR" "$@"
EOF
  chmod +x "$shim_bin/mkdir"

  for query in --show-toplevel --git-dir --git-common-dir; do
    repo=$(new_repo "standalone-old-git-${query#--}")
    target="$repo/tools/git-hook-pure"
    marker="$suite_tmp/standalone-old-git-${query#--}.called"
    copy_marker="$suite_tmp/standalone-old-git-${query#--}.copied"
    mkdir_marker="$suite_tmp/standalone-old-git-${query#--}.mkdir"
    prepare_standalone_rejection_fixture "$repo" "standalone-old-git-${query#--}"
    set +e
    standalone_install_output=$(
      cd "$repo"
      PATH="$shim_bin:$PATH" REAL_GIT="$real_git" REAL_CP="$real_cp" \
        REAL_MKDIR="$real_mkdir" COPY_MARKER="$copy_marker" \
        MKDIR_MARKER="$mkdir_marker" INJECT_QUERY="$query" \
        INJECTION_MARKER="$marker" GIT_HOOK_PURE_VERSION="$package_version" \
        INSTALL_PATH=tools/git-hook-pure \
        HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        sh "$repo_root/install-standalone.sh" --source-executable "$source" 2>&1
    )
    standalone_install_status=$?
    set -e

    [ -e "$marker" ] || fail "old-Git shim did not intercept $query"
    assert_standalone_rejection_preserved "$repo" "$standalone_install_output"
    case "$standalone_install_output" in *'Git 2.31'*) ;;
      *) fail "malformed successful $query output lacked a capability diagnostic" ;;
    esac
    [ ! -e "$target" ] || fail "malformed successful $query query created its target"
    [ ! -e "$repo/tools" ] || fail "malformed successful $query query created its parent"
    [ ! -e "$copy_marker" ] || fail "malformed successful $query query copied the source"
    [ ! -e "$mkdir_marker" ] || fail "malformed successful $query query reached mkdir"
  done
}

test_install_standalone_fetches_a_versioned_verified_release_asset() {
  local assets version_dir expected stub_bin repo installed corrupt_assets previous status output
  local uppercase_assets uppercase_dir uppercase_hash
  local ordering_assets ordering_dir ordering_asset
  local convergence_assets convergence_dir convergence_asset signal_once
  local signal_bin real_mv
  assets="$suite_tmp/releases"
  version_dir="$assets/$package_tag"
  mkdir -p "$version_dir"
  expected="$version_dir/git-hook-pure"
  "$repo_root/scripts/build.sh" --output "$expected" >/dev/null
  write_sha256_manifest "$expected" "$version_dir/SHA256SUMS"

  stub_bin="$suite_tmp/curl-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/curl" <<'EOF'
#!/bin/sh
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  file://*) input=${url#file://} ;;
  *) exit 22 ;;
esac
[ -f "$input" ] || exit 22
if [ -n "$output" ]; then cp "$input" "$output"; else cat "$input"; fi
EOF
  chmod +x "$stub_bin/curl"

  repo=$(new_repo download-installer)
  installed="$repo/tool dir/git-hook-pure"
  (
    cd "$repo"
    PATH="$stub_bin:$PATH" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$assets" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" >/dev/null
  )
  assert_files_equal "$expected" "$installed"
  [ -x "$installed" ] || fail 'downloaded release asset is not executable'
  [ "$(find "$repo/tool dir" ! -path "$repo/tool dir" | wc -l | tr -d '[:space:]')" -eq 1 ] || \
    fail 'successful download left a staging path'
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" || \
    fail 'download installer did not run explicit hook setup'

  uppercase_assets="$suite_tmp/uppercase-releases"
  uppercase_dir="$uppercase_assets/$package_tag"
  mkdir -p "$uppercase_dir"
  cp "$expected" "$uppercase_dir/git-hook-pure"
  uppercase_hash=$(awk '{ print toupper($1) }' "$version_dir/SHA256SUMS")
  printf '%s  git-hook-pure\n' "$uppercase_hash" >"$uppercase_dir/SHA256SUMS"
  repo=$(new_repo uppercase-checksum-download)
  installed="$repo/tools/git-hook-pure"
  (
    cd "$repo"
    PATH="$stub_bin:$PATH" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$uppercase_assets" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" >/dev/null
  )
  assert_files_equal "$expected" "$installed"
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" || \
    fail 'uppercase checksum install did not configure hooks'

  ordering_assets="$suite_tmp/ordering-releases"
  ordering_dir="$ordering_assets/$package_tag"
  ordering_asset="$ordering_dir/git-hook-pure"
  mkdir -p "$ordering_dir"
  cat >"$ordering_asset" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version) printf '%s\n' "$TEST_VERSION" ;;
  install)
    if ! cmp -s "$INSTALL_PATH" "$OLD_EXECUTABLE"; then
      printf '%s\n' '[fixture] executable was published before hook setup' >&2
      exit 73
    fi
    exec "$REAL_ARTIFACT" install
    ;;
  *) exec "$REAL_ARTIFACT" "$@" ;;
esac
EOF
  chmod +x "$ordering_asset"
  write_sha256_manifest "$ordering_asset" "$ordering_dir/SHA256SUMS"
  repo=$(new_repo download-publish-order)
  installed="$repo/tools/git-hook-pure"
  previous="$repo/old-executable"
  mkdir -p "$(dirname -- "$installed")"
  printf '%s\n' old-executable-must-remain-during-setup >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"
  (
    cd "$repo"
    PATH="$stub_bin:$PATH" \
      TEST_VERSION="$package_version" REAL_ARTIFACT="$expected" \
      OLD_EXECUTABLE="$previous" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$ordering_assets" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" >/dev/null
  )
  assert_files_equal "$ordering_asset" "$installed"
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" || \
    fail 'staged executable did not configure hooks before publication'

  convergence_assets="$suite_tmp/convergence-releases"
  convergence_dir="$convergence_assets/$package_tag"
  convergence_asset="$convergence_dir/git-hook-pure"
  mkdir -p "$convergence_dir"
  cat >"$convergence_asset" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version) printf '%s\n' "$TEST_VERSION" ;;
  install)
    "$REAL_ARTIFACT" install || exit $?
    if [ ! -e "$SIGNAL_ONCE_FILE" ]; then
      : >"$SIGNAL_ONCE_FILE"
      kill -TERM "$PPID"
    fi
    ;;
  *) exec "$REAL_ARTIFACT" "$@" ;;
esac
EOF
  chmod +x "$convergence_asset"
  write_sha256_manifest "$convergence_asset" "$convergence_dir/SHA256SUMS"
  repo=$(new_repo download-post-setup-signal)
  installed="$repo/tools/git-hook-pure"
  previous="$repo/old-executable"
  signal_once="$repo/setup-signalled"
  mkdir -p "$(dirname -- "$installed")"
  printf '%s\n' old-executable-before-setup-signal >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"
  set +e
  (
    cd "$repo"
    PATH="$stub_bin:$PATH" \
      TEST_VERSION="$package_version" REAL_ARTIFACT="$expected" SIGNAL_ONCE_FILE="$signal_once" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$convergence_assets" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" >/dev/null 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'post-setup signal did not interrupt executable publication'
  assert_files_equal "$previous" "$installed"
  [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] || \
    fail 'post-setup signal changed the old executable mode'
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" || \
    fail 'post-setup signal lost the committed hook transaction'
  [ -z "$(find "$repo/tools" -maxdepth 1 -type d -name '.git-hook-pure-download.*' -print | sed -n '1p')" ] || \
    fail 'post-setup signal left download staging state'

  (
    cd "$repo"
    PATH="$stub_bin:$PATH" \
      TEST_VERSION="$package_version" REAL_ARTIFACT="$expected" SIGNAL_ONCE_FILE="$signal_once" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$convergence_assets" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" >/dev/null
  )
  assert_files_equal "$convergence_asset" "$installed"
  [ "$(grep -c 'git-hook-pure start' "$repo/.git/hooks/pre-commit")" -eq 1 ] || \
    fail 'rerun after setup/publication boundary duplicated the managed block'

  corrupt_assets="$suite_tmp/corrupt-releases/$package_tag"
  mkdir -p "$corrupt_assets"
  cp "$expected" "$corrupt_assets/git-hook-pure"
  printf '%064d  git-hook-pure\n' 0 >"$corrupt_assets/SHA256SUMS"
  repo=$(new_repo corrupt-download)
  installed="$repo/tools/git-hook-pure"
  previous="$repo/previous-executable"
  mkdir -p "$(dirname -- "$installed")"
  printf '%s\n' old-verified-executable >"$installed"
  cp "$installed" "$previous"
  set +e
  (
    cd "$repo"
    PATH="$stub_bin:$PATH" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$suite_tmp/corrupt-releases" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" >/dev/null 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'download installer accepted a bad checksum'
  assert_files_equal "$previous" "$installed"
  [ "$(find "$repo/tools" ! -path "$repo/tools" | wc -l | tr -d '[:space:]')" -eq 1 ] || \
    fail 'failed download left a staging path'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'checksum failure mutated Git hooks'
  fi

  repo=$(new_repo setup-failure-download)
  git -C "$repo" config core.hooksPath custom-hooks
  installed="$repo/tools/git-hook-pure"
  previous="$repo/previous-executable"
  mkdir -p "$(dirname -- "$installed")"
  printf '%s\n' old-verified-executable >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"
  set +e
  output=$(
    cd "$repo"
    PATH="$stub_bin:$PATH" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$assets" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'download installer ignored hook setup failure'
  assert_files_equal "$previous" "$installed"
  [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] || \
    fail 'hook setup rollback changed the previous executable mode'
  case "$output" in *core.hooksPath*) ;; *) fail 'hook setup failure lost its diagnostic' ;; esac
  case "$output" in *'installed executable'*) fail 'failed setup printed executable success' ;; *) ;; esac
  [ "$(find "$repo/tools" ! -path "$repo/tools" | wc -l | tr -d '[:space:]')" -eq 1 ] || \
    fail 'hook setup failure left a staging path'

  repo=$(new_repo signalled-download)
  installed="$repo/tools/git-hook-pure"
  previous="$repo/previous-executable"
  mkdir -p "$(dirname -- "$installed")"
  printf '%s\n' old-before-signal >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"
  signal_bin="$suite_tmp/signal-mv-bin"
  mkdir -p "$signal_bin"
  real_mv=$(command -v mv)
  cat >"$signal_bin/mv" <<'EOF'
#!/bin/sh
last=
for argument do last=$argument; done
last_name=${last##*/}
"$REAL_MV" "$@" || exit $?
[ "$last_name" != "$TARGET_HOOK_NAME" ] || [ -e "$SIGNAL_ONCE_FILE" ] || {
  : >"$SIGNAL_ONCE_FILE"
  kill -TERM "$PPID"
}
EOF
  chmod +x "$signal_bin/mv"
  set +e
  (
    cd "$repo"
    PATH="$signal_bin:$stub_bin:$PATH" \
      REAL_MV="$real_mv" TARGET_HOOK_NAME=applypatch-msg \
      SIGNAL_ONCE_FILE="$repo/hook-setup-signalled" \
      GIT_HOOK_PURE_VERSION="$package_version" \
      GIT_HOOK_PURE_RELEASE_BASE_URL="file://$assets" \
      INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" >/dev/null 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'download installer ignored a replacement-time signal'
  assert_files_equal "$previous" "$installed"
  [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] || \
    fail 'signal rollback changed the previous executable mode'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'signal rollback left managed hook content'
  fi
  [ ! -e "$repo/.githooks" ] || fail 'signal rollback left its generated handler directory'
  [ "$(find "$repo/tools" ! -path "$repo/tools" | wc -l | tr -d '[:space:]')" -eq 1 ] || \
    fail 'signal rollback left a staging path'

}

test_install_standalone_cleans_staging_on_supported_signals() {
  local assets version_dir expected stub_bin signal repo installed previous status
  assets="$suite_tmp/signal-download-releases"
  version_dir="$assets/$package_tag"
  mkdir -p "$version_dir"
  expected="$version_dir/git-hook-pure"
  "$repo_root/scripts/build.sh" --output "$expected" >/dev/null
  write_sha256_manifest "$expected" "$version_dir/SHA256SUMS"
  stub_bin="$suite_tmp/signal-curl-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/curl" <<'EOF'
#!/bin/sh
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
input=${url#file://}
[ -f "$input" ] || exit 22
if [ -n "$output" ]; then cp "$input" "$output"; else cat "$input"; fi
count=0
[ ! -f "$CURL_COUNT_FILE" ] || IFS= read -r count <"$CURL_COUNT_FILE"
count=$((count + 1))
printf '%s\n' "$count" >"$CURL_COUNT_FILE"
if [ "$count" -eq 1 ]; then
  kill -s "$TEST_SIGNAL" "$PPID"
fi
EOF
  chmod +x "$stub_bin/curl"

  for signal in HUP INT QUIT PIPE TERM; do
    repo=$(new_repo "download-signal-$signal")
    installed="$repo/tools/git-hook-pure"
    previous="$repo/previous-executable"
    mkdir -p "$(dirname -- "$installed")"
    printf '%s\n' "old-before-download-$signal" >"$installed"
    chmod 751 "$installed"
    cp -p "$installed" "$previous"
    set +e
    (
      trap - "$signal"
      cd "$repo"
      PATH="$stub_bin:$PATH" TEST_SIGNAL="$signal" CURL_COUNT_FILE="$repo/curl-count" \
        GIT_HOOK_PURE_VERSION="$package_version" \
        GIT_HOOK_PURE_RELEASE_BASE_URL="file://$assets" \
        INSTALL_PATH="$installed" \
        HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        sh "$repo_root/install-standalone.sh" >/dev/null 2>&1
    )
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "download installer ignored SIG$signal"
    assert_files_equal "$previous" "$installed"
    [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] || \
      fail "download SIG$signal changed the previous executable mode"
    if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
      fail "download SIG$signal reached hook setup"
    fi
    [ ! -e "$repo/.githooks" ] || fail "download SIG$signal created .githooks"
    [ -z "$(find "$repo/tools" -maxdepth 1 -type d -name '.git-hook-pure-download.*' -print | sed -n '1p')" ] || \
      fail "download SIG$signal left staging state"
  done
}

test_install_standalone_cleans_staging_when_mktemp_is_interrupted_before_returning() {
  local source repo installed previous shim_bin created_path_file real_mktemp status stage_dir
  source="$suite_tmp/standalone assignment gap source"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$source"
  chmod +x "$source"
  repo=$(new_repo 'standalone assignment gap')
  installed="$repo/tools with spaces/git-hook-pure"
  previous="$repo/previous-executable"
  shim_bin="$suite_tmp/standalone assignment gap bin"
  created_path_file="$suite_tmp/standalone-assignment-gap.path"
  mkdir -p "$(dirname -- "$installed")" "$shim_bin"
  printf '%s\n' old-install-before-assignment-gap >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"

  real_mktemp=$(command -v mktemp)
  cat >"$shim_bin/mktemp" <<'EOF'
#!/bin/sh
created=$("$REAL_MKTEMP" "$@") || exit $?
printf '%s\n' "$created" >"$MKTEMP_CREATED_PATH"
kill -TERM "$PPID"
kill -TERM "$$"
EOF
  chmod +x "$shim_bin/mktemp"

  set +e
  (
    trap - TERM
    cd "$repo"
    PATH="$shim_bin:$PATH" REAL_MKTEMP="$real_mktemp" \
      MKTEMP_CREATED_PATH="$created_path_file" \
      GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable "$source"
  ) >/dev/null 2>&1
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'standalone installer ignored an interrupted mktemp'
  [ -s "$created_path_file" ] || fail 'mktemp shim did not record its created staging path'
  assert_files_equal "$previous" "$installed"
  [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] ||
    fail 'interrupted mktemp changed the previous installed executable mode'
  stage_dir=$(cat "$created_path_file")
  [ ! -e "$stage_dir" ] ||
    fail 'interrupted mktemp left a staging directory before path assignment'
  [ ! -e "$repo/.githooks" ] || fail 'interrupted mktemp created .githooks'
}

test_install_standalone_rejects_an_empty_local_source_without_network() {
  local repo stub_bin installed previous output status
  repo=$(new_repo empty-local-source)
  stub_bin="$suite_tmp/empty-source-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/curl" <<'EOF'
#!/bin/sh
: >"$CURL_CALLED"
exit 73
EOF
  chmod +x "$stub_bin/curl"
  installed="$repo/tools/git-hook-pure"
  previous="$repo/previous-executable"
  mkdir -p "$(dirname -- "$installed")"
  printf '%s\n' old-executable >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"

  set +e
  output=$(
    cd "$repo"
    PATH="$stub_bin:$PATH" CURL_CALLED="$repo/curl-called" \
      GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable '' 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "empty standalone source was not rejected as usage: $output"
  [ ! -e "$repo/curl-called" ] || fail 'empty standalone source unexpectedly used the network path'
  assert_files_equal "$previous" "$installed"
  [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] ||
    fail 'empty standalone source changed the previous executable mode'
  [ ! -e "$repo/.githooks" ] || fail 'empty standalone source created .githooks'
  if grep -Rqs 'git-hook-pure start' "$repo/.git/hooks"; then
    fail 'empty standalone source installed Git hooks'
  fi
}

test_install_standalone_rejects_a_staged_executable_version_mismatch() {
  local source repo installed previous hook original_hook output status
  source="$suite_tmp/version-mismatch-source"
  cat >"$source" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version) printf '%s\n' '999.0.0' ;;
  install) : >"$SETUP_CALLED" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$source"
  repo=$(new_repo standalone-version-mismatch)
  installed="$repo/tools/git-hook-pure"
  previous="$repo/previous-executable"
  mkdir -p "$(dirname -- "$installed")"
  printf '%s\n' old-executable >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"
  hook="$repo/.git/hooks/pre-commit"
  original_hook="$repo/original-pre-commit"
  printf '%s\n' '#!/bin/sh' 'exit 23' >"$hook"
  chmod 711 "$hook"
  cp -p "$hook" "$original_hook"

  set +e
  output=$(
    cd "$repo"
    SETUP_CALLED="$repo/setup-called" \
      GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable "$source" 2>&1
  )
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'standalone installer accepted a staged version mismatch'
  case "$output" in *'staged executable version mismatch'*) ;;
    *) fail "staged version mismatch had no actionable diagnostic: $output" ;;
  esac
  [ ! -e "$repo/setup-called" ] || fail 'staged version mismatch reached hook setup'
  assert_files_equal "$previous" "$installed"
  [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] ||
    fail 'staged version mismatch changed the previous executable mode'
  assert_files_equal "$original_hook" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original_hook")" ] ||
    fail 'staged version mismatch changed the existing hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'staged version mismatch created .githooks'
  [ -z "$(find "$repo/tools" -maxdepth 1 -type d -name '.git-hook-pure-download.*' -print | sed -n '1p')" ] ||
    fail 'staged version mismatch left staging state'
}

test_install_standalone_runs_setup_when_npm_auto_install_is_skipped() {
  local source repo installed
  source="$suite_tmp/standalone-npm-skip-source"
  "$repo_root/scripts/build.sh" --output "$source" >/dev/null
  repo=$(new_repo standalone-npm-skip)
  installed="$repo/tools/git-hook-pure"

  (
    cd "$repo"
    GIT_HOOK_PURE_SKIP_INSTALL=1 \
      GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH="$installed" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable "$source" >/dev/null
  )

  assert_files_equal "$source" "$installed"
  grep -q 'git-hook-pure start' "$repo/.git/hooks/pre-commit" ||
    fail 'npm automatic-install skip control disabled standalone explicit setup'
}

test_install_standalone_rejects_a_leading_dash_target_before_side_effects() {
  local source repo installed previous hook original_hook output status
  source="$suite_tmp/leading-dash-source"
  "$repo_root/scripts/build.sh" --output "$source" >/dev/null
  repo=$(new_repo standalone-leading-dash)
  installed="$repo/-git-hook-pure"
  previous="$repo/previous-executable"
  printf '%s\n' old-executable >"$installed"
  chmod 751 "$installed"
  cp -p "$installed" "$previous"
  hook="$repo/.git/hooks/pre-commit"
  original_hook="$repo/original-pre-commit"
  printf '%s\n' '#!/bin/sh' 'exit 19' >"$hook"
  chmod 711 "$hook"
  cp -p "$hook" "$original_hook"

  set +e
  output=$(
    cd "$repo"
    GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH=-git-hook-pure \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable "$source" 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "leading-dash target was not rejected as usage: $output"
  case "$output" in *'must not start with -'*) ;;
    *) fail "leading-dash target had no actionable diagnostic: $output" ;;
  esac
  assert_files_equal "$previous" "$installed"
  [ "$(file_mode "$installed")" = "$(file_mode "$previous")" ] ||
    fail 'leading-dash target changed the previous executable mode'
  assert_files_equal "$original_hook" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original_hook")" ] ||
    fail 'leading-dash target changed the existing hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'leading-dash target created .githooks'
  [ -z "$(find "$repo" -maxdepth 1 -type d -name '.git-hook-pure-download.*' -print | sed -n '1p')" ] ||
    fail 'leading-dash target left staging state'
}

test_install_standalone_rejects_directory_syntax_before_hook_setup() {
  local source repo hook original output status backslash_target
  source="$suite_tmp/directory-syntax-source"
  "$repo_root/scripts/build.sh" --output "$source" >/dev/null
  repo=$(new_repo standalone-directory-syntax)
  hook="$repo/.git/hooks/pre-commit"
  original="$repo/original-pre-commit"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$hook"
  chmod 751 "$hook"
  cp -p "$hook" "$original"

  set +e
  output=$(
    cd "$repo"
    GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH="$repo/tools/" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable "$source" 2>&1
  )
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'standalone installer accepted directory syntax as its target'
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] ||
    fail 'directory-syntax failure changed the existing hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'directory-syntax failure created .githooks'
  [ ! -e "$repo/tools" ] || fail 'directory-syntax failure created its target'

  backslash_target="$repo/tools\\git-hook-pure"
  set +e
  output=$(
    cd "$repo"
    GIT_HOOK_PURE_VERSION="$package_version" INSTALL_PATH="$backslash_target" \
      HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      sh "$repo_root/install-standalone.sh" --source-executable "$source" 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'standalone installer accepted a backslash-bearing target'
  assert_files_equal "$original" "$hook"
  [ "$(file_mode "$hook")" = "$(file_mode "$original")" ] ||
    fail 'backslash-target failure changed the existing hook mode'
  [ ! -e "$repo/.githooks" ] || fail 'backslash-target failure created .githooks'
}

run_install_standalone_integration_tests() {
  run_test test_install_standalone_rejects_git_config_before_side_effects
  run_test test_install_standalone_rejects_absent_and_case_varied_git_admin_paths
  run_test test_install_standalone_rejects_git_admin_components_before_dot_dot
  run_test test_install_standalone_rejects_separate_git_admin_paths
  run_test test_install_standalone_rejects_escaping_and_symlink_paths
  run_test test_install_standalone_rejects_invalid_existing_destination_nodes
  run_test test_install_standalone_rejects_before_download
  run_test test_install_standalone_preserves_direct_path_semantics
  run_test test_install_standalone_rejects_malformed_successful_git_paths
  run_test test_install_standalone_fetches_a_versioned_verified_release_asset
  run_test test_install_standalone_cleans_staging_on_supported_signals
  run_test test_install_standalone_cleans_staging_when_mktemp_is_interrupted_before_returning
  run_test test_install_standalone_rejects_an_empty_local_source_without_network
  run_test test_install_standalone_rejects_a_staged_executable_version_mismatch
  run_test test_install_standalone_runs_setup_when_npm_auto_install_is_skipped
  run_test test_install_standalone_rejects_a_leading_dash_target_before_side_effects
  run_test test_install_standalone_rejects_directory_syntax_before_hook_setup
}
