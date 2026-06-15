#!/usr/bin/env bash
# Stop-hook notifier for unattended batch runs (Telegram).
# NEVER blocks: only sends notifications, always exits 0.
# Modes:
#   - Stop hook: receives Stop JSON on stdin (auto "finished").
#   - Manual stop-and-notify: notify.sh "BLOCKED: reason"
#
# Generic (project-agnostic) version. All per-project state lives under
# ${CLAUDE_PROJECT_DIR}/.claude/ ; this script ships inside the plugin and is
# referenced via ${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh.
set -uo pipefail

# CLAUDE_PROJECT_DIR is set by the harness when this runs as a hook. Fall back
# to the current working directory only as a last resort.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONF="${PROJECT_DIR}/.claude/.notify.conf"
LOG="${PROJECT_DIR}/.claude/hooks/notify.log"
SENTINEL="${PROJECT_DIR}/.claude/.batch-active"
MANUAL_MSG="${1:-}"

# Ensure the log directory exists (project may not have .claude/hooks/).
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

STDIN_JSON=""
if [ -z "$MANUAL_MSG" ] && [ ! -t 0 ]; then
  STDIN_JSON="$(cat 2>/dev/null || true)"
fi

# Infinite-loop guard: if another Stop hook is blocking, do not re-notify.
if [ -n "$STDIN_JSON" ]; then
  ACTIVE="$(printf '%s' "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
  if [ "$ACTIVE" = "true" ]; then
    echo "$(date -u +%FT%TZ) skip: stop_hook_active=true" >> "$LOG"
    exit 0
  fi
fi

# Auto "finished" only fires during an active batch run (sentinel present).
if [ -z "$MANUAL_MSG" ] && [ ! -f "$SENTINEL" ]; then
  exit 0
fi

if [ ! -r "$CONF" ]; then
  echo "$(date -u +%FT%TZ) ERROR: $CONF missing; no notification sent" >> "$LOG"
  exit 0
fi
# shellcheck disable=SC1090
. "$CONF"

# Project label: override via PROJECT_LABEL= in .notify.conf, else the project
# directory name.
LABEL="${PROJECT_LABEL:-$(basename "$PROJECT_DIR")}"

HOST="$(hostname 2>/dev/null || echo unknown)"
if [ -n "$MANUAL_MSG" ]; then
  HEAD="${LABEL} batch: ATTENTION NEEDED"; BODY="$MANUAL_MSG"
else
  HEAD="${LABEL} batch: run finished"
  LATEST="$(ls -t "${PROJECT_DIR}/.claude/plans/"*.md 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ]; then BODY="$(tail -c 1200 "$LATEST" 2>/dev/null)";
  else BODY="Batch run completed. See plan file for the full summary."; fi
fi
TEXT="${HEAD}
[$HOST] $(date -u +%FT%TZ)
$BODY"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  curl -sS -m 15 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TEXT}" \
    --data "disable_web_page_preview=true" >> "$LOG" 2>&1 \
    && echo "$(date -u +%FT%TZ) telegram OK" >> "$LOG" \
    || echo "$(date -u +%FT%TZ) telegram FAILED" >> "$LOG"
else
  echo "$(date -u +%FT%TZ) ERROR: telegram vars missing in .notify.conf" >> "$LOG"
fi
exit 0
