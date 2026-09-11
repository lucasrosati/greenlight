#!/usr/bin/env bash
# greenlight.sh — serial task queue for headless Claude Code.
#
# For each task-id in the queue: reset the target repo to a clean base branch, run one
# headless `claude -p` session with prompts/<TASK>.md, detect the PR it opened, gate on CI
# (by check name or by count), optionally run a babysit command, then hand the PR to a human
# and wait for the MERGE to happen. Nothing merges without a human.
#
# Usage: greenlight.sh [queue.txt] [--dry-run] [--env <file>] [--repo-dir <path>]
#                      [--poll-interval 60] [--task-timeout 3600] [--babysit-timeout 1800]
#                      [--skip-babysit] [--version]
#
# Invariants: never auto-merge · never commit on the base branch · 1 task = 1 headless session ·
# serial on the main checkout · fail-fast with state in state/ · zero secrets in logs/comments ·
# Orca reporting is best-effort · NOTHING is written inside $REPO_DIR by this script.
#
# bash 3.2 compatible (macOS): no associative arrays, no `;;&`, empty arrays guarded.

set -euo pipefail

GREENLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- env file
# Optional: GREENLIGHT_ENV (or --env) points to a file sourced before defaults are applied.
# Default: <greenlight dir>/greenlight.env if it exists. See examples/greenlight.env.example.
_env_from_cli=""
_args=("$@")
_i=0
while [[ $_i -lt ${#_args[@]} ]]; do
  case "${_args[$_i]}" in
    --env) _i=$((_i + 1)); _env_from_cli="${_args[$_i]:-}" ;;
    --env=*) _env_from_cli="${_args[$_i]#*=}" ;;
  esac
  _i=$((_i + 1))
done
GREENLIGHT_ENV="${_env_from_cli:-${GREENLIGHT_ENV:-$GREENLIGHT_DIR/greenlight.env}}"
if [[ -n "$_env_from_cli" && ! -f "$GREENLIGHT_ENV" ]]; then
  echo "ERROR: env file not found: $GREENLIGHT_ENV" >&2; exit 1
fi
if [[ -f "$GREENLIGHT_ENV" ]]; then
  # precedence: command-line flags > shell environment > env file. Exported shell vars are
  # snapshotted and re-applied after the file is sourced.
  _pre_env="$(export -p)"
  set -a
  # shellcheck disable=SC1090
  source "$GREENLIGHT_ENV"
  set +a
  eval "$_pre_env"
  unset _pre_env
fi
unset _env_from_cli _args _i

# shellcheck source=lib/orca.sh
source "$GREENLIGHT_DIR/lib/orca.sh"
# shellcheck source=lib/checks.sh
source "$GREENLIGHT_DIR/lib/checks.sh"

# ---------------------------------------------------------------- configuration
GREENLIGHT_VERSION="0.3.1"
# Every setting is an env var. Paths default relative to the greenlight directory.
REPO_DIR="${REPO_DIR:-}"                                   # target checkout (required)
BASE_BRANCH="${BASE_BRANCH:-main}"
QUEUE_FILE="${QUEUE_FILE:-$GREENLIGHT_DIR/queue.txt}"
PROMPTS_DIR="${PROMPTS_DIR:-$GREENLIGHT_DIR/prompts}"
STATE_DIR="${STATE_DIR:-$GREENLIGHT_DIR/state}"
LOGS_DIR="${LOGS_DIR:-$GREENLIGHT_DIR/logs}"
SETTINGS_FILE_EXPLICIT="${SETTINGS_FILE:+1}"   # set by the user (shell or env file) vs defaulted below
SETTINGS_FILE="${SETTINGS_FILE:-$GREENLIGHT_DIR/claude-settings.json}"
SETTINGS_EXAMPLE="$GREENLIGHT_DIR/examples/claude-settings.example.json"
DONE_FILE="$STATE_DIR/done.txt"
PRS_FILE="$STATE_DIR/prs.txt"      # "TASK<TAB>PR<TAB>PHASE<TAB>GATED_SHA" (last line per task wins)
                                   # phases: opened → gated → babysat → merged
RUNNER_LOG="$LOGS_DIR/runner.log"
GH_BIN="${GH_BIN:-gh}"             # indirection to pin gh (or to simulate outages in tests)
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}"               # e.g. "--model claude-opus-5"

SYNC_COMMAND="${SYNC_COMMAND:-}"       # run in $REPO_DIR after the base is clean (install deps, codegen…)
BABYSIT_COMMAND="${BABYSIT_COMMAND:-}" # run in $REPO_DIR once per PR; empty = skip with a log line

DRY_RUN=0
POLL_INTERVAL="${POLL_INTERVAL:-60}"
SKIP_BABYSIT="${SKIP_BABYSIT:-0}"
TASK_TIMEOUT_S="${TASK_TIMEOUT_S:-3600}"
BABYSIT_TIMEOUT_S="${BABYSIT_TIMEOUT_S:-1800}"
BABYSIT_DELAY_S="${BABYSIT_DELAY_S:-0}"             # wait between the green gate and the babysit (review bots that comment late)
CHECKS_APPEAR_TRIES="${CHECKS_APPEAR_TRIES:-20}"    # × CHECKS_APPEAR_SLEEP_S waiting for check-runs to exist
CHECKS_APPEAR_SLEEP_S="${CHECKS_APPEAR_SLEEP_S:-15}"
POLL_FAILS_WARN="${POLL_FAILS_WARN:-3}"
POLL_FAILS_ABORT="${POLL_FAILS_ABORT:-5}"
HEARTBEAT_EVERY_POLLS="${HEARTBEAT_EVERY_POLLS:-10}"

