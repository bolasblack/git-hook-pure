# git-hook-pure Specification

This file records the stable product requirements owned by the project author. It is
normative for implementation changes and reviews. The README explains current usage;
tests provide evidence; release notes describe history. An intentional product change
updates this specification rather than silently weakening it in code or documentation.

Historical sources cited below are part of this specification where they establish a
persistent product choice made by the project author. They establish intent, not the
correctness of every old implementation detail; only the requirements stated here are
binding.

## Repository-Owned Executable Handlers

`git-hook-pure` is a small dispatcher for executable files owned by the repository. It
is not a task graph, staged-file engine, package manager, or configuration language.

- `.githooks/<handler>` runs for every supported Git hook and receives the hook name
  followed by every original Git argument.
- `.githooks/<hook-name>/<handler>` runs only for that hook and receives every original
  Git argument.
- Handlers may use any executable interpreter available to the project. Running a Git
  hook does not require Node.js, npm, a package-manager process, or git-hook-pure's
  installation mechanism.
- `.githooks` is project content. Successful installation creates an ordinary
  `.githooks` directory when it is absent. A failed installation never removes a
  pre-existing or project-owned directory; it may roll back only a directory created
  by that same operation and still safe to remove. Uninstall never deletes it.
- `git-hook-pure` owns one dispatcher implementation. Executable `.githooks` handlers
  are the project extension seam.

**Why:** The original purpose is to keep hook policy visible, reviewable, language
agnostic, and reusable with the repository instead of embedding it in package-manager
configuration or bootstrapping Node.js from every hook.

