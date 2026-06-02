#!/usr/bin/env bash
# agent-lib.sh — shared configuration and helpers for agent-pad
# Source this file from other agent-* scripts.

AGENT_SESSION="${AGENT_SESSION:-agents}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.agent-state}"
AGENT_SILENCE_SECONDS="${AGENT_SILENCE_SECONDS:-30}"

# Status emoji mapping
declare -A AGENT_ICONS=(
  [running]="⏳"
  [waiting]="❓"
  [done]="✓ "
  [blocked]="🔴"
)

agent_ensure_state_dir() {
  mkdir -p "$AGENT_STATE_DIR"
}

agent_ensure_session() {
  if ! tmux has-session -t "$AGENT_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$AGENT_SESSION" -x 220 -y 50
  fi
}

# State file format: status|task|timestamp|note|window_id
agent_write_state() {
  local task="$1" status="$2" note="${3:-}" window_id="${4:-}"
  agent_ensure_state_dir
  # If no window_id provided, preserve existing one
  if [[ -z "$window_id" && -f "${AGENT_STATE_DIR}/${task}" ]]; then
    window_id=$(agent_get_window_id "$task")
  fi
  # Atomic write: temp file + rename
  local tmp
  tmp=$(mktemp "${AGENT_STATE_DIR}/.${task}.XXXXXX")
  echo "${status}|${task}|$(date +%s)|${note}|${window_id}" > "$tmp"
  mv -f "$tmp" "${AGENT_STATE_DIR}/${task}"
}

agent_get_window_id() {
  local task="$1"
  local f="${AGENT_STATE_DIR}/${task}"
  [[ -f "$f" ]] && awk -F'|' '{print $5}' "$f"
}

agent_read_state() {
  local task="$1"
  local f="${AGENT_STATE_DIR}/${task}"
  [[ -f "$f" ]] && cat "$f"
}

agent_rename_window() {
  local task="$1" status="$2" wid="${3:-}"
  local icon="${AGENT_ICONS[$status]:-⏳}"
  # Prefer an explicitly supplied window id (the caller's authoritative,
  # pane-derived id) over the stored one, so a rename can never target the
  # wrong window even if the state file is stale.
  [[ -n "$wid" ]] || wid=$(agent_get_window_id "$task")
  if [[ -n "$wid" ]]; then
    tmux rename-window -t "$wid" "${icon} ${task}" 2>/dev/null
  fi
}

agent_task_exists() {
  local task="$1"
  [[ -f "${AGENT_STATE_DIR}/${task}" ]]
}

agent_list_tasks() {
  agent_ensure_state_dir
  for f in "${AGENT_STATE_DIR}"/*; do
    [[ -f "$f" ]] || continue
    basename "$f"
  done
}