# current state (read by the trap)
CUR_TASK="-"
CUR_STEP="boot"
CUR_PR=""
GATED_SHA=""
DEFERRED_N=0     # DEFERRED_FINDINGS=<n> reported by the babysit (0 = none/not reported)
TASK_START_TS=""
INTERRUPTED=0
PIDFILE_OWNED=0   # set once preflight writes state/runner.pid; the trap never removes another runner's pidfile
FINISHED=0   # bash 3.2: a `set -u` error exits with status 0 inside the trap — this flag closes that hole
TASK_IDX=0
TASK_TOTAL=0
declare -a PENDING=()
declare -a MERGED_PRS=()

# ---------------------------------------------------------------- utilities
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  local line="[$(ts)] [$CUR_TASK/$CUR_STEP] $*"
  echo "$line"
  [[ "$DRY_RUN" == "1" ]] && return 0
  echo "$line" >>"$RUNNER_LOG"
  # last-alive trace: a hard signal (SIGKILL/OOM/reboot) skips the exit trap, so this file is the
  # only record of where the runner was; the next preflight reports it when it finds a stale pidfile.
  # Only the runner that owns the pidfile writes it (a refused second launch must not clobber it).
  [[ "$PIDFILE_OWNED" == "1" ]] && echo "$(date -u +%FT%TZ) $CUR_TASK/$CUR_STEP" >"$STATE_DIR/heartbeat"
  return 0
}
warn() { log "WARN: $*" >&2; }
die() { # die <message> — always names task, step and (when there is one) the command
  log "ERROR: $*" >&2
  exit 1
}
usage() { sed -n '2,12p' "$0"; FINISHED=1; exit "${1:-0}"; }

# git/gh always with an explicit cwd in the repo — never `cd` in the runner's own shell
rgit() { git -C "$REPO_DIR" "$@"; }
rgh()  { (cd "$REPO_DIR" && "$GH_BIN" "$@"); }