**Source:** The [1.0.1 README](https://github.com/bolasblack/git-hook-pure/blob/1.0.1/README.md)
establishes the no-Node runtime goal, repository-root `.githooks`, both handler scopes,
and their argument shapes.

## Authorship Transparency

Version 4 is disclosed as having been developed with substantial assistance from AI
coding agents under maintainer-owned requirements, review, and testing. Version 3.3.0
remains available as the last human-written release for users whose provenance policy
requires it.

The disclosure also distinguishes provenance from assurance: version 3 does not inherit
the correctness, repository-layout, transaction-safety, packaging, or verification
requirements introduced in version 4, and human authorship is not presented as a
security guarantee.

**Why:** Users may treat code-generation provenance as an adoption constraint. They
should be able to make that choice without being led to equate authorship with safety or
to assume that the two major versions provide the same guarantees.

## Project-Owned Installation, npm Bootstrap and Compatibility

The recommended installation path uses a version-pinned `npx` command as a one-time
bootstrap to copy the npm package's standalone shell executable to a project-owned path
so the repository can commit it for ordinary review. Committing that result is an
explicit user obligation; the command does not modify the Git index. This does not
require keeping the npm package as a project dependency. A direct, checksum-verifying
download remains available when npm is unavailable.

Generated Git hook entrypoints remain per-checkout derived files, so a fresh clone
activates the committed executable with its explicit `install` command.

The optional npm vendoring destination remains a supported repository-relative
interface. The standalone installer also accepts a normal shell path, with relative
values interpreted from its caller's working directory. Both paths are preflighted
before hook setup and must resolve to an ordinary committable location inside the
current worktree, never through a symlink or into a Git administrative directory.
Comparisons against Git administrative paths are ASCII case-insensitive so that a
destination rejected on a case-insensitive supported filesystem is rejected
conservatively elsewhere; ordinary worktree containment is not generally case-folded.

The npm package is a convenience and compatibility path. A local npm installation
attempts to run `git-hook-pure install` automatically when npm permits dependency
lifecycle scripts. `GIT_HOOK_PURE_SKIP_INSTALL=1` disables that attempt; other values do
not. Global npm installation does not configure hooks.

Automatic setup is a convenience, not the only control path:

- Success emits commands for explicit uninstall and for skipping future automatic
  setup.
- Failure does not make the npm package unavailable. It reports that hooks did not take
  effect and gives the explicit repair command.
- `git-hook-pure install` and `git-hook-pure uninstall` remain idempotent public
  commands independent of npm lifecycle behavior.
- Documentation states that npm may suppress lifecycle output or disable scripts, and
  gives the explicit command as the reliable recovery path.
- No operation changes system, global, or repository `core.hooksPath` configuration.

**Why:** A repository should be able to own and audit the complete manager it uses,
while npm-integrated projects retain a low-friction compatibility path. Users, CI,
security policies, and unsupported layouts keep an observable opt-out and a
deterministic manual command.

**Sources and platform bounds:** Automatic npm setup appears in the
[initial package manifest](https://github.com/bolasblack/git-hook-pure/blob/1.0.1/package.json)
and remains present in [3.3.0](https://github.com/bolasblack/git-hook-pure/blob/v3.3.0/package.json).
The [3.2.0 skip control](https://github.com/bolasblack/git-hook-pure/commit/a2383662701fbd8cbfe5744e22c59af7818b75a9)
makes that convenience optional, while the
[3.3.0 command entry](https://github.com/bolasblack/git-hook-pure/commit/78f0176e3c63ee0e30d1a86801d05d827df569a1)
provides explicit control. npm's current
[script](https://docs.npmjs.com/cli/using-npm/scripts/),
[logging](https://docs.npmjs.com/cli/using-npm/logging/), and
[install](https://docs.npmjs.com/cli/install/) contracts mean dependency lifecycle
scripts or their output may be disabled, so automatic setup cannot replace the explicit
command.

## Lossless Dispatch and Composition

Handlers run in filename order. Repository-wide handlers run before hook-specific
handlers, and managed handlers run before compatible pre-existing hook content.

- Every consumer receives the complete, correctly quoted argument list defined by its
  handler scope.
- Directory entries and entries whose basename begins with `.` are ignored in both
  repository-wide and hook-specific handler scopes.
- A Git-provided stdin stream is replayed byte-for-byte from the beginning to every
  supported consumer, including pre-existing hook content.
- A handler's non-zero status is returned unchanged and stops later managed handlers.
- A non-executable selected handler is an error, not a silent skip.

**Why:** Adding a dispatcher must not remove facts, weaken an existing policy, or force
projects to translate executable hook logic into a new configuration system.

## Existing Hook Ownership

Install and uninstall preserve user-owned hook content and file modes exactly. They
recognize only an explicit v4 ownership declaration—an exact envelope with a matching
repository-format content object ID—or a complete historical v3 default dispatcher.
They reject ambiguous marker content and never infer ownership from a near match.

A v4 managed block carries a content identity independent of the manager currently
running. A changed or upgraded manager accepts a complete internally consistent v4
block, replaces it with its current dispatcher, and rejects content whose recorded
identity does not match its managed content.

The object ID proves internal content consistency, not authorship or authenticity;
someone able to edit a local hook can recompute it. Hook execution does not perform this
check. It governs the later manager operations that replace or remove an owned block.

The complete target set is preflighted before mutation. Changes are idempotent and use
one transaction owner; ordinary failures and supported termination signals roll back
the whole hook set. If rollback cannot finish, recovery material is retained and
reported rather than deleted.

**Why:** Existing Git hooks may enforce security or release policy. Convenience setup
must not overwrite, bypass, partially replace, or irreversibly reinterpret them.

**Source:** The [1.2.0 coexistence change](https://github.com/bolasblack/git-hook-pure/commit/92e790a140f48c1e48b98224434ba38b6a75f099)
replaced destructive hook overwrites with composition and added uninstall. Coexistence
is the requirement; its historical marker and rewriting mechanics are not.

## Git-Native Repository Semantics

Repository, worktree, Git directory, and hook paths come from Git. Nested monorepo
directories, linked worktrees, submodules, and explicitly mapped separate Git
directories resolve according to their real Git layout. A layout that cannot map a
hook execution back to project-owned `.githooks` is rejected before mutation.

Install, uninstall, and the installed dispatcher require Git's usable absolute-path
resolution capability. A Git command that succeeds but returns a malformed non-absolute
path is treated as an unsupported capability and fails closed. Repository-independent
commands such as help and version do not require a Git repository or this capability.

Any visible `core.hooksPath` definition is an ownership conflict and causes install or
uninstall to fail before mutation. The tool does not reset, override, or follow it.

**Why:** `.git` is not always a directory beside the worktree, and Git exposes only one
active hook path. Guessing either fact can install inactive hooks or modify hooks owned
by another system.

## Only Composable Git Hook Protocols

The installer manages only hook protocols that have a defined and tested fan-out model
for arguments, stdin, stdout, status, and pre-existing hook composition. A hook is not
added merely because Git documents its name. Bidirectional, transactional, or
structured-output protocols remain unsupported until their composition semantics and
integration coverage are explicit.

**Why:** Pretending to support an incompatible protocol can corrupt Git's conversation
or silently turn a rejecting policy into an accepting one.

## Minimal, Verifiable Distribution

Source code may be split into maintainable modules, but releases provide one
self-contained Git hook command whose runtime has no third-party package dependency.
Builds are deterministic and publish only validated artifacts. The npm package contains
the command plus the minimum adapters needed to vendor it and to perform compatible
automatic setup.

The npm bootstrap copies the exact command shipped inside the pinned package, performs
hook setup from that staged command, and publishes it at the project-owned path only
after setup succeeds. It relies on the integrity of the selected npm package and on the
package's tested manifest and embedded command version agreeing; it does not fetch a
second checksum for the package's own file. Users still trust the npm publisher to
publish those reviewed package contents under the selected version.

The no-npm installer separately pins a release version, verifies the downloaded release
checksum and embedded version before execution, performs hook setup from the verified
staged command, and publishes that command only after setup succeeds. In both cases the
result is readable shell source intended to be committed, inspected, modified, and
reviewed with the project. Editing the manager requires rerunning `install`; editing a
`.githooks` handler takes effect directly.

Vendoring reduces hook-manager dependency surface and makes changes auditable; it does
not eliminate trust in the initial npm or download bootstrap, its registry or hosting
service, or the package and release publisher.

**Why:** Development structure should improve review and testing without making a
consumer reconstruct the program or trust an unverified download.

**Source:** The [3.0.0 distribution](https://github.com/bolasblack/git-hook-pure/tree/v3.0.0)
added an installation path independent of npm or Yarn. The current deterministic bundle
and verified installer preserve that choice while tightening its trust boundary.

## Ecosystem-Neutral Project Maintenance

Recurring repository maintenance entrypoints that apply across distribution ecosystems
have one ecosystem-neutral owner in `.mise.toml`. Ecosystem-specific manifests are
distribution adapters, not alternative authorities for build or test behavior. A future
Python, npm, or other package must reuse those neutral tasks instead of copying their
implementation into its own manifest.

An ecosystem manifest may retain lifecycle glue that the ecosystem itself must invoke.
For example, `package.json` keeps npm's `prepack` hook as a thin delegation to
`mise run build`, preserving npm's automatic pre-pack build without duplicating it. It
also keeps `postinstall` because best-effort automatic hook setup is behavior of the npm
compatibility package and must run in consumer environments without requiring mise.
Neither adapter makes npm the owner of repository build or test workflows.

**Why:** The project may be published through more than one package ecosystem. Its
maintenance workflow must remain reusable and independently understandable instead of
making npm the architectural center of the repository.

## Public-Behavior Verification

The ecosystem-neutral test task runs the same black-box integration suite against the
source entry and the newly built standalone artifact. Package behavior is tested from
the packed tarball in fresh Git and non-Git consumers, including byte-identical one-time
vendoring, automatic success, failure, opt-out, and disabled lifecycle scripts. Release
validation binds version, release note, exact tag commit, artifact inventory, and
checksum before publication.

**Why:** Source-only tests can pass while the shipped executable, package lifecycle, or
release artifact is broken. The exact distributed forms are the product.
