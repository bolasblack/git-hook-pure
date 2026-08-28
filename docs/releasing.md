# Releasing

The installed `release` skill owns this workflow. Invoke that skill explicitly by name; it reads the repository-owned contract below and stops at both remote approval gates.

Local GitHub CLI is optional. Git and explicit confirmation in the GitHub web UI provide the portable local path; the generated GitHub-hosted workflow uses the runner-provided CLI.

## Release contract

```yaml
project: "git-hook-pure"
branch: "develop"
tag_prefix: "v"
test: |-
  mise run test
build: |-
  mise run build
install: ""
version_files:
  - "package.json"
  - "README.md"
asset_dir: "dist"
assets:
  - "git-hook-pure"
changelog: "CHANGELOG.md"
spec_dirs: []
action_pins:
  checkout: "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
  upload_artifact: "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
  download_artifact: "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
setup_actions:
  - uses: "jdx/mise-action@c2a87611a18de5b3828c5652fe268e992400cb5c"
```

## Flow

1. The skill verifies repository identity, branch, release state, and tests before preparing one local release commit and annotated tag.
2. After approval, the branch and tag are pushed atomically. The pinned `draft-release` workflow checks out the exact tag with read-only permissions and reruns identity checks and tests.
3. CI also builds the release assets, creates `SHA256SUMS`, and attaches that exact staged set to the draft.
4. The workflow creates or updates only an unpublished draft. Review its note and exact asset inventory before separately approving publication.
5. Publication makes the prepared release public. Published tags and assets are immutable; corrections use a new version.

## Publishing to npm

The npm package is also built from the same artifact. Its `prepack` lifecycle hook is a
thin adapter to the neutral `mise run build` task, so npm packaging still rebuilds
automatically without owning a separate build definition.
Publishing npm is intentionally separate from GitHub Release publication and is a
second explicit human action. Publish only from a clean checkout of the exact tag:

1. Verify `HEAD` is `refs/tags/v<version>^{commit}` and rerun `mise run test`.
2. Run `npm pack --dry-run`, inspect the inventory, then run `npm pack` once.
3. Publish that exact generated archive with
   `npm publish ./git-hook-pure-<version>.tgz --access public`; do not run
   `npm publish .`, which would repack mutable working-tree contents.
4. Verify `npm view git-hook-pure@<version> version dist.integrity`, then exercise the
   pinned `npx git-hook-pure@<version> install-standalone` command in a disposable Git
   repository before announcing the npm release.
