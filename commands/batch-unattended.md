---
description: Intake for autonomous batch work — clarify everything, one consolidated approval, run unattended, notify on Telegram when done.
argument-hint: "<paste all demands here>"
allowed-tools: Read, Grep, Glob, Edit, Write, AskUserQuestion, Skill(superpowers:brainstorming), Skill(superpowers:writing-plans), Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, Bash(git status:*), Bash(git branch:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(git add:*), Bash(git commit:*), Bash(git merge:*), Bash(git worktree:*), Bash(touch:*), Bash(bash:*)
---

# Autonomous Batch Work — Intake Ritual

The user will NOT be watching. Everything that needs human input MUST be
resolved in this intake phase. You are the Lead: if the project's `CLAUDE.md`
defines an agent-team workflow you delegate all code changes to agent teams in
worktrees and never edit project files directly; otherwise you do the work
yourself with the same discipline (see Phase 4).

## The demands

$ARGUMENTS

## Phase 0 — Preconditions (silent, first)

1. `git branch --show-current` + `git status --short`. Record the current
   branch. ALL final work lands on this branch. Never PR, never merge to
   main/development.
2. Confirm the notify config exists and has both secrets WITHOUT reading its
   contents (the token must never enter the transcript). Run:
   `bash -c 'f=.claude/.notify.conf; test -s "$f" && grep -Eq "^TELEGRAM_BOT_TOKEN=\"?[^\"[:space:]]" "$f" && grep -Eq "^TELEGRAM_CHAT_ID=\"?[^\"[:space:]]" "$f" && echo OK'`
   If it does not print `OK`, STOP and ask the user to create/fill it from this
   plugin's `.notify.conf.example`. Never Read or print the file.
3. Resolve and record these project-specific values for use throughout the run:
   - **Project root** (absolute): run `pwd` and record it. The Bash tool does
     NOT export `CLAUDE_PROJECT_DIR`, and worktree steps change the working
     directory, so EVERY manual notifier call below must set it explicitly:
     `CLAUDE_PROJECT_DIR="<project-root>" bash "<notify-path>" ...`. Without
     this, a stop-and-notify fired from inside a worktree writes to the wrong
     `.claude/` (no conf there) and silently sends nothing.
   - **Notify script path** (absolute): prefer `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh`.
     If that variable is not expanded in your shell, resolve it once now with:
     `find ~/.claude/plugins -type f -path '*claude-batch-unattended*/scripts/notify.sh' | head -1`
     and reuse the result for every call below.
   - **Verify command** (the "green gate"): read the project's `CLAUDE.md` and
     `package.json`/`Makefile`. Use the project's check/test command
     (e.g. `npm run check`, `make test`, `pnpm test`). If none exists, note that
     there is no automated gate and rely on manual review. **Run it ONCE now**
     to record a baseline: if it is already failing before any work, note the
     pre-existing failures — during the run, block only on NEW failures you
     introduce, not on the baseline.
   - **Team prefix**: the team-name prefix defined in the project's `CLAUDE.md`
     if present, else derive a short kebab-case prefix from the project
     directory name (e.g. `myapp`).

## Phase 1 — Understand and clarify EVERYTHING (blocking, before any work)

4. Invoke the `superpowers:brainstorming` skill to interrogate the demands (if
   that skill is not installed, do the equivalent inline: a structured
   interrogation of each demand).
   For EACH demand resolve: scope boundaries, acceptance criteria, edge cases,
   data/schema impact, UI/UX expectations, ordering/dependencies between
   demands, and what "done" means. Identify every ambiguity.
5. Batch all questions and ask them via AskUserQuestion in the fewest rounds
   possible. Do NOT start with any open question. Ask about: ambiguous
   requirements and priority/order; anything destructive or irreversible
   implied (schema drop, backfill/migration, deploy, deletion) — explicit
   yes/no now; acceptable trade-offs if a demand cannot be fully met.

## Phase 2 — Enumerate EVERY permission/command needed (blocking)

6. Explicitly list every command class the run will need that is NOT in the
   allow list of `.claude/settings.json`. Cross-check against allow and deny.
   For each: command pattern, why, which demand, reversible?, destructive?
7. Anything in the deny list a demand would require (prod deploy, raw SQL
   execution, schema migration apply, `git push --force`, `rm -rf`...) MUST be
   flagged now as "cannot be done autonomously" — propose an alternative or
   ask the user to pre-run it. NEVER plan to work around the deny list.

## Phase 3 — Single consolidated approval (blocking)

8. Use the `superpowers:writing-plans` skill to write the execution plan to the
   plan file (if not installed, write the plan directly with the same structure):
   ordered demands, per-demand execution chain
   (impl → testing → review, or solo steps), target branch, the
   autonomous-vs-stop policy below, and the full Phase 2 permission list.
9. Present ONE consolidated message: plan summary + the exact extra
   allow entries the user must add (if any) + deny-list blockers. Ask for a
   single approval via AskUserQuestion: Approve / Revise / Cancel. Do NOT
   create the sentinel before the answer — an interrupted or abandoned
   approval must leave no batch state behind.
10. Only after Approve: create the sentinel `.claude/.batch-active` (touch the
    file — its mtime is the run's start marker; the Stop hook only treats a
    summary NEWER than it as a real finish), then send the start ping (note the
    explicit `CLAUDE_PROJECT_DIR`, per Phase 0):
    `CLAUDE_PROJECT_DIR="<project-root>" bash "<notify-path>" --start "<one-line plan summary>"`.
    Then read the last line of `.claude/hooks/notify.log`: if it is not
    `telegram OK (start)`, delivery is broken — STOP and warn the user in chat
    (quote the failure line) instead of running hours blind. Only once the
    start ping is confirmed, tell the user they can do something else; you will
    notify on Telegram + report in chat when done (or if a stop-and-notify
    condition is hit).

## Team Naming Convention (when delegating to agent teams)

Parallel demands share the global `~/.claude/teams/` namespace. To avoid
collision and keep teams debuggable:

- Team names MUST follow `<prefix>-<role>-<demand-slug>` where:
  - `<prefix>` is the project team prefix resolved in Phase 0.
  - `<role>` is one of `frontend`, `backend`, `testing`, `review`.
  - `<demand-slug>` is a short kebab-case identifier derived from the
    demand itself (e.g. `fix-radix-crash`, `add-orders-filter`).
    NEVER use `batch1`/`batch2`/numeric indices — they repeat across
    sessions and are not debuggable.
- Examples (prefix `myapp`): `myapp-backend-fix-orders-filter`,
  `myapp-frontend-fix-radix-crash`, `myapp-testing-add-orders-filter`.
- Pick the slug ONCE per demand during Phase 3 (planning). Record the
  slug for each demand in the plan file so all teams of that demand share it.
- After the full chain (impl → testing → review) for a demand finishes,
  call `TeamDelete` for EACH team created for that demand. Do not defer.

## Phase 4 — Autonomous execution (after approval)

11. Execute each demand. Choose the mode based on the project:
    - **If the project's `CLAUDE.md` defines an agent-team workflow** → delegate
      per those conventions: teammate + worktree + commit per demand; after each
      implementation team commits, immediately run the testing → review chain;
      the Lead merges the teammate commits into the current branch and cleans up
      the worktree with
      `git worktree remove .claude/worktrees/<agent-id> --force && git branch -D worktree-<agent-id>`.
      Team names MUST follow the convention above; call `TeamDelete` per team
      after its chain completes.
    - **Otherwise (no agent-team setup)** → do the work yourself (solo) on the
      current branch, committing per demand, applying the SAME green gate,
      Autonomous Decisions Log, and stop-and-notify discipline. No teams needed.
12. Green gate before any demand counts as done: run the project's verify
    command resolved in Phase 0 (skip only if the project has none).
13. Apply the Hybrid Policy below at every decision point.
14. Keep an "Autonomous Decisions Log" in the plan file: every small decision
    taken without asking, with a one-line rationale.

## Hybrid Mid-Run Policy (MANDATORY)

DECIDE AUTONOMOUSLY and log it (do not interrupt) when the choice is:
- Reversible in code (naming, file layout, refactor shape, library within
  existing deps, test structure, minor UX copy).
- Within the agreed spec and acceptance criteria.
- Recoverable via git on the current branch.

Sanctioned cleanup (NOT a blocker): `git worktree remove --force` and
`git branch -D worktree-<id>` for worktrees/branches THIS run created (per
step 11) are normal housekeeping — do them without stopping.

STOP IMMEDIATELY, notify, and wait when the action is:
- DESTRUCTIVE: deletes/overwrites user data, drops table/column, force
  operation on data you did not create, mass file deletion, history rewrite.
- IRREVERSIBLE: any deploy (dev OR prod), raw SQL execution / schema migration
  apply, external API write with side effects, any deny-list item, anything
  touching main/development.
- SPEC CONFLICT: the only way to satisfy a demand contradicts another demand
  or a Phase 1 answer, or the demand is infeasible / much larger than scoped.
To "stop and notify": run
`CLAUDE_PROJECT_DIR="<project-root>" bash "<notify-path>" "BLOCKED: <reason>"`
(the root and path resolved in Phase 0 — the explicit `CLAUDE_PROJECT_DIR` is
mandatory, especially from inside a worktree), end the turn and wait for the
user. Do NOT proceed past the blocker. The sentinel stays in place (the batch is still
active). When the BLOCKED message is delivered, the notifier marks the block so the
trailing Stop hook stays silent; if delivery fails, that Stop instead sends the
fallback ATTENTION ("ended without a summary") — so a failed BLOCKED never leaves you
with no ping at all.

Never end a mid-run turn any other way: a turn that ends while the batch is
active without a fresh summary (and without the BLOCKED call) makes the Stop
hook send an ATTENTION ping — correct as a safety net, but it means you
stopped without following this policy.

A NEW session opened while the batch is active receives a SessionStart context
block describing the run state. If you see it, resume from the plan file and
`.claude/.batch-summary.md` under this same policy — do not restart the intake.

## On completion

15. When ALL demands are done (or permanently blocked), write a simple report
    in chat AND a final summary block in the plan file: demands done, blocked
    + reason, Autonomous Decisions Log, worktrees cleaned (if any),
    verify-command status.
16. Write that same final report (overwrite) to
    `${CLAUDE_PROJECT_DIR}/.claude/.batch-summary.md` — this is the exact file
    the Stop hook reads to build the Telegram message. Keep it short (the
    notifier sends the last ~1200 bytes): the headline status, demands done,
    anything blocked + reason. Do NOT remove the sentinel yourself — the Stop
    hook clears `${CLAUDE_PROJECT_DIR}/.claude/.batch-active` when it sends the
    finished message.
17. End the turn normally. The Stop hook fires `notify.sh`, which (because the
    sentinel is present and the turn did not end on a block) sends the contents
    of `.claude/.batch-summary.md` to Telegram and then removes the sentinel.

## Notification setup (tell the user if .notify.conf is missing)

Create `${CLAUDE_PROJECT_DIR}/.claude/.notify.conf` from this plugin's
`.notify.conf.example`:

    TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
    TELEGRAM_CHAT_ID="numeric-chat-id"
    # PROJECT_LABEL="MyProject"   # optional, defaults to the project dir name

How to obtain: create a bot via @BotFather (copy the token); send any message
to the bot; open `https://api.telegram.org/bot<TOKEN>/getUpdates` and read
`message.chat.id`.
