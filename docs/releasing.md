# Releasing git-hook-pure

Releases use the same reviewed two-stage flow as DWB: a tag creates an
unpublished Draft Release, and a human publishes that draft before artifacts
are built and attached.

1. Choose a semantic version greater than the latest release.
2. Update the single machine-readable version owner in `package.json`.
3. Write `docs/releases/v<version>.md` and update `CHANGELOG.md`.
4. Run:

   ```sh
   mise run test
   scripts/check-release.sh v<version>
   ```

5. Review and commit only the release changes, then create an annotated
   `v<version>` tag.
6. Push the commit and tag only after explicit publication approval.
7. The `draft-release` workflow creates an unpublished GitHub Release from the
   exact note. Review it and click **Publish**.
8. The `release` workflow checks out the exact tag, verifies release identity,
   runs `mise run test` to build and exercise `dist/git-hook-pure`, confirms later package
   tests did not change those bytes, then uses `scripts/prepare-release-assets.sh` to
   generate and verify `SHA256SUMS` and the exact two-file inventory before uploading
   those two assets with `--clobber`, so a manual retry is idempotent.

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
