#!/usr/bin/env bash
# Stop-hook notifier for unattended batch runs (Telegram).
# NEVER blocks: only sends notifications, always exits 0.
# Modes:
#   - Stop hook: auto "finished" — fires when a batch is active (sentinel
#     present) AND the turn did not end on a block. On a clean finish it sends
#     the summary and clears the sentinel. A turn that ended on a manual block
#     leaves a .batch-blocked marker, which makes this run stay silent (the
#     BLOCKED message already went out) and consume the marker.
#   - Manual stop-and-notify: notify.sh "BLOCKED: reason"  (drops the marker)
#
# Generic (project-agnostic). All per-project state lives under
# ${CLAUDE_PROJECT_DIR}/.claude/ ; this script ships inside the plugin and is
# referenced via ${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh.
# No external deps beyond curl.
set -uo pipefail

# CLAUDE_PROJECT_DIR is set by the harness when this runs as a hook. Fall back
# to the current working directory only as a last resort.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONF="${PROJECT_DIR}/.claude/.notify.conf"
LOG="${PROJECT_DIR}/.claude/hooks/notify.log"
SENTINEL="${PROJECT_DIR}/.claude/.batch-active"
SUMMARY="${PROJECT_DIR}/.claude/.batch-summary.md"
BLOCKED_MARK="${PROJECT_DIR}/.claude/.batch-blocked"
MANUAL_MSG="${1:-}"

# Guard FIRST, before any side effect: the auto "finished" message only fires
# during an active batch run (sentinel present). An ordinary session stop with
# no batch active is a no-op — no dirs created, no stdin read, instant exit.
if [ -z "$MANUAL_MSG" ] && [ ! -f "$SENTINEL" ]; then
  exit 0
fi

# Past the guard: this is a real notification. Ensure the log dir exists.
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

if [ -n "$MANUAL_MSG" ]; then
  # Manual BLOCKED call: mark that this turn ended on a block, so the Stop hook
  # that fires right after this turn stays silent instead of sending "finished".
  : > "$BLOCKED_MARK" 2>/dev/null || true
else
  # Stop hook (sentinel present). If the turn ended on a block, the BLOCKED
  # message already went out — consume the marker and stay silent.
  if [ -f "$BLOCKED_MARK" ]; then
    rm -f "$BLOCKED_MARK"
    echo "$(date -u +%FT%TZ) skip finished: turn ended on a block" >> "$LOG"
    exit 0
  fi
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
  if [ -r "$SUMMARY" ]; then BODY="$(tail -c 1200 "$SUMMARY" 2>/dev/null)";
  else BODY="Batch run completed. See plan file for the full summary."; fi
fi
TEXT="${HEAD}
[$HOST] $(date -u +%FT%TZ)
$BODY"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  # Telegram returns HTTP 200 with {"ok":false,...} on bad token/chat, so a
  # zero curl exit is NOT proof of delivery — inspect the response body.
  RESP="$(curl -sS -m 15 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TEXT}" \
    --data "disable_web_page_preview=true" 2>>"$LOG")"
  case "$RESP" in
    *'"ok":true'*) echo "$(date -u +%FT%TZ) telegram OK" >> "$LOG" ;;
    *) echo "$(date -u +%FT%TZ) telegram FAILED: ${RESP:-no response}" >> "$LOG" ;;
  esac
else
  echo "$(date -u +%FT%TZ) ERROR: telegram vars missing in .notify.conf" >> "$LOG"
fi

# Finished mode: the batch is done — clear the sentinel so ordinary later stops
# don't re-notify (regardless of the send outcome above).
[ -z "$MANUAL_MSG" ] && rm -f "$SENTINEL"
exit 0
