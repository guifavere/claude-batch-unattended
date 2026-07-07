# claude-batch-unattended

A Claude Code plugin that packages an **autonomous batch-work ritual**: paste a pile of
demands, the assistant clarifies everything up front, asks for **one consolidated
approval**, then runs unattended — and pings you on **Telegram** when it finishes or gets
blocked.

It is project-agnostic: it delegates to agent teams when your project's `CLAUDE.md` defines
them, and otherwise runs the work solo with the same discipline.

## What you get

| Piece | Path | Role |
|-------|------|------|
| Slash command | `commands/batch-unattended.md` | The intake-to-execution ritual (Phases 0–4). |
| Status / cancel | `commands/batch-status.md`, `commands/batch-cancel.md` | Inspect the run state; cancel it cleanly (with a "cancelled" ping). |
| Stop + Notification hooks | `hooks/hooks.json` + `scripts/notify.sh` | Telegram message when a batch run starts, finishes, blocks, stalls on a permission prompt, or ends abnormally. |
| SessionStart hook | `hooks/hooks.json` + `scripts/batch-context.sh` | A new session opened while a batch is active gets a context block: run state + how to resume or discard. |
| Secrets template | `.notify.conf.example` | Copied into each project's `.claude/` (gitignored). |
| Test suite | `tests/test-notify.sh` + `.github/workflows/ci.yml` | State-logic regression tests; CI runs them on Linux and macOS. |

Invocation: `/claude-batch-unattended:batch-unattended <paste demands>` (plugin commands are
namespaced as `/<plugin-name>:<command>`).

## How it works

1. **Phase 0 — Preconditions:** records the current branch, checks `.notify.conf` exists,
   resolves the project's verify command, team prefix, and the notify-script path.
2. **Phase 1 — Clarify:** brainstorms every demand and batches all open questions into the
   fewest `AskUserQuestion` rounds.
3. **Phase 2 — Permissions:** enumerates every command the run needs; flags anything on the
   deny list as "cannot be done autonomously."
4. **Phase 3 — Single approval:** writes the plan, asks once: Approve / Revise / Cancel.
   Only on Approve it creates the `.batch-active` sentinel and sends a **"run started"**
   ping — which also proves Telegram delivery works *before* hours of unattended work.
5. **Phase 4 — Unattended execution:** runs each demand (teams or solo), green-gates with the
   project's verify command, logs autonomous decisions, and **stops + notifies** on anything
   destructive, irreversible, or spec-conflicting. A stop-and-notify leaves the sentinel in
   place and drops a `.batch-blocked` marker so the run isn't mistaken for finished. If the
   run stalls on a permission prompt or idle input, the **Notification hook** pings you
   (5-min debounce) instead of waiting silently forever.
6. **On completion:** writes the run summary to `.claude/.batch-summary.md` and ends the turn.
   The Stop hook — seeing the sentinel present, no block marker, and a summary **newer than
   the sentinel** — sends the summary to Telegram and clears the sentinel. A turn that ended
   on a block consumes the marker and stays silent (exactly one message per event). A turn
   that ends mid-run with no fresh summary sends an **ATTENTION** ping (30-min debounce) and
   keeps the sentinel, so a stale summary from a previous run is never mistaken for a finish.
7. **Resuming:** any new session opened while the sentinel is present receives a SessionStart
   context block (run state, where the plan/summary live, how to resume) — after a BLOCKED
   ping or a crash you just open a session and continue. `/claude-batch-unattended:batch-status`
   shows the same picture on demand; `/claude-batch-unattended:batch-cancel` discards the run
   cleanly and pings "cancelled".

## Install

### Via GitHub (recommended)
Add this repo as a marketplace, then install the plugin:

```bash
/plugin marketplace add guifavere/claude-batch-unattended
/plugin install claude-batch-unattended@claude-batch-unattended
```

The first line points Claude Code at your GitHub repo (it reads this repo's
`.claude-plugin/marketplace.json`). Nothing is published to any public registry —
the manifest lives only in your repo; anyone with the repo URL can install it.

Or via CLI with an explicit scope:

```bash
claude plugin install claude-batch-unattended@claude-batch-unattended --scope project
```

Scopes: `user` (personal, default), `project` (shared in `.claude/settings.json`),
`local` (gitignored `.claude/settings.local.json`).

