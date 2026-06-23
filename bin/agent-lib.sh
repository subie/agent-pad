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

# Return success if WID names a tmux window that currently exists.
agent_window_alive() {
  local wid="$1"
  [[ -n "$wid" ]] || return 1
  tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qx "$wid"
}

agent_read_state() {
  local task="$1"
  local f="${AGENT_STATE_DIR}/${task}"
  [[ -f "$f" ]] && cat "$f"
}

# Print the task name whose state file records WID as its window id, if any.
# Used by the run wrapper to discover its *current* name (the task may have
# been renamed while running) so exit-time state writes target the right file.
agent_task_for_window() {
  local wid="$1"
  [[ -n "$wid" ]] || return 0
  agent_ensure_state_dir
  local f
  for f in "${AGENT_STATE_DIR}"/*; do
    [[ -f "$f" ]] || continue
    if [[ "$(awk -F'|' '{print $5}' "$f")" == "$wid" ]]; then
      basename "$f"
      return 0
    fi
  done
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

# Rename a task: move its state file OLD -> NEW (rewriting the task field) and
# rename its tmux window to match, keeping the current status icon.  The window
# id is preserved, so any attached eat buffer / tmux client stays connected.
agent_rename_task() {
  local old="$1" new="$2"
  local f="${AGENT_STATE_DIR}/${old}"
  [[ -f "$f" ]] || return 1
  local status timestamp note wid
  IFS='|' read -r status _ timestamp note wid < "$f" || true
  local tmp
  tmp=$(mktemp "${AGENT_STATE_DIR}/.${new}.XXXXXX")
  echo "${status}|${new}|${timestamp}|${note}|${wid}" > "$tmp"
  mv -f "$tmp" "${AGENT_STATE_DIR}/${new}"
  rm -f "$f"
  agent_rename_window "$new" "$status" "$wid"
}

agent_list_tasks() {
  agent_ensure_state_dir
  for f in "${AGENT_STATE_DIR}"/*; do
    [[ -f "$f" ]] || continue
    basename "$f"
  done
}
