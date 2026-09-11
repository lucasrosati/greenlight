# Runbook

## Layout

```
greenlight/
├── greenlight.sh              # orchestrator (bash 3.2-compatible)
├── lib/checks.sh              # CI gate policy: count | names | list
├── lib/orca.sh                # best-effort reporting to an Orca worktree card
├── greenlight.env             # your settings (gitignored; --env <file> for others)
├── claude-settings.json       # optional local allow/deny; falls back to the example
├── queue.txt                  # the queue (1 task-id per line; "#" comments)
├── prompts/<TASK>.md          # one prompt per task (gitignored)
├── state/done.txt             # finished task-ids (1 per line)
├── state/prs.txt              # TASK<TAB>PR<TAB>PHASE<TAB>GATED_SHA[<TAB>deferred=n] (append-only; last line wins)
├── state/runner.pid           # only while running (a leftover one = the previous run died by a hard signal)
├── state/heartbeat            # last log line's time + task/step; read by the preflight when the pidfile is stale
└── logs/                      # runner.log · <TASK>.json/.err · <TASK>-babysit.out · <TASK>-checks.log
```

## "How do I stop it right now?"

```bash
kill -TERM $(cat state/runner.pid)
```

The trap logs `INTERRUPTED at <TASK> in step <STEP>`, emits the interruption comment, and exits
130. **Ctrl+C only works with the runner in the foreground of a terminal**: a background job of a
non-interactive shell starts with SIGINT ignored, and bash does not trap a signal that was ignored
on entry. The pidfile is removed on exit; if it does not exist, the runner is not running. A
headless session in progress dies with the runner.

## Launching (and why the command order matters)

```bash
nohup caffeinate -is ./greenlight.sh queue.txt --env my.env >> logs/run-$(date +%F).out 2>&1 &
disown   # zsh: detach the job so closing the shell never touches it
```

`nohup` shields only its direct child from the terminal's SIGHUP. `caffeinate -is nohup …`
(the other order) leaves `caffeinate` exposed: closing the terminal kills it, the runner survives
but the laptop is free to sleep — and a runner asleep in `sleep "$BABYSIT_DELAY_S"` or in the
merge poll is exactly the one that gets killed later. `>>` keeps one log across relaunches.

A second launch while a runner is alive is refused in preflight (`another runner is alive (pid N)
— stop it with: kill -TERM N`): two queues on the same `REPO_DIR` would `checkout` under each
other's session. The refused launch leaves the live runner's pidfile and heartbeat untouched.

## "The runner died in the middle of task X. Now what?"

1. `tail -5 logs/runner.log` — the last `FAILED at X in step <STEP>` line says where it stopped.
   **No `FAILED at` line, process gone, `state/runner.pid` still there** = a hard signal
   (SIGKILL, OOM, reboot): the exit trap never ran. `state/heartbeat` holds the last log's time
   and task/step. Nothing to clean by hand — the next launch logs `stale runner.pid (pid N is
   not running) … last seen alive at <time> in <task/step>`, removes it and resumes from
   `state/prs.txt`. Measured case (2026-09-10): the runner died inside `sleep
   "$BABYSIT_DELAY_S"` with the PR at `gated`; the relaunch ran the babysit, and since the head
   had moved, redid only the gate (`ci-gate-new-head`) before the handover — expected behavior.
2. `grep '^X' state/prs.txt | tail -1` — the recorded **phase** of X's PR:

| phase in `prs.txt` | what already happened | rerun does | human action before rerun |
|---|---|---|---|
| *(no line)* | the session did not open a PR (or died before recording it) | re-runs the task from scratch (new session) | `gh pr list` in the repo: if the session opened a PR the runner did not record, add `X<TAB>N<TAB>opened` to `prs.txt` (never let it open a duplicate) |
| `opened` | PR exists | CI gate → babysit → handover | none |
| `gated` | CI green on the sha in column 4 | babysit → handover | none |
| `babysat` | babysit ran (once, never repeats) | if head ≠ gated sha, redo **only the gate**; then handover/polling | none |
| `merged` | merge validated on the local base branch | only persists to `done.txt` | none |

3. The PR's state on GitHub decides before the phase: `OPEN` → resume at the phase; `MERGED` →
   validate the merge and persist; `CLOSED` → the runner **aborts asking for a decision**: remove
   X's lines from `prs.txt` (new PR on the next run) or drop X from the queue.
4. Rerun = **the same command**. Tasks in `state/done.txt` are skipped.

Failures that need fixing outside the runner before a rerun: red CI (`logs/<X>-checks.log`), a
dirty working tree in `REPO_DIR` (the session left an uncommitted file; the runner **never** does
stash/clean), a diverged `pull --ff-only`.

