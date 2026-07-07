---
description: Cancel the active unattended batch run — clears the sentinel and markers and sends a "run cancelled" ping.
allowed-tools: Read, Bash(ls:*), Bash(tail:*), Bash(bash:*)
---

# Batch Cancel

1. Check `.claude/.batch-active`. If absent, tell the user there is no active
   batch and STOP — do not run the notifier.
2. If present, run (the explicit `CLAUDE_PROJECT_DIR` is required — the Bash
   tool does not export it):

       CLAUDE_PROJECT_DIR="$(pwd)" bash "<notify-path>" --cancel

   Resolve `<notify-path>` as `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh`, or if
   that variable is not expanded:
   `find ~/.claude/plugins -type f -path '*claude-batch-unattended*/scripts/notify.sh' | head -1`.
   This clears the sentinel and all markers and sends the "run cancelled"
   Telegram ping.
3. Report in chat: state cleared; whether the ping was delivered (read the
   last line of `.claude/hooks/notify.log` — `telegram OK (cancel)` vs
   `FAILED`); and note that worktrees/teams/branches created by the run are
   NOT touched — list any the plan file names so the user can clean them up.
