# Changelog

All notable changes to this project are documented in this file.

## [4.0.0](https://github.com/bolasblack/git-hook-pure/compare/v3.3.0...v4.0.0) (2026-08-16)

### Breaking changes

- Require Git 2.31 or newer and reject bare repositories.
- Run managed handlers before compatible pre-existing hook content.

### Features and fixes

- Preserve every argument for every handler and support spaces in handler
  names and arguments.
- Replay exact stdin independently to every handler and existing hook for the
  four stream-driven hook types, preventing policy bypass by an earlier reader.
- Resolve normal, monorepo, linked-worktree, submodule, and non-bare receive
  hook paths through Git; reject layouts whose receive hooks cannot recover a
  worktree.
- Refuse every visible `core.hooksPath` configuration before mutation.
- Make install and uninstall preflighted, idempotent, fail-closed, and
  transactional across ordinary failures and HUP, INT, QUIT, PIPE, and TERM;
  preserve recovery backups if a rollback cannot finish.
- Record exact v4 ownership/state metadata inside a fixed wrapper envelope,
  migrate only complete historical v3 default blocks, and restore existing
  hook bytes and modes exactly.
- Isolate managed dispatch from existing hook state and install only hook
  protocols with defined composition semantics.
- Add a deterministic single-file packager, checksum-verifying downloader,
  staged-setup-before-publication semantics, npm artifact smoke tests, and
  reviewed Draft/Publish GitHub Release workflows.
- Add a version-pinned `npx ... install-standalone` bootstrap that copies the exact npm
  package executable to a project-owned path without retaining the package dependency.
- Make local npm installation attempt hook setup automatically, with an exact
  skip control, non-fatal actionable failure, explicit install/uninstall
  commands, and documentation for npm lifecycle-output suppression.

## [3.3.0](https://github.com/bolasblack/git-hook-pure/compare/v3.2.1...v3.3.0) (2023-12-29)


### Features

* make git-hook-pure as a command ([78f0176](https://github.com/bolasblack/git-hook-pure/commit/78f0176e3c63ee0e30d1a86801d05d827df569a1))
