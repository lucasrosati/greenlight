# Design

## Invariants

1. **Never auto-merge.** The runner waits for a human to merge; the headless sessions are denied
   `gh pr merge`. Merge is the human's decision and the only irreversible step.
2. **Never commit on the base branch.** Every task lives on its own branch and PR. A PR whose head
   is the base branch aborts the queue.
3. **One task = one headless session.** No context carries over; the prompt is the whole spec.
4. **Serial on the main checkout.** The next task starts only after the previous PR is merged and
   its merge commit is in the local base branch (merge-before-next).
5. **Fail-fast, resumable.** Any unexpected condition stops the queue with the task, step and
   command named. State in `state/` lets a rerun continue from the recorded phase.
6. **Zero secrets in logs and comments.** Reporting carries task-id, PR number and phase only.
7. **Reporting is best-effort.** Orca (or nothing) never blocks or fails the queue.
8. **The runner never writes inside `REPO_DIR`.** Only git/gh/claude do, and only through
   commands the runner issues with an explicit cwd.

## Phase machine

`state/prs.txt` is append-only; the last line per task wins. Phases are ordered:

```
(no line) ──run task──▶ opened ──ci_gate──▶ gated ──babysit──▶ babysat ──wait merge──▶ merged
```

`run_task` computes the rank of the recorded phase and runs only the steps above it. Two rules
make reruns safe:

- **`babysat` is recorded before the post-babysit re-gate.** The babysit is "at most once": a
  rerun interrupted during the re-gate never repeats it.
- **`ensure_head_gated` before handover.** If the current head differs from the gated sha (re-gate
  interrupted, or a human pushed), only the gate is redone.

The PR's live state on GitHub takes precedence over the recorded phase: `MERGED` skips to
persistence, `CLOSED` aborts and asks for a decision, anything else is an error.

## Why the gate is sha-bound

`gh pr checks` reports the rollup of the PR's current head. Right after a push it is empty, and if
the head moves while waiting, a green rollup can belong to a sha that was never inspected. The gate
therefore:

1. pins `headRefOid` on entry;
2. waits until check-runs for **that sha** exist (`commits/<sha>/check-runs`);
3. watches with `--fail-fast` (nothing reviews code that is about to change);
4. re-reads the head and aborts if it moved;
5. validates the check-runs of the pinned sha.

The gated sha is persisted in `prs.txt` and compared again before handover.

## Gating by name vs by count

Counting successful check-runs is the weakest gate: a job that was renamed or deleted from the
workflow "passes" by no longer existing. Name-based gating fails on a **missing** required check
("green by absence"). `lib/checks.sh` offers three modes and reads the required names at runtime
from the target repo (or from a literal list), never from memory. Count mode exists for scratch
repos and bootstrapping, and warns on every gate so it never becomes the silent default.

## Squash merge and merge validation

With squash merges the commit that lands on the base branch is the PR's `mergeCommit`, **not** the
branch's `headRefOid`. Post-merge validation is `git merge-base --is-ancestor <mergeCommit> HEAD`
after `checkout <base> && pull --ff-only`. Comparing against the branch head would be a bug for
squash and rebase merges alike. Only after this validation is the task recorded in `done.txt`.

## PR detection

The prompt contract asks for a `PR_NUMBER=<n>` marker on the last line of the session result. The
fallback is deliberately narrow (one open PR by the runner's user, head containing the task-id,
created after the session started); zero or several candidates stop the queue rather than guess.

## Babysit as a pluggable command

The original implementation ran a second headless session with a review skill. That is an
environment detail, so it became `BABYSIT_COMMAND`: any command, run once in the repo with the PR
number in the environment. If it pushes, the full gate re-runs; if it dirties the tree, the queue
stops. Two lessons shaped the contract:

- A single automated pass has no channel for **author decisions**. When a review bot defers a
  finding to the author, the PR is handed over with an open thread; the human must read threads
  before merging. Handover status `in-review` means "the ball is with you", not "no findings".
- The babysit needs the same shell rules as the task prompt. Without them it rediscovers the
  permission matcher's denials, fails to commit a legitimate fix, and aborts the queue.

## Shell and platform constraints

- **bash 3.2** (macOS default): no associative arrays, no `;;&`, empty arrays guarded with
  `${arr[@]+"${arr[@]}"}`. A `set -u` error inside the EXIT trap exits with status 0, so a
  `FINISHED` flag distinguishes "reached the end" from "died silently".
- **No `timeout` on macOS**: `perl -e 'alarm shift; exec @ARGV'` gives a portable ceiling; exit
  142 means SIGALRM.
- **Signals**: a background job of a non-interactive shell ignores SIGINT; stop with `kill -TERM`
  and the pidfile.
- **Polling outside `set -e`**: transient `gh` failures during the merge wait count toward a
  threshold instead of aborting.
- **Explicit cwd everywhere**: `git -C` and `(cd … && gh …)` in the runner; the runner's own shell
  never changes directory.
- **Editing the runner**: avoid substring replacement with a non-unique anchor (`run_task() {`
  also matches `step_run_task() {`). Rewrite whole functions.

## Non-goals

- Parallel tasks or worktrees per task. Serial is the point: each task sees the previous merge.
- Auto-merge on green, even behind a flag.
- Orchestrating other agents' terminals or automations. The runner is the orchestrator.

## Possible extensions

- Per-task model (`TASK<TAB>MODEL` in the queue, `CLAUDE_EXTRA_ARGS` today).
- A configurable wait for a review bot before the babysit, since bots can arrive after the gate.
- A test that sweeps `claude-settings.json` against the commands the prompts actually use; today
  the `permission_denials` count in the logs is the only signal.
