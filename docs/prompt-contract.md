# Prompt contract

The runner is a black box around `prompts/<TASK>.md`. It does not care how the prompt is written
or generated; it cares about five observable outcomes. A prompt that honors them is picked up
automatically; one that does not makes the queue stop and ask a human.

## What the runner guarantees to the prompt

- cwd is `REPO_DIR`, on `BASE_BRANCH`, fast-forwarded to origin, with a clean working tree.
- `SYNC_COMMAND` (if configured) already ran: dependencies and generated code match the base.
- The session runs under `SETTINGS_FILE` (allow/deny) with `--permission-mode acceptEdits`.
  Merging, closing, force-pushing and pushing to the base branch are denied.
- The prompt is fed on stdin, so there is no size or quoting limit.
- Timeout: `TASK_TIMEOUT_S` (default 1 h). A session killed by the timeout fails the task.

## What the prompt must do

1. **Work on its own branch.** Create a branch whose name contains the task-id (lowercase is
   fine, e.g. `feat/task-101-short-slug`). Never commit on `BASE_BRANCH`: the runner aborts if
   the PR's head is the base branch.

2. **Open the PR with `gh pr create`** against `BASE_BRANCH`. Use `--body-file <path>` for the
   body (command substitution in `--body` is denied by the matcher). Write the file somewhere
   ignored by git, or delete it before finishing.

3. **Print the PR number on the last line**, exactly:

   ```
   PR_NUMBER=<number>
   ```

   The runner reads the last `PR_NUMBER=<n>` occurrence in the session result. Without it, the
   fallback looks for a single open PR authored by you whose head contains the task-id and that
   was created after the session started; zero or several candidates abort the task.

4. **Finish with a clean working tree.** Every change is committed and pushed; no stray files.
   The runner never stashes or cleans; a dirty tree aborts the queue with the diff preserved for
   a human.

5. **Do not merge, close, or force-push.** These are denied, but the prompt should not try. If a
   rebase is needed, say so in the PR body and stop.

## Recommended prompt skeleton

```
You are implementing <TASK-101>: <one-line title>.

Context: <what the feature is, where the code lives, what "done" means>.
Acceptance criteria: <named specs, tests to add or change>.
Do NOT: <explicit exclusions>.

Shell rules for this headless session: <paste the relevant gotchas from docs/runbook.md>.

When done:
- create branch feat/task-101-<slug> from the current base and commit there;
- run the project's lint and tests and make them pass;
- open the PR with `gh pr create --base main --title "..." --body-file <file>`;
- make sure `git status --porcelain` is empty;
- print exactly `PR_NUMBER=<number>` as the last line of your output.
```

## Optional: progress checkpoints on an Orca card

If the target repo is a worktree managed by Orca, the prompt may post intermediate milestones
(specs green, PR opened) with:

```
orca worktree set --worktree active --comment "TASK-101: specs green, opening PR"
```

`orca worktree set` is in the example allow list; other `orca` subcommands are denied. Inside the
session `--worktree active` resolves from the cwd (the repo), so it works; the runner itself,
which lives outside the repo, uses `path:<REPO_DIR>`.

## Optional: a babysit pass

If `BABYSIT_COMMAND` is configured, a second session runs once after the first green gate. Its
job is narrow: fix red CI, apply objective review comments, push, reply on the threads, leave the
tree clean. Give it the same shell rules as the task prompt; a babysit that gets a dozen
permission denials and cannot commit its fix leaves the queue aborted with a dirty tree.
