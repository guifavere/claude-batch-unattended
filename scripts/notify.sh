#!/usr/bin/env bash
# Telegram notifier for unattended batch runs.
# NEVER blocks: only sends notifications, always exits 0.
#
# Modes:
#   notify.sh                    Stop hook. With the batch sentinel present:
#                                - turn ended on a manual block -> consume the
#                                  .batch-blocked marker, stay silent (the
#                                  BLOCKED message already went out);
#                                - .batch-summary.md exists and is NEWER than
#                                  the sentinel -> real finish: send it as
#                                  "run finished", clear sentinel + markers;
#                                - otherwise the turn ended WITHOUT finishing ->
#                                  send ATTENTION (30-min debounce) and KEEP the
#                                  sentinel so a later real finish still
#                                  notifies.
#                                Without the sentinel: instant silent no-op.
#   notify.sh --notification     Notification hook (permission request / idle
#                                input). Only acts while the sentinel is
#                                present; 5-min debounce so repeated prompts
#                                don't spam.
#   notify.sh --start "msg"      Post-approval "run started" ping. Also proves
#                                the Telegram pipeline works at minute zero
#                                instead of hours later.
#   notify.sh --cancel           Cancel the active batch: send "run cancelled"
#                                and clear the sentinel + all markers. No-op
#                                (logged) when no batch is active.
#   notify.sh "BLOCKED: reason"  Manual stop-and-notify (drops .batch-blocked).
#
# If .notify.conf is missing nothing is sent and the sentinel is left in place;
# the error is logged on every stop until the conf is restored or the sentinel
# is removed by hand.
#
# Generic (project-agnostic). All per-project state lives under
# ${CLAUDE_PROJECT_DIR}/.claude/ ; this script ships inside the plugin and is
# referenced via ${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh.
# No external deps beyond curl and iconv.
set -uo pipefail

# CLAUDE_PROJECT_DIR is set by the harness when this runs as a hook. Fall back
# to the current working directory only as a last resort.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONF="${PROJECT_DIR}/.claude/.notify.conf"
LOG="${PROJECT_DIR}/.claude/hooks/notify.log"
SENTINEL="${PROJECT_DIR}/.claude/.batch-active"
SUMMARY="${PROJECT_DIR}/.claude/.batch-summary.md"
BLOCKED_MARK="${PROJECT_DIR}/.claude/.batch-blocked"
ATTN_MARK="${PROJECT_DIR}/.claude/.batch-attn-last"   # debounce: stale-stop ATTENTION
NOTIF_MARK="${PROJECT_DIR}/.claude/.batch-notif-last" # debounce: permission/input pings

case "${1:-}" in
  --notification) MODE=notification; MSG="" ;;
  --start)        MODE=start;        MSG="${2:-}" ;;
  --cancel)       MODE=cancel;       MSG="" ;;
  "")             MODE=stop;         MSG="" ;;
  *)              MODE=blocked;      MSG="$1" ;;
esac

# Guard FIRST, before any side effect: hook-driven modes only act during an
# active batch run (sentinel present). An ordinary session stop / notification
# with no batch active is a no-op — no dirs created, no stdin read, instant exit.
case "$MODE" in
  stop|notification) [ -f "$SENTINEL" ] || exit 0 ;;
esac

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
# True when marker file $1 is newer than $2 minutes.
recent() { [ -f "$1" ] && [ -n "$(find "$1" -mmin "-$2" 2>/dev/null)" ]; }

# Past the guard: this is a real notification. Ensure the log dir exists and
# keep the log from growing without bound.
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 204800 ]; then
  tail -c 102400 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
fi