## Preflight (once at boot, fails early)

`state/runner.pid` absent, stale (logged + removed) or **alive (abort)** · `REPO_DIR` is a git
repo with a working tree · settings file is valid JSON · `git gh jq perl claude` on PATH · **a
prompt exists for every pending task** (names the missing ones) · clean working tree (untracked
included) · required checks resolved per `CHECKS_MODE` · `gh auth status`. Liveness is
`kill -0 <pid>` (the process exists), not a `ps` name match. `--dry-run` skips the pidfile check.

## The loop per task

```
1 clean base    git checkout <base> && git pull --ff-only (aborts if dirty/diverged)
1b sync-env     SYNC_COMMAND in REPO_DIR (install deps, codegen); tree must stay clean
2 session       claude -p < prompts/<TASK>.md --settings <SETTINGS_FILE> --permission-mode acceptEdits
                (cwd=REPO_DIR, JSON in logs/<TASK>.json; requires subtype=success, is_error=false, clean tree)
3 detect PR     PR_NUMBER=<n> marker (last occurrence in .result) → fallback gh pr list (head contains
                the lowercase task-id AND createdAt > start; >1 candidate = abort) → PR OPEN, head ≠ base
                                                                                    → phase opened
4 CI gate       single ci_gate function (see README)                                → phase gated
5 babysit       [sleep BABYSIT_DELAY_S] BABYSIT_COMMAND once; DEFERRED_FINDINGS=<n> marker read;
                clean tree required (leftover saved otherwise); back to base;
                if headRefOid moved → ci_gate again                                 → phase babysat (deferred=n)
6 handover      status in-review + comment; polling gh pr view --json state
7 manual merge  MERGED → continue · CLOSED → abort the queue · OPEN → sleep
8 post-merge    checkout base + pull --ff-only; mergeCommit ⊂ local HEAD             → phase merged
                done.txt · comment "merged, moving on"
```

## Failure modes

| symptom | cause | action |
|---|---|---|
| `prompt(s) missing ...` at boot | `prompts/<TASK>.md` absent | write the prompt; nothing ran |
| `dirty working tree in REPO_DIR` | leftover from a previous session or manual work | resolve by hand (commit/stash/discard); the runner never cleans |
| `pull --ff-only` failed | local base branch diverged | `git -C $REPO_DIR status`; resolve; rerun |
| `SYNC_COMMAND failed (see logs/env-sync.log)` | install/codegen exited non-zero | read `logs/env-sync.log`; fix the environment; rerun (nothing else ran) |
| `SYNC_COMMAND dirtied the working tree` | codegen wrote to a versioned path | discard by hand; make the generated output gitignored or move it; rerun |
| `task session exceeded TASK_TIMEOUT_S` (exit 142) | long or stuck task | read the partial `logs/<TASK>.json`; raise `--task-timeout`; rerun |
| `task session did not succeed (subtype=...)` | session error | read `logs/<TASK>.json` and `.err`; rerun re-runs the task |
| `no PR detected` / `ambiguous fallback` | no `PR_NUMBER=` and branch without the task-id | `gh pr list`; record `opened` by hand in `prs.txt` or close the duplicate; rerun |
| `PR #N has head=<base>` | session committed on the base branch | revert by hand; invariant violated — investigate the prompt |
| `no check-run appeared` | CI did not trigger | check the workflow on GitHub; rerun |
| `CI red on PR #N` | checks failed | `logs/<TASK>-checks.log`; fix (or babysit manually); rerun resumes at `opened` |
| `required check(s) MISSING` | job renamed/removed | compare the required names with `gh pr checks`; it is a gate, not noise |
| `CI gate by COUNT` warn on every gate | `CHECKS_MODE=count` | expected in scratch repos; in production prefer `names` or `list` |
| `CHECKS_JQ_FILTER produced no check names` | source file or filter changed | run `jq -rRs "$CHECKS_JQ_FILTER" $REPO_DIR/$CHECKS_SOURCE` by hand |
| `head of PR moved DURING the gate` | concurrent push | rerun (redoes only the gate) |
| `babysit violated the clean-tree contract` | babysit changed files without commit/revert | read `logs/<TASK>-babysit-leftover.diff`; commit, push or discard by hand; the phase is still `gated`, so the rerun runs the babysit again (at least once) |
| `handover: ... with N deferred finding(s)` | babysit deferred review findings to the author | not a failure: read the PR threads and decide before merging |
| `gh pr view failed 5 times in a row` | gh/network/API down | warns from the 3rd; rerun resumes at `babysat` |
| `PR #N was CLOSED without merge` | human decision | clear the task's lines in `prs.txt` (new PR) or drop it from the queue |
| `merge commit ... is NOT in local <base>` | base diverged after merge | `git -C $REPO_DIR log`; resolve; rerun (PR MERGED → only persists) |
| `WARN: orca cannot resolve worktree` | repo not managed by Orca | expected outside Orca; set `ORCA_ENABLED=0` to silence |
| `orca CLI not found` | runner outside an Orca terminal | expected; reporting becomes a no-op |

