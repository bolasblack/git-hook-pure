test_ci_workflow_covers_portable_shells_and_lf_sources() {
  local workflow source_file eol shell_sources
  workflow=$repo_root/.github/workflows/test.yml

  grep -Fq 'windows-latest' "$workflow" ||
    fail 'test workflow does not cover Git Bash on Windows'
  grep -Fq 'shell: bash' "$workflow" ||
    fail 'Windows workflow does not select Git Bash'
  grep -Fq 'uses: jdx/mise-action@v4' "$workflow" ||
    fail 'test workflow does not install repository tools through mise'
  grep -Fq 'run: mise run test' "$workflow" ||
    fail 'test workflow bypasses the repository maintenance task'
  grep -Fq 'timeout-minutes: 45' "$workflow" ||
    fail 'test workflow timeout is too short for the full Windows integration suite'
  grep -Fq \
    "GIT_HOOK_PURE_REQUIRE_NON_C_COLLATION: \${{ matrix.os == 'ubuntu-latest' && '1' || '0' }}" \
    "$workflow" ||
    fail 'test workflow does not require the non-C collation regression on Ubuntu only'

  shell_sources=$(git -C "$repo_root" ls-files -- '*.sh' src/modules.list) ||
    fail 'unable to enumerate tracked shell sources for LF verification'
  [ -n "$shell_sources" ] || fail 'no tracked shell sources were found for LF verification'
  while IFS= read -r source_file; do
    [ -e "$repo_root/$source_file" ] || continue
    eol=$(git -C "$repo_root" ls-files --eol -- "$source_file")
    printf '%s\n' "$eol" | awk '
      $1 == "i/lf" && $2 == "w/lf" { valid = 1 }
      END { exit valid ? 0 : 1 }
    ' || fail "shell source is not stored and checked out with LF endings: $source_file ($eol)"
  done <<<"$shell_sources"
}

run_ci_workflow_contract_tests() {
  run_test test_ci_workflow_covers_portable_shells_and_lf_sources
}
