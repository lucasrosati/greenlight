# Changelog

## Unreleased

- Babysit contract: `DEFERRED_FINDINGS=<n>` marker surfaced at handover (comment, warn log,
  `deferred=n` annotation on the `babysat` line; older 4-column lines still parse). Never
  blocks the merge.
- Babysit clean-tree violation: leftover status/diffs/untracked list saved to
  `logs/<TASK>-babysit-leftover.diff` before the runner stops; files named in the error.
- `BABYSIT_DELAY_S` (default 0): wait between the green gate and the babysit for late review bots.
- `SYNC_COMMAND` exercised in the smoke harness: success, non-zero exit (points at
  `logs/env-sync.log`), and versioned-file dirt all behave as documented.
- Docs: lessons from production runs and a design sketch for `stream-json` in-flight visibility.
- Parity smoke passed against a scratch repo with real CI (two named checks) and a real
  babysit command: PR detection by marker, gate by name, babysit push → re-gate on the new
  sha, SIGTERM + resume without repeating the babysit, human push → gate-only redo, squash
  merge validated by merge commit, PR closed without merge → abort with a decision request.
  No code changes were needed.

## v0.1.0 — 2026-09-08

Initial public release. Ported from a private, single-project runner into a generic tool.

- Serial queue runner: clean base → headless session → PR detection → sha-bound CI gate →
  optional babysit → human handover → merge validation on the base branch.
- `lib/checks.sh` with `CHECKS_MODE=count|names|list`.
- All configuration via environment, with an optional env file (`--env`); precedence is
  flags > shell environment > env file.
- `SYNC_COMMAND` and `BABYSIT_COMMAND` as pluggable hooks.
- Best-effort Orca worktree reporting.
- Docs: runbook, prompt contract, design notes.

Validated by syntax check and dry-run only; a full parity smoke against a scratch repo with
real CI follows in the next release.
