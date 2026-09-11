#!/usr/bin/env bash
# lib/checks.sh — which CI checks a PR must pass before it is handed to a human.
# Sourceable. Expects `log`, `warn`, `die` and `orca_comment` from the caller.
#
# CHECKS_MODE:
#   count (default)  at least MIN_CHECKS check-runs with conclusion=success, none failed.
#                    Weak (a renamed/removed job still "passes"), so it warns on every gate.
#   names            required names come from a file inside the target repo:
#                    CHECKS_SOURCE     path relative to $REPO_DIR
#                    CHECKS_JQ_FILTER  jq program applied with `jq -rRs` (the file is one raw
#                                      string; use `fromjson` for JSON sources). Must emit one
#                                      check name per line.
#   list             required names come from REQUIRED_CHECKS="a,b,c".
#
# Result: REQUIRED_CHECK_NAMES[] (empty in count mode). A required check that is missing on the
# gated sha is a failure ("green by absence" is not green).

if [[ -n "${_CHECKS_LIB_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_CHECKS_LIB_LOADED=1

CHECKS_MODE="${CHECKS_MODE:-count}"
MIN_CHECKS="${MIN_CHECKS:-1}"
CHECKS_SOURCE="${CHECKS_SOURCE:-}"
# default filter: a line like `REQUIRED_CHECKS: "build, lint, e2e"` anywhere in the file
if [[ -z "${CHECKS_JQ_FILTER:-}" ]]; then
  CHECKS_JQ_FILTER='capture("REQUIRED_CHECKS:[[:space:]]*\"(?<v>[^\"]*)\"").v | split(",")[] | gsub("^[[:space:]]+|[[:space:]]+$"; "")'
fi
REQUIRED_CHECKS="${REQUIRED_CHECKS:-}"
# after `gh pr checks --watch` returns, check-runs chained on CI completion (workflow_run) may still
# be starting on the sha: re-read while any is running, at most CHECKS_SETTLE_TRIES × CHECKS_SETTLE_SLEEP_S
CHECKS_SETTLE_TRIES="${CHECKS_SETTLE_TRIES:-6}"
CHECKS_SETTLE_SLEEP_S="${CHECKS_SETTLE_SLEEP_S:-10}"
declare -a REQUIRED_CHECK_NAMES=()

_checks_add_csv() { # _checks_add_csv "<a, b, c>" → appends trimmed non-empty names
  local c
  while IFS= read -r c; do
    c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
    [[ -n "$c" ]] && REQUIRED_CHECK_NAMES+=("$c")
  done < <(tr ',' '\n' <<<"$1")
}

checks_load() { # resolve REQUIRED_CHECK_NAMES[] according to CHECKS_MODE (runtime, never from memory)
  REQUIRED_CHECK_NAMES=()
  case "$CHECKS_MODE" in
    count)
      [[ "$MIN_CHECKS" =~ ^[0-9]+$ ]] || die "MIN_CHECKS must be an integer (got: $MIN_CHECKS)"
      warn "CHECKS_MODE=count: CI gate is a minimum COUNT of $MIN_CHECKS successful check-runs, with no validation by name (set CHECKS_MODE=names or list to gate by name)"
      ;;
    names)
      [[ -n "$CHECKS_SOURCE" ]] || die "CHECKS_MODE=names requires CHECKS_SOURCE (path relative to REPO_DIR)"
      local src="$REPO_DIR/$CHECKS_SOURCE" line
      [[ -f "$src" ]] || die "CHECKS_SOURCE not found in the target repo: $src"
      while IFS= read -r line; do
        [[ -n "$line" ]] && _checks_add_csv "$line"
      done < <(jq -rRs "$CHECKS_JQ_FILTER" "$src" 2>/dev/null || true)
      [[ ${#REQUIRED_CHECK_NAMES[@]} -gt 0 ]] || die "CHECKS_MODE=names: CHECKS_JQ_FILTER produced no check names from $CHECKS_SOURCE (filter: $CHECKS_JQ_FILTER)"
      log "required checks from $CHECKS_SOURCE (${#REQUIRED_CHECK_NAMES[@]}): $(IFS='|'; echo "${REQUIRED_CHECK_NAMES[*]}")"
      ;;
    list)
      _checks_add_csv "$REQUIRED_CHECKS"
      [[ ${#REQUIRED_CHECK_NAMES[@]} -gt 0 ]] || die "CHECKS_MODE=list requires REQUIRED_CHECKS=\"a,b,c\""
      log "required checks from REQUIRED_CHECKS (${#REQUIRED_CHECK_NAMES[@]}): $(IFS='|'; echo "${REQUIRED_CHECK_NAMES[*]}")"
      ;;
    *) die "unknown CHECKS_MODE: '$CHECKS_MODE' (count|names|list)" ;;
  esac
}

checks_describe() { # one-line summary for dry-run output
  case "$CHECKS_MODE" in
    count) echo ">= $MIN_CHECKS successful check-runs (CHECKS_MODE=count, with warn + comment)" ;;
    *) echo "${#REQUIRED_CHECK_NAMES[@]} named checks success ($(IFS='|'; echo "${REQUIRED_CHECK_NAMES[*]+${REQUIRED_CHECK_NAMES[*]}}"))" ;;   # bash 3.2 + set -u: guard the empty array
  esac
}

checks_pending() { # checks_pending <check-runs json> → "a, b" of check-runs with status != completed ("" = none)
  jq -r '[.[] | select(.status!="completed") | .name] | join(", ")' <<<"$1"
}

_checks_is_required() { # _checks_is_required <name> → 0 if the name is in REQUIRED_CHECK_NAMES
  local c
  for c in ${REQUIRED_CHECK_NAMES[@]+"${REQUIRED_CHECK_NAMES[@]}"}; do [[ "$c" == "$1" ]] && return 0; done
  return 1
}

# checks_settle <sha> <pr> — re-reads the sha's check-runs while any is still running (bounded), dying
# if the head moves meanwhile. Needs `sha_check_runs <sha>` and `pr_head_oid <pr>` from the caller.
# Leaves the last JSON read in CHECKS_SETTLED_JSON (not printed: log lines would land in a `$( )`);
# the caller passes it to checks_verify, which applies the policy for check-runs still running after
# the window.
CHECKS_SETTLED_JSON='[]'
checks_settle() {
  local sha="$1" pr="$2" tries=0 json pending sha2
  while :; do
    sha2="$(pr_head_oid "$pr")"
    [[ "$sha2" == "$sha" ]] || die "head of PR #$pr moved DURING the gate (${sha:0:8} → ${sha2:0:8}); run again to validate the current head"
    json="$(sha_check_runs "$sha")"
    pending="$(checks_pending "$json")"
    [[ -n "$pending" ]] || break
    tries=$((tries + 1))
    [[ $tries -le $CHECKS_SETTLE_TRIES ]] || break
    log "late check-run(s) still running on ${sha:0:8} ($tries/$CHECKS_SETTLE_TRIES): $pending — waiting ${CHECKS_SETTLE_SLEEP_S}s"
    sleep "$CHECKS_SETTLE_SLEEP_S"
  done
  CHECKS_SETTLED_JSON="$json"
}

checks_verify() { # checks_verify <check-runs json> <sha> <pr> — dies unless the gate passes
  local json="$1" sha="$2" pr="$3" failed pending
  pending="$(checks_pending "$json")"
  if [[ -n "$pending" ]]; then
    # still running after the settle window: by NAME, a non-required check-run must not block the
    # handover (the operator chose the required set) — drop it with a warn; a required one is fatal.
    # By COUNT the gate is "every check-run on the sha", so anything still running is fatal.
    local n blocking=() ignored=()
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      if [[ ${#REQUIRED_CHECK_NAMES[@]} -gt 0 ]] && ! _checks_is_required "$n"; then ignored+=("$n"); else blocking+=("$n"); fi
    done < <(jq -r '.[] | select(.status!="completed") | .name' <<<"$json")
    [[ ${#blocking[@]} -eq 0 ]] || die "check-runs not yet completed on ${sha:0:8} (PR #$pr) after the settle window: ${blocking[*]}"
    warn "ignoring non-required check-run(s) still running on ${sha:0:8} (PR #$pr) after the settle window: ${ignored[*]}"
    json="$(jq '[.[] | select(.status=="completed")]' <<<"$json")"
  fi
  failed="$(jq -r '[.[] | select(.conclusion!="success" and .conclusion!="skipped" and .conclusion!="neutral") | "\(.name)=\(.conclusion)"] | join(", ")' <<<"$json")"
  [[ -z "$failed" ]] || die "check-runs without success on ${sha:0:8} (PR #$pr): $failed"
  if [[ ${#REQUIRED_CHECK_NAMES[@]} -gt 0 ]]; then
    local c missing=() notpass=() st
    for c in "${REQUIRED_CHECK_NAMES[@]}"; do
      st="$(jq -r --arg c "$c" '[.[] | select(.name==$c) | .conclusion] | .[0] // "MISSING"' <<<"$json")"
      case "$st" in
        success) ;;
        MISSING) missing+=("$c") ;;
        *) notpass+=("$c=$st") ;;
      esac
    done
    [[ ${#missing[@]} -eq 0 ]] || die "required check(s) MISSING on ${sha:0:8} (PR #$pr) — \"green by absence\": $(IFS='|'; echo "${missing[*]}")"
    [[ ${#notpass[@]} -eq 0 ]] || die "required check(s) not green on ${sha:0:8} (PR #$pr): ${notpass[*]}"
    log "CI gate OK: ${#REQUIRED_CHECK_NAMES[@]}/${#REQUIRED_CHECK_NAMES[@]} required checks success on ${sha:0:8} (by NAME)"
  else
    local passed
    passed="$(jq '[.[] | select(.conclusion=="success")] | length' <<<"$json")"
    [[ "$passed" -ge "$MIN_CHECKS" ]] || die "COUNT gate: $passed successful check-run(s) < MIN_CHECKS=$MIN_CHECKS on ${sha:0:8} (PR #$pr)"
    warn "CI gate by COUNT: $passed success >= MIN_CHECKS=$MIN_CHECKS on ${sha:0:8} (PR #$pr) — no validation by name"
    orca_comment "[${TASK_IDX:-?}/${TASK_TOTAL:-?}] ${CUR_TASK:-?}: CI green by COUNT ($passed >= $MIN_CHECKS) on PR #$pr"
  fi
}