# ---------------------------------------------------------------- trap
on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM
  [[ "${PIDFILE_OWNED:-0}" == "1" ]] && rm -f "$STATE_DIR/runner.pid"
  if [[ $rc -eq 0 && "$FINISHED" != "1" ]]; then rc=1; fi   # exited without reaching the end = failure
  if [[ "$INTERRUPTED" == "1" ]]; then exit "$rc"; fi          # on_signal already reported
  if [[ $rc -ne 0 ]]; then
    local msg="FAILED at $CUR_TASK in step $CUR_STEP"
    [[ -n "$CUR_PR" ]] && msg="$msg (PR #$CUR_PR)"
    echo "[$(ts)] $msg — exit $rc. Progress preserved in $STATE_DIR; resume = run the same command." >&2
    orca_status in-review
    orca_comment "$msg: exit $rc — see logs/runner.log"
  fi
  exit "$rc"
}
on_signal() {
  trap - INT TERM
  INTERRUPTED=1
  echo "[$(ts)] INTERRUPTED at $CUR_TASK in step $CUR_STEP. Progress preserved in $STATE_DIR." >&2
  orca_status in-review
  orca_comment "INTERRUPTED at $CUR_TASK in step $CUR_STEP$( [[ -n "$CUR_PR" ]] && echo " (PR #$CUR_PR)") — resume by running the runner again"
  exit 130
}
trap on_exit EXIT
trap on_signal INT TERM

# ---------------------------------------------------------------- args
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --skip-babysit) SKIP_BABYSIT=1 ;;
      --env) shift ;;                               # already consumed before sourcing
      --env=*) ;;
      --poll-interval) shift; POLL_INTERVAL="${1:?--poll-interval needs a value}" ;;
      --poll-interval=*) POLL_INTERVAL="${1#*=}" ;;
      --task-timeout) shift; TASK_TIMEOUT_S="${1:?--task-timeout needs a value}" ;;
      --task-timeout=*) TASK_TIMEOUT_S="${1#*=}" ;;
      --babysit-timeout) shift; BABYSIT_TIMEOUT_S="${1:?--babysit-timeout needs a value}" ;;
      --babysit-timeout=*) BABYSIT_TIMEOUT_S="${1#*=}" ;;
      --repo-dir) shift; REPO_DIR="${1:?--repo-dir needs a value}" ;;
      --repo-dir=*) REPO_DIR="${1#*=}" ;;
      -h|--help) usage 0 ;;
      --version) echo "greenlight $GREENLIGHT_VERSION"; FINISHED=1; exit 0 ;;
      --*) die "unknown argument: $1" ;;
      *) QUEUE_FILE="$1" ;;
    esac
    shift
  done
  [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || die "--poll-interval must be an integer (got: $POLL_INTERVAL)"
  [[ "$TASK_TIMEOUT_S" =~ ^[0-9]+$ ]] || die "--task-timeout must be an integer (got: $TASK_TIMEOUT_S)"
  [[ "$BABYSIT_TIMEOUT_S" =~ ^[0-9]+$ ]] || die "--babysit-timeout must be an integer (got: $BABYSIT_TIMEOUT_S)"
  [[ "$BABYSIT_DELAY_S" =~ ^[0-9]+$ ]] || die "BABYSIT_DELAY_S must be an integer (got: $BABYSIT_DELAY_S)"
  [[ -n "$REPO_DIR" ]] || die "REPO_DIR is required (env, env file, or --repo-dir)"
  [[ "$REPO_DIR" = /* ]] || REPO_DIR="$PWD/$REPO_DIR"
  [[ "$QUEUE_FILE" = /* ]] || QUEUE_FILE="$PWD/$QUEUE_FILE"
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    # Only the implicit default may fall back to the example. An explicitly set path that is
    # missing is a typo — headless sessions must not run under permissions the user never chose.
    [[ -z "$SETTINGS_FILE_EXPLICIT" ]] || die "SETTINGS_FILE not found: $SETTINGS_FILE (explicitly set; refusing to fall back to the example settings)"
    SETTINGS_FILE="$SETTINGS_EXAMPLE"
  fi
  export QUEUE_DRY_RUN="$DRY_RUN"
  export REPO_DIR GREENLIGHT_DIR SETTINGS_FILE BASE_BRANCH
}

# ---------------------------------------------------------------- state
is_done() { [[ -f "$DONE_FILE" ]] && grep -qxF "$1" "$DONE_FILE"; }
# last line of the task in prs.txt: "PR PHASE SHA [ANNOTATIONS]" (empty if none). Lines written by
# older versions have 4 columns; the 5th (e.g. "deferred=2") is optional.
recorded_pr() { [[ -f "$PRS_FILE" ]] && awk -F'\t' -v t="$1" '$1==t {l=$2" "$3" "$4" "$5} END {print l}' "$PRS_FILE" || true; }
record_pr() { # record_pr <task> <pr> <phase> [sha] [annotations]
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" >>"$PRS_FILE"
  log "state: $1 → PR #$2 phase=$3${4:+ sha=${4:0:8}}${5:+ $5}"
}
# save what an agent left uncommitted, for the human, before the runner dies (never cleans)
save_leftover() { # save_leftover <file>
  { echo "# git status --porcelain"; rgit status --porcelain; echo; echo "# git diff (unstaged)"; rgit diff
    echo; echo "# git diff --cached"; rgit diff --cached
    echo; echo "# untracked files"; rgit ls-files --others --exclude-standard; } >"$1" 2>&1 || true
}

# ---------------------------------------------------------------- queue
read_queue() { # fills PENDING[] with valid, not-yet-done, de-duplicated task-ids
  [[ -f "$QUEUE_FILE" ]] || die "queue file not found: $QUEUE_FILE"
  local raw id seen='|'
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    id="${raw%%#*}"                       # strip comment
    id="${id#"${id%%[![:space:]]*}"}"     # ltrim
    id="${id%"${id##*[![:space:]]}"}"     # rtrim
    [[ -z "$id" ]] && continue
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid task-id in queue: '$id' (allowed: letters, digits, . _ -)"
    if [[ "$seen" == *"|$id|"* ]]; then warn "duplicate task in queue ignored: $id"; continue; fi
    seen="$seen$id|"
    if is_done "$id"; then log "already done (state/done.txt): $id — skipping"; continue; fi
    PENDING+=("$id")
  done <"$QUEUE_FILE"
  TASK_TOTAL=${#PENDING[@]}
}

# ---------------------------------------------------------------- preflight (once, at boot)
# Stale or concurrent runner. The pidfile is removed by the exit trap, so one left behind means
# either a runner is still alive (two queues on the same REPO_DIR would checkout under each other's
# session — refuse) or the previous run died without its trap (SIGKILL, OOM, reboot — report where it
# was, using the heartbeat, and resume from state/prs.txt). Liveness = kill -0 (process exists), not ps.
pidfile_check() {
  [[ "$DRY_RUN" != "1" && -f "$STATE_DIR/runner.pid" ]] || return 0
  local old_pid last=""
  old_pid="$(tr -d '[:space:]' <"$STATE_DIR/runner.pid" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "another runner is alive (pid $old_pid, state/runner.pid) — stop it with: kill -TERM $old_pid"
  fi
  [[ -f "$STATE_DIR/heartbeat" ]] && last="$(head -1 "$STATE_DIR/heartbeat" 2>/dev/null || true)"
  log "stale runner.pid (pid ${old_pid:-?} is not running): the previous run ended without its exit trap (hard signal, OOM or reboot)${last:+ — last seen alive at ${last%% *} in ${last#* }}; state/prs.txt is authoritative — resuming from it"
  rm -f "$STATE_DIR/runner.pid"
}

preflight() {
  CUR_STEP="preflight"
  mkdir -p "$STATE_DIR" "$LOGS_DIR"   # before anything logs: log() appends to $RUNNER_LOG outside dry-run
  local missing=() t
  pidfile_check
  [[ -d "$REPO_DIR/.git" ]] || die "REPO_DIR is not a git repository: $REPO_DIR"
  [[ "$(rgit rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || die "REPO_DIR has no working tree: $REPO_DIR"
  [[ -f "$SETTINGS_FILE" ]] || die "headless settings file missing: $SETTINGS_FILE"
  jq -e . "$SETTINGS_FILE" >/dev/null 2>&1 || die "headless settings file is not valid JSON: $SETTINGS_FILE"
  for t in git jq perl "$CLAUDE_BIN" "$GH_BIN"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] || die "tools missing from PATH: ${missing[*]}"

  # prompts for ALL pending tasks — fail early naming the missing ones
  missing=()
  for t in ${PENDING[@]+"${PENDING[@]}"}; do [[ -f "$PROMPTS_DIR/$t.md" ]] || missing+=("$PROMPTS_DIR/$t.md"); done
  [[ ${#missing[@]} -eq 0 ]] || die "prompt(s) missing for pending task(s): ${missing[*]}"

  # clean working tree (untracked included): dirt = abort, never stash/clean
  local dirty
  dirty="$(rgit status --porcelain)"
  [[ -z "$dirty" ]] || die "dirty working tree in $REPO_DIR (git status --porcelain):"$'\n'"$dirty"

  checks_load
  orca_probe

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would run: gh auth status"
  else
    "$GH_BIN" auth status >/dev/null 2>&1 || die "gh not authenticated (command: gh auth status)"
  fi
  if [[ "$DRY_RUN" != "1" ]]; then echo $$ >"$STATE_DIR/runner.pid"; PIDFILE_OWNED=1; fi   # stop: kill -TERM $(cat state/runner.pid); pidfile_check ran first
  log "preflight ok — repo=$REPO_DIR base=$BASE_BRANCH queue=$QUEUE_FILE pending=$TASK_TOTAL poll=${POLL_INTERVAL}s timeout=${TASK_TIMEOUT_S}s checks=$CHECKS_MODE babysit=$( [[ -n "$BABYSIT_COMMAND" && "$SKIP_BABYSIT" != "1" ]] && echo on || echo off )"
}

# ---------------------------------------------------------------- step: clean base
step_clean_base() {
  CUR_STEP="clean-base"
  local dirty
  dirty="$(rgit status --porcelain)"
  [[ -z "$dirty" ]] || die "dirty working tree before clean base (never stash/clean):"$'\n'"$dirty"
  rgit checkout -q "$BASE_BRANCH" || die "command failed: git -C $REPO_DIR checkout $BASE_BRANCH"
  rgit pull -q --ff-only || die "command failed: git -C $REPO_DIR pull --ff-only (diverged? resolve by hand)"
  log "clean base: $BASE_BRANCH @ $(rgit rev-parse --short HEAD)"
  step_sync_env
}

# ---------------------------------------------------------------- step: environment coherent with the base
# A "clean base" that is only git-clean is not enough: a session that starts from stale dependencies
# or stale generated code burns turns discovering that the test suite does not compile. SYNC_COMMAND
# (e.g. a frozen-lockfile install + codegen) must not touch versioned files — the tree is checked again.
step_sync_env() {
  CUR_STEP="sync-env"
  local log_f="$LOGS_DIR/env-sync.log"
  [[ -n "$SYNC_COMMAND" ]] || { log "sync-env: SYNC_COMMAND empty — skipped"; return 0; }
  if [[ "$DRY_RUN" == "1" ]]; then log "[dry-run] would run in $REPO_DIR: $SYNC_COMMAND"; return 0; fi
  (cd "$REPO_DIR" && bash -c "$SYNC_COMMAND") >>"$log_f" 2>&1 \
    || die "SYNC_COMMAND failed (see logs/env-sync.log): $SYNC_COMMAND"
  local dirty; dirty="$(rgit status --porcelain)"
  [[ -z "$dirty" ]] || die "SYNC_COMMAND dirtied the working tree (touched a versioned file?):"$'\n'"$dirty"
  log "environment synced: $SYNC_COMMAND"
}

# ---------------------------------------------------------------- step: headless task session
step_run_task() {
  CUR_STEP="claude-task"
  local prompt="$PROMPTS_DIR/$CUR_TASK.md" out="$LOGS_DIR/$CUR_TASK.json" err="$LOGS_DIR/$CUR_TASK.err" rc=0
  TASK_START_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  log "claude -p headless (timeout ${TASK_TIMEOUT_S}s, cwd=$REPO_DIR) → logs/$CUR_TASK.json"
  # prompt via stdin (no argv limit/quoting); perl's alarm is inherited by exec (macOS has no `timeout`)
  # shellcheck disable=SC2086
  (cd "$REPO_DIR" && perl -e 'alarm shift; exec @ARGV' "$TASK_TIMEOUT_S" \
      "$CLAUDE_BIN" -p --settings "$SETTINGS_FILE" --permission-mode "$CLAUDE_PERMISSION_MODE" --output-format json $CLAUDE_EXTRA_ARGS \
      <"$prompt") >"$out" 2>"$err" || rc=$?
  if [[ $rc -eq 142 ]]; then die "task session exceeded TASK_TIMEOUT_S=${TASK_TIMEOUT_S}s (SIGALRM); partial log in logs/$CUR_TASK.json"; fi
  [[ $rc -eq 0 ]] || die "claude -p exited with $rc; stderr in logs/$CUR_TASK.err"
  jq -e . "$out" >/dev/null 2>&1 || die "claude -p output is not JSON (logs/$CUR_TASK.json)"
  local subtype is_err
  subtype="$(jq -r '.subtype // "?"' "$out")"; is_err="$(jq -r '.is_error // false' "$out")"
  log "session ended: subtype=$subtype is_error=$is_err turns=$(jq -r '.num_turns // "?"' "$out") duration_ms=$(jq -r '.duration_ms // "?"' "$out") cost_usd=$(jq -r '.total_cost_usd // "?"' "$out") denials=$(jq -r '(.permission_denials // []) | length' "$out")"
  [[ "$is_err" == "false" && "$subtype" == "success" ]] || die "task session did not succeed (subtype=$subtype is_error=$is_err); see logs/$CUR_TASK.json"
  local dirty
  dirty="$(rgit status --porcelain)"
  [[ -z "$dirty" ]] || die "session left the working tree dirty (uncommitted); never cleaned automatically:"$'\n'"$dirty"
}

# ---------------------------------------------------------------- step: detect the PR
step_detect_pr() {
  CUR_STEP="detect-pr"
  local out="$LOGS_DIR/$CUR_TASK.json" pr="" lower
  # a) PR_NUMBER=<n> marker — last occurrence in the result text
  pr="$(jq -r '.result // ""' "$out" | grep -oE 'PR_NUMBER=[0-9]+' | tail -1 | cut -d= -f2 || true)"
  if [[ -n "$pr" ]]; then
    log "PR detected by marker: #$pr"
  else
    # b) fallback: open PR by me, head contains the task-id (lowercase) AND created after the task started
    lower="$(tr '[:upper:]' '[:lower:]' <<<"$CUR_TASK")"
    local cands
    # gh's --jq accepts no --arg flags; pipe the JSON into real jq instead
    cands="$(rgh pr list --author '@me' --state open --limit 50 --json number,headRefName,createdAt \
      | jq -r --arg t "$lower" --arg s "$TASK_START_TS" '[.[] | select((.headRefName|ascii_downcase|contains($t)) and .createdAt > $s)] | map(.number) | join(" ")')"
    case "$(wc -w <<<"$cands" | tr -d ' ')" in
      1) pr="$(tr -d ' ' <<<"$cands")"; log "PR detected by fallback (gh pr list): #$pr" ;;
      0) die "no PR detected: no PR_NUMBER= marker in the result and no open PR with head containing '$lower' created after $TASK_START_TS" ;;
      *) die "ambiguous fallback: more than one candidate PR (${cands}); refusing to guess" ;;
    esac
  fi
  # the PR exists, is open and is not the base branch
  local meta
  meta="$(rgh pr view "$pr" --json state,headRefName,baseRefName --jq '"\(.state) \(.headRefName) \(.baseRefName)"' 2>/dev/null)" \
    || die "gh pr view $pr failed — does the PR from the marker exist in this repo?"
  set -- $meta
  [[ "$1" == "OPEN" ]] || die "PR #$pr is not OPEN (state: $1)"
  [[ "$2" != "$BASE_BRANCH" ]] || die "PR #$pr has head=$BASE_BRANCH — session violated 'never commit on the base branch'"
  CUR_PR="$pr"
  log "PR #$pr: head=$2 base=$3"
  record_pr "$CUR_TASK" "$pr" opened
  orca_comment "[$TASK_IDX/$TASK_TOTAL] $CUR_TASK: PR #$pr opened, waiting for CI"
}

# ---------------------------------------------------------------- CI gate (SINGLE function)
# Evidence is bound to the SHA: the head is pinned on entry; final validation reads the check-runs
# OF THAT sha via the API (not the PR rollup) and the gate fails if the head moves midway.
# 1) wait for the sha's check-runs to EXIST (right after push/pr create the list is empty);
# 2) gh pr checks --watch --fail-fast (red = abort the queue);
# 3) settle: re-read the sha's check-runs while a late one (workflow_run-chained on CI completion)
#    is still running, bounded; the head must not move meanwhile;
# 4) validate by NAME (required checks present and success; a non-required check-run still running
#    after the settle window is ignored with a warn) or by COUNT (>= MIN_CHECKS, no failure, nothing running).
# Exports GATED_SHA.
pr_head_oid() { rgh pr view "$1" --json headRefOid --jq '.headRefOid'; }
repo_slug() { rgh repo view --json nameWithOwner --jq '.nameWithOwner'; }
sha_check_runs() { # sha_check_runs <sha> → JSON [{name,status,conclusion}]
  rgh api "repos/$(repo_slug)/commits/$1/check-runs?per_page=100" \
    --jq '[.check_runs[] | {name, status, conclusion}]' 2>/dev/null || echo '[]'
}
ci_gate() { # ci_gate <pr>
  local pr="$1" tries=0 json n sha
  sha="$(pr_head_oid "$pr")"
  [[ -n "$sha" ]] || die "could not read headRefOid of PR #$pr"
  while :; do
    json="$(sha_check_runs "$sha")"
    n="$(jq 'length' <<<"$json")"
    [[ "$n" -gt 0 ]] && break
    tries=$((tries + 1))
    [[ $tries -le $CHECKS_APPEAR_TRIES ]] || die "no check-run appeared for ${sha:0:8} (PR #$pr) after $((CHECKS_APPEAR_TRIES * CHECKS_APPEAR_SLEEP_S))s"
    log "PR #$pr @ ${sha:0:8} has no check-runs yet ($tries/$CHECKS_APPEAR_TRIES) — waiting ${CHECKS_APPEAR_SLEEP_S}s"
    sleep "$CHECKS_APPEAR_SLEEP_S"
  done
  log "PR #$pr @ ${sha:0:8}: $n check-runs present — gh pr checks --watch --fail-fast"
  if ! rgh pr checks "$pr" --watch --fail-fast >>"$LOGS_DIR/$CUR_TASK-checks.log" 2>&1; then
    die "CI red on PR #$pr (gh pr checks $pr --watch --fail-fast); human intervention — see logs/$CUR_TASK-checks.log"
  fi
  checks_settle "$sha" "$pr"   # re-reads the head too: moved → die
  checks_verify "$CHECKS_SETTLED_JSON" "$sha" "$pr"
  GATED_SHA="$sha"
}

step_ci_gate() {
  CUR_STEP="ci-gate"
  ci_gate "$CUR_PR"
  record_pr "$CUR_TASK" "$CUR_PR" gated "$GATED_SHA"
}

# ---------------------------------------------------------------- step: babysit (once)
# BABYSIT_COMMAND runs in $REPO_DIR with PR_NUMBER, TASK_ID, REPO_DIR, BASE_BRANCH, SETTINGS_FILE and
# GREENLIGHT_DIR exported. It may push to the PR branch; it must leave the tree clean. If stdout is
# JSON with is_error=true the step fails.
step_babysit() {
  CUR_STEP="babysit"
  local out="$LOGS_DIR/$CUR_TASK-babysit.out" err="$LOGS_DIR/$CUR_TASK-babysit.err" rc=0 before after
  if [[ "$BABYSIT_DELAY_S" -gt 0 ]]; then
    log "BABYSIT_DELAY_S=$BABYSIT_DELAY_S: waiting before the babysit so late review comments land first"
    sleep "$BABYSIT_DELAY_S"
  fi
  before="$(pr_head_oid "$CUR_PR")"
  orca_comment "[$TASK_IDX/$TASK_TOTAL] $CUR_TASK: babysit on PR #$CUR_PR"
  log "babysit once (timeout ${BABYSIT_TIMEOUT_S}s) head=${before:0:8} → logs/$CUR_TASK-babysit.out"
  (cd "$REPO_DIR" && PR_NUMBER="$CUR_PR" TASK_ID="$CUR_TASK" \
      perl -e 'alarm shift; exec @ARGV' "$BABYSIT_TIMEOUT_S" bash -c "$BABYSIT_COMMAND") \
      >"$out" 2>"$err" || rc=$?
  if [[ $rc -eq 142 ]]; then die "babysit exceeded BABYSIT_TIMEOUT_S=${BABYSIT_TIMEOUT_S}s (SIGALRM); partial log in logs/$CUR_TASK-babysit.out"; fi
  [[ $rc -eq 0 ]] || die "BABYSIT_COMMAND exited with $rc; stderr in logs/$CUR_TASK-babysit.err"
  if jq -e . "$out" >/dev/null 2>&1; then
    log "babysit ended: subtype=$(jq -r '.subtype // "?"' "$out") is_error=$(jq -r '.is_error // false' "$out") turns=$(jq -r '.num_turns // "?"' "$out") cost_usd=$(jq -r '.total_cost_usd // "?"' "$out") denials=$(jq -r '(.permission_denials // []) | length' "$out")"
    [[ "$(jq -r '.is_error // false' "$out")" == "false" ]] || die "babysit ended with is_error=true; see logs/$CUR_TASK-babysit.out"
  else
    log "babysit ended: exit 0 (output is not JSON; see logs/$CUR_TASK-babysit.out)"
  fi
  # DEFERRED_FINDINGS=<n> marker (last occurrence anywhere in stdout, JSON or plain): review findings the
  # babysit deferred to the author. Informational — it changes the handover message, never the flow.
  DEFERRED_N="$(grep -oE 'DEFERRED_FINDINGS=[0-9]+' "$out" | tail -1 | cut -d= -f2 || true)"
  DEFERRED_N="${DEFERRED_N:-0}"
  if [[ "$DEFERRED_N" -gt 0 ]]; then
    warn "babysit deferred $DEFERRED_N finding(s) to the author on PR #$CUR_PR — read the threads before merging"
  else
    log "babysit reported no deferred findings (DEFERRED_FINDINGS marker: $(grep -c 'DEFERRED_FINDINGS=' "$out" || true) occurrence(s))"
  fi

  # the babysit may have checked out the PR branch: require a clean tree and RETURN to the base branch.
  # Contract: it commits+pushes or reverts; a dirty tree is a violation. The runner NEVER cleans — it saves
  # the leftover for the human and dies.
  local dirty
  dirty="$(rgit status --porcelain)"
  if [[ -n "$dirty" ]]; then
    save_leftover "$LOGS_DIR/$CUR_TASK-babysit-leftover.diff"
    orca_comment "FAILED at $CUR_TASK in step $CUR_STEP: babysit violated the clean-tree contract on PR #$CUR_PR (leftover saved in logs/$CUR_TASK-babysit-leftover.diff)"
    die "babysit violated the clean-tree contract (uncommitted changes; never cleaned automatically). Leftover saved in logs/$CUR_TASK-babysit-leftover.diff. git status --porcelain:"$'\n'"$dirty"
  fi
  rgit checkout -q "$BASE_BRANCH" || die "command failed: git -C $REPO_DIR checkout $BASE_BRANCH (after babysit)"

  # the babysit RAN (once): record BEFORE the re-gate so a rerun never repeats it
  record_pr "$CUR_TASK" "$CUR_PR" babysat "$GATED_SHA" "deferred=$DEFERRED_N"
  after="$(pr_head_oid "$CUR_PR")"
  if [[ "$after" != "$before" ]]; then
    log "push detected by babysit: head ${before:0:8} → ${after:0:8} — re-running the full CI gate"
    orca_comment "[$TASK_IDX/$TASK_TOTAL] $CUR_TASK: babysit pushed to PR #$CUR_PR, waiting for CI again"
    CUR_STEP="ci-gate-post-babysit"
    ci_gate "$CUR_PR"
    record_pr "$CUR_TASK" "$CUR_PR" babysat "$GATED_SHA" "deferred=$DEFERRED_N"
  else
    log "babysit made no push (head unchanged ${after:0:8})"
  fi
}

step_skip_babysit() {
  CUR_STEP="babysit"
  if [[ -z "$BABYSIT_COMMAND" ]]; then
    log "babysit SKIPPED: BABYSIT_COMMAND is empty — recording phase babysat without execution"
  else
    log "babysit SKIPPED by --skip-babysit — recording phase babysat without execution (operator decision)"
  fi
  record_pr "$CUR_TASK" "$CUR_PR" babysat "$GATED_SHA"
}

# Before handover: the current head must be the gated sha. A rerun after an interrupted re-gate
# (or a human push in between) redoes ONLY the gate — never the babysit.
ensure_head_gated() {
  local head; head="$(pr_head_oid "$CUR_PR")"
  if [[ -z "$GATED_SHA" || "$head" != "$GATED_SHA" ]]; then
    CUR_STEP="ci-gate-new-head"
    log "head ${head:0:8} ≠ gated sha ${GATED_SHA:0:8} — redoing only the CI gate"
    ci_gate "$CUR_PR"
    record_pr "$CUR_TASK" "$CUR_PR" babysat "$GATED_SHA" "deferred=$DEFERRED_N"
  fi
}

# ---------------------------------------------------------------- step: handover + wait for the MANUAL MERGE
step_wait_merge() {
  CUR_STEP="waiting-merge"
  local pr="$CUR_PR" polls=0 fails=0 st started now mins errline
  started="$(date +%s)"
  orca_status in-review
  if [[ "$DEFERRED_N" -gt 0 ]]; then
    orca_comment "[$TASK_IDX/$TASK_TOTAL] PR #$pr ($CUR_TASK): ready, with $DEFERRED_N deferred finding(s) awaiting your judgment"
    warn "handover: PR #$pr ($CUR_TASK) ready, with $DEFERRED_N deferred finding(s) awaiting your judgment — read the review threads before merging"
  else
    orca_comment "[$TASK_IDX/$TASK_TOTAL] PR #$pr ($CUR_TASK) ready for your review/merge"
  fi
  log "handover: PR #$pr waiting for MANUAL MERGE (poll ${POLL_INTERVAL}s, heartbeat every $HEARTBEAT_EVERY_POLLS polls)"
  while :; do
    # gh and sleep OUTSIDE the reach of set -e: a transient failure counts, it does not abort
    st="$(rgh pr view "$pr" --json state --jq '.state' 2>"$LOGS_DIR/.poll-err" || true)"
    if [[ -z "$st" ]]; then
      fails=$((fails + 1))
      errline="$(head -1 "$LOGS_DIR/.poll-err" 2>/dev/null || true)"
      if [[ $fails -ge $POLL_FAILS_ABORT ]]; then
        orca_comment "FAILED at $CUR_TASK in step $CUR_STEP: gh pr view $pr failed ${fails}x in a row (${errline:-no stderr})"
        die "gh pr view $pr failed $fails times in a row (>= POLL_FAILS_ABORT=$POLL_FAILS_ABORT): ${errline:-no stderr}"
      elif [[ $fails -ge $POLL_FAILS_WARN ]]; then
        warn "gh pr view $pr failed ${fails}x in a row (aborts after ${POLL_FAILS_ABORT}): ${errline:-no stderr}"
      else
        log "gh pr view $pr failed (${fails}/${POLL_FAILS_ABORT}) — transient? ${errline:-no stderr}"
      fi
      sleep "$POLL_INTERVAL" || true
      continue
    fi
    [[ $fails -gt 0 ]] && log "gh pr view responding again after $fails failure(s)"
    fails=0
    case "$st" in
      MERGED) log "PR #$pr MERGED"; break ;;
      CLOSED) orca_comment "FAILED at $CUR_TASK in step $CUR_STEP: PR #$pr closed WITHOUT merge"
              die "PR #$pr was CLOSED without merge — human decision to stop the queue" ;;
      OPEN) ;;
      *) warn "unexpected state for PR #$pr: '$st' — treating as transient" ;;
    esac
    polls=$((polls + 1))
    if (( polls % HEARTBEAT_EVERY_POLLS == 0 )); then
      now="$(date +%s)"; mins=$(( (now - started) / 60 ))
      log "heartbeat: waiting for merge of PR #$pr for ~${mins}min ($polls polls)"
      orca_comment "[$TASK_IDX/$TASK_TOTAL] waiting for merge of PR #$pr ($CUR_TASK) for ~${mins}min"
    fi
    sleep "$POLL_INTERVAL" || true
  done
}

# ---------------------------------------------------------------- step: post-merge → done
# The next task MUST start from the base branch WITH the merge (merge-before-next invariant).
step_persist_done() {
  CUR_STEP="post-merge"
  local pr="$CUR_PR" mc head dirty
  mc="$(rgh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // ""')"
  [[ -n "$mc" ]] || die "PR #$pr has no mergeCommit on GitHub (gh pr view $pr --json mergeCommit)"
  dirty="$(rgit status --porcelain)"
  [[ -z "$dirty" ]] || die "dirty working tree before the post-merge pull:"$'\n'"$dirty"
  rgit checkout -q "$BASE_BRANCH" || die "command failed: git -C $REPO_DIR checkout $BASE_BRANCH (post-merge)"
  rgit pull -q --ff-only || die "command failed: git -C $REPO_DIR pull --ff-only (post-merge)"
  head="$(rgit rev-parse HEAD)"
  rgit merge-base --is-ancestor "$mc" HEAD \
    || die "merge commit ${mc:0:8} of PR #$pr is NOT in local $BASE_BRANCH (HEAD ${head:0:8}) — diverged? not marking done"
  log "merge validated: ${mc:0:8} ⊂ $BASE_BRANCH@${head:0:8}"
  record_pr "$CUR_TASK" "$pr" merged "$mc"
  echo "$CUR_TASK" >>"$DONE_FILE"
  MERGED_PRS+=("$pr")
  orca_status in-progress
  orca_comment "[$TASK_IDX/$TASK_TOTAL] PR #$pr merged, moving on"
  log "done: $CUR_TASK (PR #$pr) recorded in state/done.txt"
}

# ---------------------------------------------------------------- dry-run
dry_run_task() {
  local k="$TASK_IDX" n="$TASK_TOTAL" t="$CUR_TASK" rec baby
  rec="$(recorded_pr "$t")"
  if [[ "$SKIP_BABYSIT" == "1" ]]; then baby="SKIPPED (--skip-babysit) → phase babysat recorded without execution"
  elif [[ -z "$BABYSIT_COMMAND" ]]; then baby="SKIPPED (BABYSIT_COMMAND empty) → phase babysat recorded without execution"
  else baby="$( [[ "$BABYSIT_DELAY_S" -gt 0 ]] && echo "sleep $BABYSIT_DELAY_S; " || true )BABYSIT_COMMAND in $REPO_DIR (once, PR_NUMBER=<PR>) > logs/$t-babysit.out; DEFERRED_FINDINGS=<n> marker → annotation; clean tree required (leftover → logs/$t-babysit-leftover.diff); git checkout $BASE_BRANCH; if headRefOid moved → repeat 5"; fi
  cat <<EOF
--- [$k/$n] $t
  prompt : $PROMPTS_DIR/$t.md ($(wc -c <"$PROMPTS_DIR/$t.md" | tr -d ' ') bytes)
  state  : ${rec:-no PR recorded (runs the task)}$( [[ -n "$rec" ]] && echo "  → resumes from the recorded phase, without re-running the task" )
  1 base : git -C $REPO_DIR checkout $BASE_BRANCH && git -C $REPO_DIR pull --ff-only$( [[ -n "$SYNC_COMMAND" ]] && echo " && $SYNC_COMMAND" || echo "  (SYNC_COMMAND empty: no env sync)" )
  2 orca : status in-progress · comment "[$k/$n] running $t"
  3 task : perl -e 'alarm $TASK_TIMEOUT_S; exec @ARGV' $CLAUDE_BIN -p --settings $SETTINGS_FILE \\
             --permission-mode $CLAUDE_PERMISSION_MODE --output-format json${CLAUDE_EXTRA_ARGS:+ $CLAUDE_EXTRA_ARGS} < prompts/$t.md  (cwd=$REPO_DIR) > logs/$t.json
  4 pr   : PR_NUMBER=<n> from the last occurrence in .result; fallback gh pr list --author @me (head contains '$(tr '[:upper:]' '[:lower:]' <<<"$t")' and createdAt > start) → phase opened
  5 ci   : check-runs of the head sha (API) + gh pr checks --watch --fail-fast + settle ≤ $((CHECKS_SETTLE_TRIES * CHECKS_SETTLE_SLEEP_S))s for late check-runs; require: $(checks_describe) → phase gated
           orca comment "[$k/$n] $t: PR #<PR> opened, waiting for CI"
  6 baby : $baby → phase babysat
  7 hand : orca status in-review · comment "[$k/$n] PR #<PR> ($t) ready for your review/merge" (or "... ready, with <n> deferred finding(s) awaiting your judgment")
  8 wait : gh pr view <PR> --json state every ${POLL_INTERVAL}s; MERGED → continue; CLOSED → abort; heartbeat every $HEARTBEAT_EVERY_POLLS polls; gh failures: warn after ${POLL_FAILS_WARN} in a row, abort after ${POLL_FAILS_ABORT}
  9 done : mergeCommit ⊂ local $BASE_BRANCH (checkout+pull --ff-only) → phase merged · state/done.txt · orca status in-progress · comment "[$k/$n] PR #<PR> merged, moving on"
EOF
}

# ---------------------------------------------------------------- one task (phase machine)
run_task() {
  CUR_TASK="$1"; CUR_PR=""; GATED_SHA=""; DEFERRED_N=0
  if [[ "$DRY_RUN" == "1" ]]; then dry_run_task; return 0; fi
  step_clean_base
  orca_status in-progress
  local rec phase st rank
  rec="$(recorded_pr "$CUR_TASK")"
  if [[ -n "$rec" ]]; then
    set -- $rec; CUR_PR="$1"; phase="${2:-opened}"; GATED_SHA="${3:-}"
    case "${4:-}" in deferred=*) DEFERRED_N="${4#deferred=}"; [[ "$DEFERRED_N" =~ ^[0-9]+$ ]] || DEFERRED_N=0 ;; esac
    CUR_STEP="resume"
    st="$(rgh pr view "$CUR_PR" --json state --jq '.state' 2>/dev/null || echo "?")"
    case "$st" in
      OPEN)   log "resuming: PR #$CUR_PR recorded (phase=$phase, state OPEN) — not re-running the task"
              orca_comment "[$TASK_IDX/$TASK_TOTAL] resuming $CUR_TASK on PR #$CUR_PR (phase $phase)" ;;
      MERGED) log "resuming: PR #$CUR_PR already MERGED (recorded phase=$phase) — validating merge and persisting"
              step_persist_done; return 0 ;;
      *)      die "PR #$CUR_PR recorded for $CUR_TASK is '$st' — human decision: remove the $CUR_TASK lines from state/prs.txt to re-run (new PR), or drop the task from the queue" ;;
    esac
  else
    orca_comment "[$TASK_IDX/$TASK_TOTAL] running $CUR_TASK"
    step_run_task
    step_detect_pr
    phase="opened"
  fi
  # phase machine (bash 3.2: no `;;&`) — each phase only runs if not yet reached
  case "$phase" in opened) rank=0 ;; gated) rank=1 ;; babysat) rank=2 ;; merged) rank=3 ;;
    *) die "unknown phase in state/prs.txt for $CUR_TASK: '$phase'" ;; esac
  if [[ $rank -le 0 ]]; then step_ci_gate; fi
  if [[ $rank -le 1 ]]; then
    if [[ "$SKIP_BABYSIT" == "1" || -z "$BABYSIT_COMMAND" ]]; then step_skip_babysit; else step_babysit; fi
  fi
  if [[ $rank -le 2 ]]; then ensure_head_gated; step_wait_merge; fi
  step_persist_done
}

# ---------------------------------------------------------------- main
main() {
  parse_args "$@"
  read_queue
  preflight
  CUR_STEP="queue"
  if [[ $TASK_TOTAL -eq 0 ]]; then
    log "nothing pending in the queue — exiting"
    orca_status completed
    orca_comment "queue finished: 0 pending tasks"
    FINISHED=1
    return 0
  fi
  orca_status in-progress
  orca_comment "queue started: $TASK_TOTAL pending tasks"
  local t
  for t in ${PENDING[@]+"${PENDING[@]}"}; do
    TASK_IDX=$((TASK_IDX + 1))
    run_task "$t"
  done
  CUR_TASK="-"; CUR_STEP="end"
  local prs="-"
  [[ ${#MERGED_PRS[@]} -gt 0 ]] && prs="$(printf '#%s ' "${MERGED_PRS[@]}")"
  log "queue finished: $TASK_TOTAL tasks, PRs $prs"
  orca_status completed
  orca_comment "queue finished: $TASK_TOTAL tasks, PRs $prs"
  FINISHED=1
}

main "$@"
