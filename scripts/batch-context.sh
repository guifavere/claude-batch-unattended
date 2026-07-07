#!/usr/bin/env bash
# SessionStart hook: if an unattended batch run is still active in this
# project, print a short context block — SessionStart hook stdout is injected
# into the new session's context — so the session resumes the run instead of
# starting blind (e.g. after a BLOCKED ping or a crash).
# Silent no-op when no batch is active. NEVER blocks: always exits 0.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SENTINEL="${PROJECT_DIR}/.claude/.batch-active"
SUMMARY="${PROJECT_DIR}/.claude/.batch-summary.md"
BLOCKED_MARK="${PROJECT_DIR}/.claude/.batch-blocked"

[ -f "$SENTINEL" ] || exit 0

# Sentinel mtime = run start. Try GNU stat first: BSD stat rejects -c with a
# non-zero exit (clean fallback), whereas GNU stat treats -f as a format string
# and "succeeds" with garbage — so GNU must be attempted first, not second.
SINCE="$(stat -c '%y' "$SENTINEL" 2>/dev/null || stat -f '%Sm' "$SENTINEL" 2>/dev/null || echo unknown)"

if [ -f "$BLOCKED_MARK" ]; then
  STATE="last turn ended on a manual BLOCK (Stop hook has not fired since); the reason is in the BLOCKED notification / plan file"
elif [ -r "$SUMMARY" ] && [ "$SUMMARY" -nt "$SENTINEL" ]; then
  STATE="completion summary written but the sentinel was never cleared — check .claude/hooks/notify.log for a failed finish notification"
else
  STATE="in progress, no completion summary yet"
fi

cat <<EOF
UNFINISHED BATCH RUN in this project (claude-batch-unattended plugin).
- Active since: ${SINCE}
- State: ${STATE}
- To resume: read .claude/.batch-summary.md (if present) and the newest plan
  file, then continue under the /batch-unattended execution policy (green
  gate, autonomous decisions log, stop-and-notify rules).
- To discard: run /claude-batch-unattended:batch-cancel — clears the batch
  state and sends a "run cancelled" ping.
EOF
exit 0
