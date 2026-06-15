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
| Stop hook | `hooks/hooks.json` + `scripts/notify.sh` | Sends a Telegram message when a batch run ends or is blocked. |
| Secrets template | `.notify.conf.example` | Copied into each project's `.claude/` (gitignored). |

Invocation: `/claude-batch-unattended:batch-unattended <paste demands>` (plugin commands are
namespaced as `/<plugin-name>:<command>`).

## How it works

1. **Phase 0 — Preconditions:** records the current branch, checks `.notify.conf` exists,
   resolves the project's verify command, team prefix, and the notify-script path.
2. **Phase 1 — Clarify:** brainstorms every demand and batches all open questions into the
   fewest `AskUserQuestion` rounds.
3. **Phase 2 — Permissions:** enumerates every command the run needs; flags anything on the
   deny list as "cannot be done autonomously."
4. **Phase 3 — Single approval:** writes the plan, creates the `.batch-active` sentinel,
   asks once: Approve / Revise / Cancel.
5. **Phase 4 — Unattended execution:** runs each demand (teams or solo), green-gates with the
   project's verify command, logs autonomous decisions, and **stops + notifies** on anything
   destructive, irreversible, or spec-conflicting.
6. **On completion:** writes the run summary to `.claude/.batch-summary.md`, removes the
   sentinel; the Stop hook reads that file and sends the summary to Telegram.

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
   `.claude/.batch-summary.md`, `.claude/hooks/notify.log` (or ignore `.claude/` wholesale).
2. **Optional label** — set `PROJECT_LABEL="MyProject"` in `.notify.conf` (defaults to the
   project directory name).
3. **Agent teams (optional)** — if you want delegated execution, set
   `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and define your team prefix + roles + verify
   command in the project's `CLAUDE.md`. Without this, the command runs solo — no extra
   config needed.
4. **Permissions** — on the first run, approve the notify Bash call (and any project-specific
   commands the plan enumerates). Add them to the project's `.claude/settings.json` allow
   list to avoid prompts on later runs.

## Notes

- The notifier **never blocks**: it always exits 0, has no deps beyond `curl`, and only
  logs failures (to `<project>/.claude/hooks/notify.log`).
- The completion message is the contents of `<project>/.claude/.batch-summary.md`, which the
  command writes on completion — a fixed file, so the notifier never has to guess which plan
  to read.
- All per-project state (`.notify.conf`, `.batch-active` sentinel, `.batch-summary.md`,
  `notify.log`, plan files) lives under the project's `.claude/`. The plugin only ships the
  command + script.
- The Stop hook only auto-notifies while a batch is active (the `.batch-active` sentinel is
  present), so it won't ping you on every ordinary session end.
