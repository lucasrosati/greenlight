#!/usr/bin/env bash
# examples/smoke/checks-unit.sh — unit test of lib/checks.sh with stubbed GitHub calls.
# No network, no repo: `sha_check_runs` and `pr_head_oid` are functions here. Run from anywhere:
#   bash examples/smoke/checks-unit.sh        (exit 0 = all cases pass; CI runs it)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

PASS=0; FAIL=0
# each case runs in a subshell: `die` there exits the subshell only; we assert on exit code + output
run_case() { # run_case <name> <expected-exit> <expected-regex> <mode> <required-csv> <settle-tries> <json-sequence...>
  local name="$1" want_rc="$2" want_re="$3" mode="$4" req="$5" tries="$6"; shift 6
  local out rc
  out="$(
    CHECKS_MODE="$mode" REQUIRED_CHECKS="$req" CHECKS_SETTLE_TRIES="$tries" CHECKS_SETTLE_SLEEP_S=0
    # shellcheck disable=SC2034  # read by lib/checks.sh
    REPO_DIR=/nonexistent; CUR_TASK=T; TASK_IDX=1; TASK_TOTAL=1
    log()  { echo "LOG $*"; }
    warn() { echo "WARN $*"; }
    die()  { echo "DIE $*"; exit 1; }
    orca_comment() { :; }
    # the API stub returns the next JSON of the sequence on every call, then keeps the last one
    SEQ=("$@"); I=0
    sha_check_runs() { local j="${SEQ[$I]}"; [[ $I -lt $((${#SEQ[@]} - 1)) ]] && I=$((I + 1)); echo "$j"; }
    pr_head_oid() { echo "${HEAD_OID:-aaaaaaaa1111}"; }
    # shellcheck source=../../lib/checks.sh
    source "$HERE/../../lib/checks.sh"
    checks_load >/dev/null
    checks_settle aaaaaaaa1111 7 && checks_verify "$CHECKS_SETTLED_JSON" aaaaaaaa1111 7
  )"; rc=$?
  if [[ $rc -eq $want_rc ]] && grep -Eq -- "$want_re" <<<"$out"; then
    PASS=$((PASS + 1)); echo "ok   - $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $name (rc=$rc want=$want_rc; want /$want_re/)"; sed 's/^/       /' <<<"$out"
  fi
}

ok='{"name":"lint","status":"completed","conclusion":"success"}'
ok2='{"name":"test","status":"completed","conclusion":"success"}'
late_run='{"name":"notify","status":"in_progress","conclusion":null}'
late_ok='{"name":"notify","status":"completed","conclusion":"success"}'
lint_run='{"name":"lint","status":"queued","conclusion":null}'

# 1. the measured race: a non-required check-run appears running, completes inside the window
run_case "late non-required check completes inside the window → gate OK, no warn" 0 '^LOG CI gate OK: 2/2' \
  list "lint,test" 3 "[$ok,$ok2,$late_run]" "[$ok,$ok2,$late_run]" "[$ok,$ok2,$late_ok]"
# 2. still running after the window, not required → warn + gate OK
run_case "late non-required check still running after the window → warn + gate OK" 0 'WARN ignoring non-required check-run\(s\) still running .*: notify' \
  list "lint,test" 2 "[$ok,$ok2,$late_run]"
# 3. a REQUIRED check still running after the window → die
run_case "required check still running after the window → die" 1 'DIE check-runs not yet completed .* after the settle window: lint' \
  list "lint,test" 2 "[$lint_run,$ok2]"
# 4. count mode: anything still running after the window → die
run_case "count mode: any check-run still running after the window → die" 1 'DIE check-runs not yet completed .* after the settle window: notify' \
  count "" 2 "[$ok,$ok2,$late_run]"
# 5. nothing pending → no settle iteration at all (no 'late check-run' line)
run_case "nothing running → no settle log line" 0 '^LOG CI gate OK: 2/2' \
  list "lint,test" 3 "[$ok,$ok2]"
# 6. the settle loop logs its progress
run_case "settle loop logs each wait" 0 'LOG late check-run\(s\) still running on aaaaaaaa \(1/3\): notify' \
  list "lint,test" 3 "[$ok,$ok2,$late_run]" "[$ok,$ok2,$late_ok]"
# 7. a required check missing on the sha is still "green by absence" → die (policy unchanged)
run_case "required check missing → die (green by absence)" 1 'DIE required check\(s\) MISSING' \
  list "lint,test,e2e" 1 "[$ok,$ok2]"
# 8. a completed non-required failure still aborts (policy unchanged)
run_case "completed non-required failure → die (unchanged)" 1 'DIE check-runs without success' \
  list "lint,test" 1 "[$ok,$ok2,{\"name\":\"notify\",\"status\":\"completed\",\"conclusion\":\"failure\"}]"

# 9. head moves inside the settle window → die "moved DURING the gate"
out="$(
  CHECKS_MODE=list REQUIRED_CHECKS="lint,test" CHECKS_SETTLE_TRIES=3 CHECKS_SETTLE_SLEEP_S=0
  REPO_DIR=/nonexistent; CUR_TASK=T; TASK_IDX=1; TASK_TOTAL=1
  log() { echo "LOG $*"; }; warn() { echo "WARN $*"; }; die() { echo "DIE $*"; exit 1; }; orca_comment() { :; }
  # the stub runs inside `$( )`, so it counts calls in a file, not a variable
  CNT="$(mktemp)"; : >"$CNT"
  pr_head_oid() { echo x >>"$CNT"; if [[ "$(wc -l <"$CNT")" -ge 2 ]]; then echo bbbbbbbb2222; else echo aaaaaaaa1111; fi; }
  sha_check_runs() { echo "[$ok,$ok2,$late_run]"; }
  # shellcheck source=../../lib/checks.sh
  source "$HERE/../../lib/checks.sh"
  checks_load >/dev/null
  checks_settle aaaaaaaa1111 7; rc=$?; rm -f "$CNT"; exit $rc
)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q 'DIE head of PR #7 moved DURING the gate (aaaaaaaa → bbbbbbbb)' <<<"$out"; then
  PASS=$((PASS + 1)); echo "ok   - head moves inside the settle window → die"
else
  FAIL=$((FAIL + 1)); echo "FAIL - head moves inside the settle window (rc=$rc)"; sed 's/^/       /' <<<"$out"
fi

echo "checks-unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