## Babysit timing and deferred findings

A review bot that comments minutes after the PR opens can arrive after the babysit already
ran. `BABYSIT_DELAY_S` (default 0) sleeps between the green gate and the babysit so those
comments land first. The trade-off is a fixed delay on every task versus a babysit that is blind
to late reviews; pick a value from the bot's typical latency, not a worst case. Reviews that
arrive **after** the babysit are, by design, the human's responsibility at merge time: the
babysit runs at most once.

Findings the babysit defers to the author are surfaced through the `DEFERRED_FINDINGS=<n>`
marker (see the prompt contract). `state/prs.txt` records `deferred=n` on the `babysat` line;
lines written before this annotation existed have four columns and still parse.

## State cleanup

- Re-run a finished task: remove its line from `state/done.txt` **and** its lines from `prs.txt`.
- Open a new PR for a task whose PR is `CLOSED`: remove its lines from `prs.txt`.
- Start over: `rm -f state/done.txt state/prs.txt` (never during a run; check the pidfile).
- `logs/` grows per task; prune by hand.

## Headless shell gotchas

The Claude Code permission matcher matches commands by **shape**, not by intent. These were
measured with the example allow/deny list; put the relevant ones in your task prompts so the
session does not burn turns rediscovering them (a denied command is not fatal, the session
recovers, but a dozen denials in a row is a wasted session).

| denied | why | use instead |
|---|---|---|
| `git -C <path> <sub>` | the allow matches the prefix `git <sub>`; `-C` comes first | `git <sub>` from the repo root |
| `pnpm --dir/-C/--filter <pkg> …`, `npx --prefix <pkg> …`, `<pkg>/node_modules/.bin/<tool>`, `node <pkg>/node_modules/…` | not in the allow list | `cd <pkg> && npx jest <spec>` (one `cd` + `&&` + one allowed tool; cwd resets per call) or `npx jest --rootDir <pkg> <spec>` |
| subshell `( cd x && … )` | not matched | `cd x && …` without parentheses |
| `$(…)` anywhere (`--body "$(cat <<EOF…)"`) | command substitution | write the PR body to a file and use `--body-file <file>` |
| `> file` redirects (`npx jest > out.log 2>&1`) | write redirect | `npx jest 2>&1 \| tail -40` |
| one-liner with assignment (`S=$(date) && git checkout -b "x-$S" && …`) | not matched | separate commands |
| inline functions (`f() { … }`), `eval`, `sed -i` | not matched / by design | separate commands; edit with the Edit tool |
| `grep`/`sed` on `.env.example` | a glob deny like `Read(**/.env.*)` also catches `.example` | the example settings deny an explicit list of secret files (`.env`, `.env.local`, `.env.development`, `.env.production`, `.env.staging`, `.env.test`, `.env.bak`, `.env.backup`) so `.env.example` stays editable; tell the prompt to never read `.env*` other than `.env.example` even when allowed |
| `pnpm -C <pkg> …`, `pnpm --dir <pkg> …`, `pnpm --filter <pkg> …` | measured: a global flag before the subcommand breaks the `pnpm <sub>:*` prefix (`pnpm install --filter x` passes the matcher, but only means something in a workspace) | `cd <pkg> && npx <tool> …` or `npx <tool> --rootDir <pkg> …` |
| Write into `.git/…` or `/tmp/…` (PR body, reply, commit message) | writes outside the working tree (and into `.git/`) are denied | a gitignored dir inside the repo (e.g. `tmp/`), checked with `git check-ignore`; if the repo has none, the prompt must stop and report, never edit `.gitignore` on its own |
| backticks or `$(` inside an inline argument (`gh api -f body='… \`sha\` …'`) | read as command substitution | write the text to a file and pass `--body-file` / `-F body=@file` |
| env prefix (`VAR=x cmd`), `export VAR; cmd`, `env PATH=… cmd` | the matcher sees the assignment/`export`/`env` as the command | pass the tool's CLI flag instead |
| `${PIPESTATUS[0]}` / `${pipestatus[0]}` after a pipe | parameter expansion in the command | run the tool without a pipe when the exit code matters |
| `npm …` in a pnpm repo | not in the allow list on purpose | `pnpm …` |
| `sed` with `\x1b`/bracket escapes inside a pipe | denied without an isolated cause | avoid; filter with `grep`/`cut` |

