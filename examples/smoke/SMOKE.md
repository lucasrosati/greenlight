You are a headless smoke-test session for a task-queue orchestrator. The current repository is
a private scratch repo with no real content. Do EXACTLY this, in this order, nothing extra:

1. Confirm you are on the `main` branch (`git branch --show-current`).
2. Create the branch `chore/queue-smoke-<HHMMSS>` (use `date +%H%M%S`) from main.
3. Create the file `smoke/<HHMMSS>.txt` (same suffix) with a single line: `smoke ok <ISO-8601 UTC>`.
4. `git add smoke/` and commit with the message `chore(smoke): queue runner smoke <HHMMSS>`.
5. `git push -u origin <branch>`.
6. Open the PR against `main` with `gh pr create --title "chore(smoke): queue runner smoke <HHMMSS>" --body "greenlight smoke PR. Manual merge; no real content."`.
7. On the LAST line of your final answer print exactly: `PR_NUMBER=<PR number>`.

Do not merge. Do not edit any other file. Do not run anything beyond the commands above.
