#!/usr/bin/env bash
# GH_BIN wrapper that fails on demand, to exercise the poll-failure ladder
# (POLL_FAILS_WARN=3 → warn, POLL_FAILS_ABORT=5 → abort). Point GH_BIN at this file.
# Touch $GH_FLAKY_FLAG (default /tmp/gh-flaky-on) to make every call exit 1;
# remove it to recover. All other behavior is the real gh.
FLAG="${GH_FLAKY_FLAG:-/tmp/gh-flaky-on}"
if [[ -e "$FLAG" ]]; then echo "gh-flaky: simulated gh outage ($FLAG exists)" >&2; exit 1; fi
exec gh "$@"
