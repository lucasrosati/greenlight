#!/usr/bin/env bash
# Stub SYNC_COMMAND for the smoke harness (docs/testing.md). Runs in $REPO_DIR.
# STUB_SYNC_MODE selects the failure case the runner must handle:
#   ok    (default) — exit 0                                  → "environment synced"
#   fail            — exit 1                                  → abort pointing at logs/env-sync.log
#   dirty           — modifies a VERSIONED file, exits 0      → abort: sync dirtied the tree
echo "stub sync in $(pwd) mode=${STUB_SYNC_MODE:-ok}"
case "${STUB_SYNC_MODE:-ok}" in
  fail)  echo "simulated dependency failure" >&2; exit 1 ;;
  dirty) echo "# dirtied by stub sync" >> README.md ;;
  ok)    ;;
esac
exit 0
