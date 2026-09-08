#!/usr/bin/env bash
# lib/orca.sh — best-effort progress reporting to the worktree card in Orca ADE.
# Sourceable. Never fails: no binary = no-op with 1 warn; CLI error = silenced.
# Contract: orca_comment "short text" · orca_status todo|in-progress|in-review|completed
# In dry-run (QUEUE_DRY_RUN=1) it only prints what it would emit.
# Set ORCA_ENABLED=0 to disable reporting entirely (no warn).

if [[ -n "${_ORCA_LIB_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_ORCA_LIB_LOADED=1

ORCA_ENABLED="${ORCA_ENABLED:-1}"
ORCA_BIN=""
[[ "$ORCA_ENABLED" == "1" ]] && ORCA_BIN="$(command -v orca 2>/dev/null || true)"

# Worktree selector. `active` resolves from the CURRENT DIRECTORY (measured: outside the repo it
# yields selector_not_found), so the runner, which lives outside the repo, uses `path:$REPO_DIR`.
# An explicit ORCA_SELECTOR wins; without REPO_DIR it falls back to `active`.
_orca_selector() {
  if [[ -n "${ORCA_SELECTOR:-}" ]]; then echo "$ORCA_SELECTOR"
  elif [[ -n "${REPO_DIR:-}" ]]; then echo "path:$REPO_DIR"
  else echo "active"; fi
}

if [[ "$ORCA_ENABLED" == "1" && -z "$ORCA_BIN" ]]; then
  echo "WARN: orca CLI not found in PATH; Orca reporting disabled (no-op)" >&2
fi

_orca_set() { # _orca_set <flag> <value>
  local sel; sel="$(_orca_selector)"
  if [[ "${QUEUE_DRY_RUN:-0}" == "1" ]]; then
    printf '[dry-run] orca worktree set --worktree %s %s "%s"\n' "$sel" "$1" "$2"
    return 0
  fi
  [[ -z "$ORCA_BIN" ]] && return 0
  "$ORCA_BIN" worktree set --worktree "$sel" "$1" "$2" --json >/dev/null 2>&1 || true
  return 0
}

# Boot probe: does the selector resolve? Binary present but worktree not managed (e.g. a scratch
# repo) = disable with 1 warn, instead of swallowing selector_not_found on every call.
orca_probe() {
  [[ -z "$ORCA_BIN" ]] && return 0
  [[ "${QUEUE_DRY_RUN:-0}" == "1" ]] && return 0
  local sel out ok; sel="$(_orca_selector)"
  out="$("$ORCA_BIN" worktree show --worktree "$sel" --json 2>/dev/null || true)"
  ok="$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null || echo false)"
  if [[ "$ok" != "true" ]]; then
    echo "WARN: orca cannot resolve worktree '$sel' ($(printf '%s' "$out" | jq -r '.error.code // "no response"' 2>/dev/null)); Orca reporting disabled (no-op)" >&2
    ORCA_BIN=""
  fi
  return 0
}

orca_comment() { _orca_set --comment "$1"; }
orca_status()  { _orca_set --workspace-status "$1"; }
