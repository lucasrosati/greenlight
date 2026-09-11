# Testing — the regression smoke harness

Any change to the runner gets validated against a **real** GitHub repo with **real** CI before it
ships: `bash -n` catches syntax, `--dry-run` catches wiring, but only a full run exercises the
phase machine, the sha-bound gate, the babysit contract and resume-after-kill. This document
ships everything the run needs; the pass/fail checklist lives in
[runbook.md — Regression smoke](runbook.md#regression-smoke-after-any-change-to-the-runner).

Everything referenced here is in [`examples/smoke/`](../examples/smoke/):

| file | role |
|---|---|
| `ci.yml` | workflow for the scratch repo — two green jobs named `lint` and `test` |
| `SMOKE.md`, `SMOKE2.md` | task prompts satisfying [prompt-contract.md](prompt-contract.md) |
| `stub-babysit.sh` | `BABYSIT_COMMAND` stub — `plain` / `deferred` / `dirty` modes |
| `stub-sync.sh` | `SYNC_COMMAND` stub — `ok` / `fail` / `dirty` modes |
| `gh-flaky.sh` | `GH_BIN` wrapper that fails on demand (poll-failure ladder) |
| `smoke.env.example` | the env file wiring all of the above |
| `checks-unit.sh` | unit test of `lib/checks.sh` with stubbed GitHub calls — no repo, no network; CI runs it |

## 1. Create the scratch repo (once)

```bash
mkdir greenlight-smoke && cd greenlight-smoke
git init -b main
mkdir -p .github/workflows
cp <greenlight>/examples/smoke/ci.yml .github/workflows/ci.yml
echo "# greenlight smoke target — no real content" > README.md
git add -A && git commit -m "smoke target: trivial two-job workflow"
gh repo create greenlight-smoke --private --source . --push
```

Verify CI exists before the first run: open a trivial PR by hand (or push any branch) and check
that `lint` and `test` both report on the commit. The gate requires them **by name**.

## 2. Wire the env file

```bash
cd <greenlight>
cp examples/smoke/smoke.env.example smoke.env      # gitignored (*.env)
$EDITOR smoke.env                                  # REPO_DIR at minimum
printf 'SMOKE\nSMOKE2\n' > queue-smoke.txt
```

`PROMPTS_DIR` already points at `examples/smoke/`, so `SMOKE.md`/`SMOKE2.md` are found as-is.
`STATE_DIR`/`LOGS_DIR` point at `state/smoke` and `logs/smoke` so a smoke never touches real
queue state. **Mind the trap the harness itself once caught:** create the log directory before
any shell redirect of your own (`mkdir -p logs/smoke` — the runner creates it in preflight, but
a `> logs/smoke/run.out` redirect on your command line happens before the runner starts).

## 3. Run the matrix

Baseline run (both tasks, manual merges):

```bash
./greenlight.sh queue-smoke.txt --env smoke.env --dry-run     # plan, exit 0
rm -f state/smoke/done.txt state/smoke/prs.txt
nohup ./greenlight.sh queue-smoke.txt --env smoke.env > logs/smoke/run.out 2>&1 &
tail -f logs/smoke/run.out
```

Then walk the numbered checklist in
[runbook.md](runbook.md#regression-smoke-after-any-change-to-the-runner) — every deviation is a
finding. The stubs drive the branches the checklist needs:

- **Sync failure modes** — rerun with each mode and confirm the documented behavior:
  `STUB_SYNC_MODE=ok` (logs "environment synced"), `fail` (abort pointing at
  `logs/smoke/env-sync.log`), `dirty` (abort: sync dirtied a versioned file).
  Set the mode by editing `SYNC_COMMAND` in `smoke.env`.
- **Babysit contract** — `STUB_MODE=plain` (handover "ready for review"),
  `deferred` (handover "2 deferred finding(s)", `deferred=2` in `state/smoke/prs.txt`),
  `dirty` (runner saves `logs/smoke/<TASK>-babysit-leftover.diff`, reports the files, stops;
  clean the scratch repo by hand afterwards — the runner never cleans).
  Set the mode by editing `BABYSIT_COMMAND` in `smoke.env`.
- **Poll-failure ladder** — during the waiting-merge phase, point `GH_BIN` at
  `examples/smoke/gh-flaky.sh` and `touch /tmp/gh-flaky-on`: expect a WARN at the 3rd
  consecutive failure and abort at the 5th; remove the flag file before the 5th to see recovery.
- **Resume** — `kill -TERM $(cat state/smoke/runner.pid)` mid-run, rerun the same command,
  and confirm it resumes at the recorded phase without repeating finished work (no second
  babysit after `babysat`).

## 4. Cleanup

```bash
rm -rf state/smoke logs/smoke queue-smoke.txt
# in the scratch repo: close leftover PRs, delete smoke branches
```

The scratch repo is reusable across smokes; `state/done.txt` is what makes tasks idempotent,
so wiping `state/smoke/` is all a fresh smoke needs.

## What a smoke does NOT cover

- The permission matcher's deny-by-form behavior (that is probed against the real target repo —
  see [runbook.md — Headless shell gotchas](runbook.md#headless-shell-gotchas)).
- Provider outages mid-session, `CHECKS_MODE=names` parsing of a real workflow file (covered by
  `--dry-run` against the real repo), and Orca reporting (best-effort by design).