FINISHED=0
case "$MODE" in
  cancel)
    if [ ! -f "$SENTINEL" ]; then
      log "cancel: no active batch"
      exit 0
    fi
    ;;
  blocked)
    # Mark that this turn ended on a block, so the Stop hook that fires right
    # after this turn stays silent instead of sending "finished".
    : > "$BLOCKED_MARK" 2>/dev/null || true
    ;;
  notification)
    if recent "$NOTIF_MARK" 5; then
      log "skip notification ping: debounced"
      exit 0
    fi
    # The harness pipes the hook JSON on stdin; pull the human-readable
    # "message" field out without jq. Tty guard so manual runs don't hang.
    RAW=""
    [ -t 0 ] || RAW="$(cat 2>/dev/null || true)"
    MSG="$(printf '%s' "$RAW" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    ;;
  stop)
    # If the turn ended on a block, the BLOCKED message already went out —
    # consume the marker and stay silent.
    if [ -f "$BLOCKED_MARK" ]; then
      rm -f "$BLOCKED_MARK"
      log "skip finished: turn ended on a block"
      exit 0
    fi
    # Only a summary written DURING THIS RUN (newer than the sentinel) counts
    # as a real finish; a stale file from a previous run, or no file at all,
    # means the turn ended mid-run and the user needs to know.
    if [ -r "$SUMMARY" ] && [ "$SUMMARY" -nt "$SENTINEL" ]; then
      FINISHED=1
    elif recent "$ATTN_MARK" 30; then
      log "skip stale-stop attention: debounced"
      exit 0
    fi
    ;;
esac

if [ ! -r "$CONF" ]; then
  log "ERROR: $CONF missing; no notification sent"
  exit 0
fi
# shellcheck disable=SC1090
. "$CONF"

# Project label: override via PROJECT_LABEL= in .notify.conf, else the project
# directory name.
LABEL="${PROJECT_LABEL:-$(basename "$PROJECT_DIR")}"
HOST="$(hostname 2>/dev/null || echo unknown)"

case "$MODE" in
  blocked)
    HEAD="${LABEL} batch: ATTENTION NEEDED"
    BODY="$MSG"
    ;;
  start)
    HEAD="${LABEL} batch: run started"
    BODY="${MSG:-Unattended run approved and under way.}"
    ;;
  cancel)
    HEAD="${LABEL} batch: run cancelled"
    BODY="Run cancelled by the user; batch state cleared."
    ;;
  notification)
    HEAD="${LABEL} batch: ATTENTION NEEDED"
    BODY="Claude is waiting (permission request or idle input): ${MSG:-no detail provided}"
    ;;
  stop)
    if [ "$FINISHED" = 1 ]; then
      HEAD="${LABEL} batch: run finished"
      # tail -c can split a multibyte char at the cut; Telegram rejects the
      # whole message on invalid UTF-8, so iconv -c drops the broken edge bytes.
      BODY="$(tail -c 1200 "$SUMMARY" 2>/dev/null | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
      [ -n "$BODY" ] || BODY="Batch run completed. See plan file for the full summary."
    else
      HEAD="${LABEL} batch: ATTENTION NEEDED"
      BODY="Session ended without a completion summary — the batch is still marked active. Resume the run, or dismiss with: rm .claude/.batch-active"
    fi
    ;;
esac

TEXT="${HEAD}
[$HOST] $(date -u +%FT%TZ)
$BODY"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  # Telegram returns HTTP 200 with {"ok":false,...} on bad token/chat, so a
  # zero curl exit is NOT proof of delivery — inspect the response body.
  # --retry covers transient failures (timeout, 408/429/5xx); per-attempt -m 8
  # and --retry-max-time 25 keep the total under the hook's 30s timeout.
  RESP="$(curl -sS -m 8 --retry 2 --retry-delay 2 --retry-max-time 25 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TEXT}" \
    --data "disable_web_page_preview=true" 2>>"$LOG")"
  case "$RESP" in
    *'"ok":true'*) log "telegram OK ($MODE)" ;;
    *) log "telegram FAILED ($MODE): ${RESP:-no response}" ;;
  esac
else
  log "ERROR: telegram vars missing in .notify.conf"
fi

# Post-send bookkeeping (regardless of the send outcome above).
case "$MODE" in
  notification)
    : > "$NOTIF_MARK" 2>/dev/null || true
    ;;
  cancel)
    rm -f "$SENTINEL" "$BLOCKED_MARK" "$ATTN_MARK" "$NOTIF_MARK"
    ;;
  stop)
    if [ "$FINISHED" = 1 ]; then
      # The batch is done — clear the sentinel and all markers so ordinary
      # later stops don't re-notify.
      rm -f "$SENTINEL" "$BLOCKED_MARK" "$ATTN_MARK" "$NOTIF_MARK"
    else
      : > "$ATTN_MARK" 2>/dev/null || true
    fi
    ;;
esac
exit 0
