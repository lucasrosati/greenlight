# Changelog

## v0.3.0 — 2026-09-09

Public-launch hardening: everything found by a fresh-clone audit. No changes to the sha-bound
gate or the phase machine.

- **Fixed:** first non-dry run on a fresh clone died in preflight — `log()` wrote to
  `logs/runner.log` before `mkdir -p` ran. The mkdir now opens preflight, and `logs/`, `state/`
  and `prompts/` ship with `.gitkeep`.
- **Fixed:** the PR-detection fallback (`gh pr list`) used `--jq` with `--arg`, a flag `gh`
  does not have; any task whose prompt failed to print `PR_NUMBER=` aborted with a gh usage
  dump instead of the documented candidate search. The JSON now pipes into real `jq`.
- **Changed:** Orca reporting is now **opt-in** (`ORCA_ENABLED=1`); non-Orca users no longer
  get a warn on every invocation.
- **Changed:** an explicitly set `SETTINGS_FILE` that does not exist is now a fatal error
  instead of a silent fallback to the example permissions. The unset default still falls back.
- `--version` flag and `GREENLIGHT_VERSION` constant.
- `.gitignore` hardened (`*.env.*`, `*.bak*`) so env-file backups cannot be committed.
- `examples/queue.example.txt` now runs out of the box with the single prompt the README
  creates (extra tasks are commented out).
- CI on this repo: `bash -n` + `shellcheck` on every PR.
- **Docs:** `docs/testing.md` — the regression smoke harness is now public
  (`examples/smoke/`: scratch-repo workflow, SMOKE prompts, stub babysit, stub sync cases,
  flaky-gh wrapper). Earlier changelog entries that mention "the smoke harness" referred to
  the author's private copy of exactly these files.
- README: version line, tool version floors, dry-run prerequisites, macOS `caffeinate` note,
  `ORCA_ENABLED` row, LICENSE link.

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
