#!/usr/bin/env bash
# Stub BABYSIT_COMMAND for the smoke harness (docs/testing.md).
# STUB_MODE selects the contract case to exercise:
#   plain    (default) — clean exit, no marker           → handover says "ready for review"
#   deferred          — prints DEFERRED_FINDINGS=2       → handover says "2 deferred finding(s)", prs.txt gets deferred=2
#   dirty             — leaves the tree dirty on purpose → runner must save logs/<TASK>-babysit-leftover.diff and stop
echo "stub babysit on PR #$PR_NUMBER task=$TASK_ID cwd=$(pwd) mode=${STUB_MODE:-plain}"
case "${STUB_MODE:-plain}" in
  deferred) echo "found 2 review findings that are author decisions"; echo "DEFERRED_FINDINGS=2" ;;
  dirty)    echo "stub leftover" >> README.md; mkdir -p smoke && echo "untracked" > smoke/stub-leftover.txt ;;
  plain)    ;;
esac
exit 0
