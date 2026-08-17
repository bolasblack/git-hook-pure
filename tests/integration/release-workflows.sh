test_release_workflows_checkout_and_verify_exact_tag_refs() {
  local workflow tagged_command eol shell_sources
  for workflow in draft-release release; do
    grep -Fq 'ref: refs/tags/${{' "$repo_root/.github/workflows/$workflow.yml" ||
      fail "$workflow workflow does not checkout the tag namespace explicitly"
    tagged_command=$(sed -n \
      's/^[[:space:]]*run: \(scripts\/check-release.sh --tagged "$TAG"\)$/\1/p' \
      "$repo_root/.github/workflows/$workflow.yml")
    [ "$tagged_command" = 'scripts/check-release.sh --tagged "$TAG"' ] ||
      fail "$workflow workflow does not delegate exact tag identity validation"
    if grep -Fq 'refs/tags/${TAG}^{commit}' "$repo_root/.github/workflows/$workflow.yml" ||
      grep -Fq 'git rev-parse HEAD' "$repo_root/.github/workflows/$workflow.yml"; then
      fail "$workflow workflow duplicates release identity validation inline"
    fi
  done
  grep -Eq 'gh release create .*--verify-tag' "$repo_root/.github/workflows/draft-release.yml" ||
    fail 'draft release creation can synthesize a missing remote tag'
  grep -Fq 'windows-latest' "$repo_root/.github/workflows/test.yml" ||
    fail 'test workflow does not cover Git Bash on Windows'
  grep -Fq 'shell: bash' "$repo_root/.github/workflows/test.yml" ||
    fail 'Windows workflow does not select Git Bash'
  grep -Fq 'uses: jdx/mise-action@v4' "$repo_root/.github/workflows/test.yml" ||
    fail 'test workflow does not install repository tools through mise'
  grep -Fq 'run: mise run test' "$repo_root/.github/workflows/test.yml" ||
    fail 'test workflow bypasses the repository maintenance task'
  grep -Fq 'uses: jdx/mise-action@v4' "$repo_root/.github/workflows/release.yml" ||
    fail 'release workflow does not install repository tools through mise'
  grep -Fq \
    "GIT_HOOK_PURE_REQUIRE_NON_C_COLLATION: \${{ matrix.os == 'ubuntu-latest' && '1' || '0' }}" \
    "$repo_root/.github/workflows/test.yml" ||
    fail 'test workflow does not require the non-C collation regression on Ubuntu only'
  if awk '
    /run: mise run test/ { tested = 1 }
    tested && /run: mise run build/ { rebuilt = 1 }
    END { exit rebuilt ? 0 : 1 }
  ' "$repo_root/.github/workflows/release.yml"; then
    fail 'release workflow rebuilds the standalone artifact after its full test suite'
  fi
  shell_sources=$(git -C "$repo_root" ls-files -- '*.sh' src/modules.list) ||
    fail 'unable to enumerate tracked shell sources for LF verification'
  [ -n "$shell_sources" ] || fail 'no tracked shell sources were found for LF verification'
  while IFS= read -r workflow; do
    eol=$(git -C "$repo_root" ls-files --eol -- "$workflow")
    printf '%s\n' "$eol" | awk '
      $1 == "i/lf" && $2 == "w/lf" { valid = 1 }
      END { exit valid ? 0 : 1 }
    ' || fail "shell source is not stored and checked out with LF endings: $workflow ($eol)"
  done <<<"$shell_sources"
}

test_release_workflow_verifies_exact_assets_and_checksum() {
  local workflow prepare_command upload_command
  workflow=$repo_root/.github/workflows/release.yml

  prepare_command=$(sed -n \
    's/^[[:space:]]*run: \(scripts\/prepare-release-assets.sh dist\)$/\1/p' \
    "$workflow")
  [ "$prepare_command" = 'scripts/prepare-release-assets.sh dist' ] ||
    fail 'release workflow does not delegate release asset preparation'
  awk '
    /run: mise run test/ { tested = NR }
    /dist\/git-hook-pure --help/ { smoked = NR }
    /run: scripts\/prepare-release-assets.sh dist/ { prepared = NR }
    /run: gh release upload/ { uploaded = NR }
    END {
      exit tested && smoked > tested && prepared > smoked && uploaded > prepared ? 0 : 1
    }
  ' "$workflow" || fail 'release asset preparation is not ordered after tests and before upload'

  upload_command=$(sed -n \
    's/^[[:space:]]*run: \(gh release upload.*\)$/\1/p' "$workflow")
  [ "$upload_command" = 'gh release upload "$TAG" dist/git-hook-pure dist/SHA256SUMS --clobber' ] ||
    fail "release workflow does not upload exactly git-hook-pure and SHA256SUMS: $upload_command"
}

run_release_workflow_contract_tests() {
  run_test test_release_workflows_checkout_and_verify_exact_tag_refs
  run_test test_release_workflow_verifies_exact_assets_and_checksum
}