### Quick (dev / try it out)
Point Claude Code at a local clone of the plugin directory:

```bash
claude --plugin-dir /path/to/claude-batch-unattended
```

## Per-project setup (each project where you'll run it)

1. **Telegram secrets** — copy `.notify.conf.example` to the project's
   `.claude/.notify.conf`, fill `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`, and **gitignore
   it**. (Bot: create via @BotFather. chat_id: message the bot, then read
   `message.chat.id` from `https://api.telegram.org/bot<TOKEN>/getUpdates`.) Also gitignore
   the run state the plugin writes: `.claude/.notify.conf`, `.claude/.batch-active`,
   `.claude/.batch-blocked`, `.claude/.batch-summary.md`, `.claude/.batch-attn-last`,
   `.claude/.batch-notif-last`, `.claude/hooks/notify.log` (or ignore `.claude/` wholesale).
2. **Optional label** — set `PROJECT_LABEL="MyProject"` in `.notify.conf` (defaults to the
   project directory name).
3. **Agent teams (optional)** — if you want delegated execution, set
   `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and define your team prefix + roles + verify
   command in the project's `CLAUDE.md`. Without this, the command runs solo — no extra
   config needed.
4. **Permissions** — on the first run, approve the notify Bash call (and any project-specific
   commands the plan enumerates). Add them to the project's `.claude/settings.json` allow
   list to avoid prompts on later runs. Note the command's frontmatter pre-allows
   `Bash(bash:*)` for the duration of the run: the plugin's install path varies per machine,
   and a permission prompt at the exact moment of a BLOCKED notification would deadlock an
   unattended run. That is deliberately broad — if you prefer tighter scoping, remove it from
   the frontmatter and allowlist the absolute `notify.sh` path per project instead.

## Notifier modes

```
notify.sh                     # Stop hook: "finished" (summary newer than sentinel)
                              # or ATTENTION (abnormal end; 30-min debounce)
notify.sh --notification      # Notification hook: permission/idle prompt (5-min debounce)
notify.sh --start "msg"       # post-approval "run started" ping
notify.sh --cancel            # clear sentinel + markers, ping "run cancelled"
notify.sh "BLOCKED: reason"   # manual stop-and-notify (drops the block marker)
```

## Tests

```bash
bash tests/test-notify.sh     # state-logic suite, no network needed
shellcheck scripts/*.sh tests/*.sh
```

CI (GitHub Actions) runs both on every push, on Linux **and** macOS — the scripts depend on
`find -mmin`, `[ -nt ]`, `tail -c` and `iconv`, which differ between GNU and BSD userlands.

## Notes

- The notifier **never blocks**: it always exits 0, has no deps beyond `curl` + `iconv`, and
  only logs failures (to `<project>/.claude/hooks/notify.log`, auto-rotated at ~200KB).
- `.notify.conf` is **parsed** (only `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `PROJECT_LABEL`
  are read), never sourced — a repo can never ship a config that executes shell in the hook.
- Delivery is confirmed only by a Telegram `{"ok":true}` body. Transient failures are retried
  (`curl --retry`); if a send still fails, **no state that would suppress a retry is touched** —
  the sentinel and debounce markers are left as-is, so the next Stop hook (or the debounce
  window expiring) tries again. A dropped "finished" is retried on the following stop, never
  silently lost. The summary excerpt is passed through `iconv -c` so a byte-level cut never
  produces invalid UTF-8 (which Telegram rejects outright).
- The completion message is the contents of `<project>/.claude/.batch-summary.md`, which the
  command writes on completion — a fixed file, so the notifier never has to guess which plan
  to read. Only a summary **newer than the sentinel** counts: stale files from previous runs
  trigger an ATTENTION ping instead of a fake "finished".
- All per-project state (`.notify.conf`, `.batch-active` sentinel, `.batch-blocked` marker,
  `.batch-summary.md`, debounce markers, `notify.log`, plan files) lives under the project's
  `.claude/`. The plugin only ships the command + script.
- The hooks only auto-notify while a batch is active (the `.batch-active` sentinel is
  present), so they won't ping you on every ordinary session end. On a clean finish the Stop
  hook sends the summary and clears the sentinel + markers; a turn that ended on a block stays
  silent (the BLOCKED message already went out). An abnormal end keeps the sentinel — dismiss
  a batch you've abandoned with `rm .claude/.batch-active`.
