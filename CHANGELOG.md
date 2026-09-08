# Changelog

## v0.2.0 — 2026-09-08

Hardening from the first production queues. No changes to the sha-bound gate or the phase machine.

- Babysit contract: `DEFERRED_FINDINGS=<n>` marker surfaced at handover (comment, warn log,
  `deferred=n` annotation on the `babysat` line; older 4-column lines still parse). Never
  blocks the merge.
- Babysit clean-tree violation: leftover status/diffs/untracked list saved to
  `logs/<TASK>-babysit-leftover.diff` before the runner stops; files named in the error.
- `BABYSIT_DELAY_S` (default 0): wait between the green gate and the babysit for late review bots.
- `SYNC_COMMAND` exercised in the smoke harness: success, non-zero exit (points at
  `logs/env-sync.log`), and versioned-file dirt all behave as documented.
- Example settings: the `.env.*` glob denies are replaced by an explicit list of secret files, so a
  versioned `.env.example` stays editable. No new Bash allow entries: a review of 105 denials across
  nine real sessions found only composition shapes, wrong prompt prescriptions and one-offs.
- Runbook: gotchas for `pnpm` global flags before the subcommand, env-var prefixes, `${PIPESTATUS}`,
  backticks in inline arguments, and writes into `.git/` or `/tmp`.
- Docs: lessons from production runs and a design sketch for `stream-json` in-flight visibility.
- Parity smoke (v0.1.0 binary) and final regression smoke (this binary) passed against a scratch repo
  with real CI and a real babysit command.

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
