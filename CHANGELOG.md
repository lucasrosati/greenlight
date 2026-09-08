# Changelog

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