Note on measurement: these rows come from an aggregate of 105 denials across nine real sessions and one
probe session; the prompts that carried the rules above went from 18–28 denials per task to 5.

**Pass** (measured): `2>/dev/null`, `2>&1 | head`, `sed 's/a/b/'`, `cut`, `sort`, `R=x; ls $R`,
globs, `--include`, chains with `;`, plain `git <sub>`, `gh pr create/view/list/checks/diff/comment`,
`gh api`, `npx jest/tsc/prettier/eslint`, `pnpm install/build/test/lint/exec`, `node -e`, `python3`,
`perl -e`.

Decision worth copying: do **not** widen the allow list for `git -C` (a wildcard in the middle,
`Bash(git -C * status:*)`, does not match) or for `cd … &&`, `$(…)`, `> file`. The compound deny
on `cd` is real protection. Add exact entries (no glob) when a specific tool is needed.

## Operational notes

- The deny list binds **only** the headless sessions of the queue. Interactive sessions in the
  repo are not prevented from merging; merge is human discipline. Do not run interactive sessions
  in auto mode on the target repo during a queue run.
- If the allow list proves insufficient, the session JSON lists `permission_denials` (the runner
  logs the count). Report the commands; do not escalate to `--dangerously-skip-permissions`.
- Comments sent to the Orca card carry only task-id, PR number and state — never a diff, env or
  code excerpt.
- A single babysit has no channel for an **author decision**: when a review bot raises a finding
  and defers it to the author, the queue hands over a PR with an open thread. `in-review` means
  the human reads the threads **before** merging; a deferred thread is a pending decision, not
  "no findings".
- Two independent reviewers (a bot plus a human) catch what a full green CI does not. "All checks
  green" is a precondition for handover, not proof of readiness.

## Regression smoke (after any change to the runner)

Use a throwaway repo with a trivial workflow (two jobs, e.g. `lint` and `test`) and two prompts
(`SMOKE.md`, `SMOKE2.md`) that create a file, open a PR and print `PR_NUMBER=`:

```bash
rm -f state/done.txt state/prs.txt && printf 'SMOKE\nSMOKE2\n' > queue.txt
export REPO_DIR=/path/to/smoke-repo CHECKS_MODE=list REQUIRED_CHECKS="lint,test"
./greenlight.sh queue.txt --dry-run                                   # 0. plan, exit 0
nohup ./greenlight.sh queue.txt --poll-interval 15 > logs/smoke.out 2>&1 &
```

Checklist (any deviation is a finding):
1. Boot: required checks logged by name; Orca warn at most once.
2. SMOKE: `PR detected by marker`, `prs.txt` at `opened`; gate OK by name → `gated`.
3. Babysit (if configured; leave an objective comment on the PR to force a push): `push detected`
   → re-gate on the new sha → `babysat` twice with different shas.
4. `handover:` + heartbeat after 10 polls. `kill -TERM $(cat state/runner.pid)` → `INTERRUPTED`,
   state intact; rerun resumes at `babysat` **without** a new babysit.
5. Manual squash merge (`gh pr merge N --squash`): `MERGED` on the next poll; `merge validated:
   <squash-sha> ⊂ main@...`; `prs.txt` `merged` before `done.txt`; SMOKE2 starts from the squash sha.
6. SMOKE2 up to the handover; `gh pr close N` → `CLOSED without merge`, exit 1.
7. Rerun: SMOKE skipped by `done.txt`; SMOKE2 `CLOSED` aborts asking for a decision; `gh pr list` = 0 open.
8. (optional) `GH_BIN=<wrapper that fails on demand>`: 4 failures → warn at the 3rd, recovery; 5 → abort.
9. `git -C <smoke-repo> branch --show-current` = base branch, clean tree, `runner.pid` removed.
10. Stale pidfile: `echo 999999 > state/runner.pid`, launch → first preflight line is
    `stale runner.pid (pid 999999 is not running) … last seen alive at … in …`, the run goes on
    normally. (An empty queue — every task in `done.txt` — is enough: the check is in preflight.)
11. Runner alive: launch twice → the second dies in preflight with `another runner is alive
    (pid N, state/runner.pid) — stop it with: kill -TERM N`, exit 1; `state/runner.pid` still
    holds N and `state/heartbeat` is unchanged (the refused launch owns neither).
