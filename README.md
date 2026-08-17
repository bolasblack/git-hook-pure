# git-hook-pure

`git-hook-pure` is a dependency-free dispatcher for repository-owned Git hook
scripts. It keeps handler code in `.githooks`, does not change global Git
configuration, and does not require Node.js when hooks run.

Maintainers and reviewers should preserve the
[normative product specification](https://github.com/bolasblack/git-hook-pure/blob/develop/docs/SPEC.md).

## Authorship and version choice

Version 4 was developed with substantial assistance from AI coding agents under the
maintainer's direction, review, and testing. If your policy requires an implementation
written without generative-AI assistance, the last human-written release,
[v3.3.0](https://github.com/bolasblack/git-hook-pure/releases/tag/v3.3.0), remains
available.

Version 3 is a historical release line and does not include v4's repository-layout,
transaction-safety, packaging, or test improvements. “Human-written” describes its
provenance, not a security guarantee.

Version 4 requires Git 2.31 or newer and a Bourne-compatible shell. The test
workflow covers Linux, macOS, and Git Bash on Windows. Bare repositories are
intentionally unsupported because they have no project worktree in which to
own `.githooks`.

## Why this project

[Husky](https://typicode.github.io/husky/) also keeps editable user hooks in the
repository, and [Lefthook](https://lefthook.dev/configuration/) keeps project
configuration there and can use a
[project-local executable](https://lefthook.dev/configuration/lefthook/).
`git-hook-pure` makes a narrower packaging choice: its recommended standalone path lets
a project vendor and commit the complete, readable manager implementation as one shell
file alongside executable `.githooks` handlers.

That project-owned snapshot can be inspected, explained, modified, and reviewed as an
ordinary code diff by people or coding agents. Generated dispatch code still lives in
Git's local hooks directory and is not cloned; it is derived from the vendored manager.
Hook execution needs neither npm, `node_modules`, nor an external hook-manager binary.
After cloning, or after changing or upgrading the manager, run its `install` command
again to regenerate those local hooks.

Committing the pinned standalone artifact reduces hook-manager dependency and runtime
supply-chain surface and makes upgrades auditable. It does not eliminate bootstrap or
publisher risk: pin the bootstrap package or installer, commit the resulting artifact,
and review its diff on every upgrade. `git-hook-pure` is intentionally a small
executable dispatcher, not a declarative task graph or staged-file engine.

## Install

### Recommended: vendor the standalone executable with npx

Use npm only as a one-time bootstrap. The npm command copies the package's exact
standalone executable to `tools/git-hook-pure`, installs the local Git hooks, and leaves
the project with no npm or external manager dependency at hook runtime:

```sh
npx git-hook-pure@4.0.0 install-standalone
git add tools/git-hook-pure
```

An optional repository-relative argument selects a different project-owned path:

```sh
npx git-hook-pure@4.0.0 install-standalone scripts/git-hook-pure
```

Use that selected path for later `install` and `uninstall` commands. The destination
must be an ordinary project path that can be committed: use `/` separators and do not
target `..`, a symlink ancestor, or a Git administrative directory.

Commit the resulting executable. Git does not clone its local hooks directory, so every
fresh checkout must activate the committed manager once, either directly or through the
project's existing setup command:

```sh
./tools/git-hook-pure install
```

Editing a `.githooks` handler takes effect immediately. After editing or upgrading
`tools/git-hook-pure` itself, rerun the command above to regenerate the managed hook
blocks.

### Without npm

The standalone installer remains available when npm is unavailable. Pin and review the
installer; it downloads the release executable and `SHA256SUMS`, verifies the checksum
and embedded version, runs hook setup from the staged executable, and publishes the
executable only after setup succeeds:

```sh
version=4.0.0
curl -fsSL \
  "https://raw.githubusercontent.com/bolasblack/git-hook-pure/v${version}/install-standalone.sh" \
  -o /tmp/install-git-hook-pure-standalone.sh
# Review the pinned installer before running it.
GIT_HOOK_PURE_VERSION="$version" \
  INSTALL_PATH=./tools/git-hook-pure \
  sh /tmp/install-git-hook-pure-standalone.sh
git add tools/git-hook-pure
```

The release assets are `git-hook-pure` and `SHA256SUMS`; you can also download and
verify them directly. When invoking the installer yourself, a relative `INSTALL_PATH`
is resolved from the caller's working directory and an absolute path is also accepted,
but its final destination must remain inside the current worktree and outside Git's
administrative directories.

## Add handlers

Put executable files in either location:

```text
.githooks/<handler>             # runs for every supported Git hook
.githooks/<hook-name>/<handler> # runs only for that hook
```

Handlers are run in filename order. Directories and hidden files are ignored.
A non-executable handler is a hard error, and a handler's non-zero status is
returned unchanged to Git; later handlers do not run.

For a `commit-msg` invocation with Git arguments `message-file extra`:

- `.githooks/check` receives `commit-msg message-file extra`.
- `.githooks/commit-msg/check` receives `message-file extra`.

Every handler receives a fresh, quoted copy of the full argument list. Spaces
and glob characters in handler names or arguments are preserved.

`pre-push`, `pre-receive`, `post-receive`, and `post-rewrite` also receive
stdin. Version 4 snapshots that stream once and replays the exact bytes from
the beginning to every handler and then to an existing hook. One handler
cannot consume facts needed by later handlers or an existing receive policy.

When a compatible shell hook already exists, managed handlers run first and
the original hook runs afterward. This ordering prevents an existing `exit`
statement from making managed handlers unreachable. Repeated install is
idempotent. Uninstall removes only the managed block, restores the original
file and mode, and deletes hook files that git-hook-pure created itself.

## Repository layouts

All paths come from Git rather than from assumptions about `.git`:

- Running install from a nested monorepo directory uses the repository root's
  `.githooks` and hooks directory.
- Linked worktrees share the common Git hooks directory, while the dispatcher
  resolves `.githooks` from the worktree currently executing the hook. Install
  or uninstall from any linked worktree therefore changes the shared wrappers
  for every linked worktree.
- A submodule uses its own worktree `.githooks` and its Git-owned
  `.git/modules/.../hooks` directory; the superproject hooks are not changed.
- Receive-side hooks in a non-bare repository resolve back from `$GIT_DIR` to
  that repository's worktree.

An unmapped repository created with `git init --separate-git-dir` is rejected
before mutation: its detached Git directory contains no reverse mapping that a
receive-side hook can use to recover the project worktree. A separate Git
directory with an explicit, valid local `core.worktree` mapping is supported
and resolves handlers from that mapped worktree.

If any visible configuration source defines `core.hooksPath`—including local,
global, system, worktree, command, included, or an empty value—install and
uninstall stop before mutation. `git-hook-pure` never changes or resets that
setting. Resolve the ownership conflict and unset it at its source before
running setup or removal.

## Existing hooks

The dispatcher is portable shell code and can be inserted only into a
new hook or a compatible executable shell hook. An unowned blank hook, a
symbolic link, directory, non-executable existing hook, malformed managed
block, reserved-marker collision, or non-shell interpreter causes the whole
install to fail before any hook is changed.

The managed dispatcher runs in an isolated subshell, so its variables,
functions, options, and traps do not leak into existing hook code. Version 4
records the Git object ID of its complete managed content, including the
generated/existing state. That self-description lets a changed or upgraded
manager replace a complete older v4 block while rejecting content whose
recorded identity no longer matches. The complete historical v3 default
dispatcher is also recognized. Unknown or near-matching marker content is
never stripped.

The content ID is an integrity check and explicit ownership declaration used by
later `install` and `uninstall` commands; hook execution does not hash itself.
It is not authentication—anyone able to edit a local hook can also recompute it.

The installer manages these 20 hooks, whose argument, stdin, and output
contracts can be composed safely with multiple handlers:

```text
applypatch-msg       commit-msg            post-applypatch
post-checkout        post-commit           post-index-change
post-merge           post-receive          post-rewrite
post-update          pre-applypatch        pre-auto-gc
pre-commit           pre-merge-commit      pre-push
pre-rebase           pre-receive           prepare-commit-msg
sendemail-validate   update
```

Protocol-specific hooks such as `push-to-checkout`, `proc-receive`, and
`fsmonitor-watchman` are not installed: their worktree-update, bidirectional,
or structured-output protocols do not have a correct generic fan-out model.
`reference-transaction` and `p4-*` remain out of scope until their transactional
or git-p4 behavior has dedicated integration coverage.

## Uninstall

Remove managed hook blocks before deleting the standalone command or npm package:

```sh
./tools/git-hook-pure uninstall

# npm compatibility installation
npx git-hook-pure uninstall
npm uninstall git-hook-pure
```

Uninstall is explicit because npm 7 and newer do not run uninstall lifecycle
scripts. It is safe to run uninstall more than once. `.githooks` is project
content and is never deleted by uninstall.

`GIT_HOOK_PURE_SKIP_INSTALL=1` skips only the automatic npm attempt. Explicit
`install` and `uninstall` commands remain available. Values other than exact `1`
do not skip the automatic attempt.

## Build and release

Repository maintenance tasks live in the ecosystem-neutral `.mise.toml`, rather than
being owned by npm. Review and trust that file once, then use the same entry points
locally and in CI:

```sh
mise trust
mise run test
mise run build
# dist/git-hook-pure
```

The packager stages beside the destination, syntax-checks and smoke-tests the
embedded version, and replaces the previous artifact only after success. npm keeps a
thin `prepack` lifecycle adapter that delegates to `mise run build`, so `npm pack` and
`npm publish` still rebuild automatically without owning a second build definition.
The npm-only `postinstall` adapter remains direct because package consumers must not
need mise merely to install hooks.
Install and uninstall also stage every target before mutation and roll back tested
interruptions from HUP, INT, QUIT, PIPE, and TERM. If automatic hook rollback itself
fails, the command reports and retains the recovery directory containing original
backups.

Release tags use a reviewed two-stage GitHub flow: the tag creates a Draft
Release from `docs/releases/<tag>.md`; publishing the draft checks out the exact
tag, reruns all tests, rebuilds the executable, creates `SHA256SUMS`, and uploads
exactly those two assets. See the
[release guide](https://github.com/bolasblack/git-hook-pure/blob/develop/docs/releasing.md).

## npm dependency compatibility

Keeping the npm package as a development dependency remains supported for projects
whose dependency installation already owns Git hook setup. It packages the same
executable and attempts hook setup automatically when installed locally:

```sh
npm install --save-dev git-hook-pure
```

npm 7 and newer hide dependency lifecycle output by default. Use
`--foreground-scripts` when you want to see the automatic setup result and its
uninstall/skip instructions:

```sh
npm install --foreground-scripts --save-dev git-hook-pure
```

Automatic setup is best-effort. npm policy may disable lifecycle scripts, and a Git
layout or ownership conflict may make setup fail. Package installation still succeeds;
fix the reported problem and run the idempotent explicit command:

```sh
npx git-hook-pure install
```

Skip the automatic attempt when CI or local policy owns setup:

```sh
GIT_HOOK_PURE_SKIP_INSTALL=1 npm install
```

For a cloned project, the normal dependency installation makes the same attempt. If
dependencies were restored without lifecycle scripts or hooks are otherwise absent,
run the explicit command above. A project can also make both controls discoverable:

```json
{
  "scripts": {
    "hooks:install": "git-hook-pure install",
    "hooks:uninstall": "git-hook-pure uninstall"
  }
}
```

Those consumer-project aliases are npm-specific convenience adapters; they do not make
this repository's maintenance workflow an npm-owned interface.
