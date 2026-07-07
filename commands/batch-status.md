---
description: Show the state of this project's unattended batch run — sentinel, block marker, summary freshness, notifier log.
allowed-tools: Read, Bash(ls:*), Bash(stat:*), Bash(tail:*), Bash(git status:*), Bash(git log:*)
---

# Batch Status

Report the current state of this project's unattended batch run. All state
lives under `${CLAUDE_PROJECT_DIR}/.claude/`. Check, in order:

1. **Sentinel** `.claude/.batch-active`: present? If yes, report since when
   (mtime). If absent, say "no batch active" and still report items 4–5
   briefly.
2. **Block marker** `.claude/.batch-blocked`: present means the last turn
   ended on a manual stop-and-notify and the Stop hook has not fired since.
3. **Summary** `.claude/.batch-summary.md`: missing / stale (older than the
   sentinel) / fresh (newer). If present, quote its last ~10 lines.
4. **Notifier log** `.claude/hooks/notify.log`: quote the last 10 lines; flag
   any `telegram FAILED` or `ERROR` lines.
5. **Git**: current branch + `git status --short`.

End with a one-line verdict — running / blocked (reason if visible) / finished
but sentinel not cleared / no batch active — and the obvious next step
(resume, `/claude-batch-unattended:batch-cancel`, or nothing).
