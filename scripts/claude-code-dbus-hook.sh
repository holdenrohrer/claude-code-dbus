#!/usr/bin/env bash
# Claude Code hook handler: reads JSON payload from stdin, sends D-Bus signal.
# Dependencies: jq, dbus-send (standard on Linux desktops)
set -euo pipefail

input=$(cat)

event=$(echo "$input" | jq -r '.hook_event_name // "unknown"')
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')
tool_name=$(echo "$input" | jq -r '.tool_name // ""')
cwd=$(echo "$input" | jq -r '.cwd // ""')
ide_session_id="${CLAUDE_CODE_IDE_SESSION_ID:-}"
notification_type=$(echo "$input" | jq -r '.notification_type // ""')

dbus-send --session \
  /com/claude/code \
  com.claude.Code.HookEvent \
  string:"$event" \
  string:"$session_id" \
  string:"$tool_name" \
  string:"$cwd" \
  string:"$ide_session_id" \
  string:"$notification_type"
