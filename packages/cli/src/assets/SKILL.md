---
name: ao (agent-orchestrator)
description: |
  Use this skill to spawn and manage persistent AI coding agent sessions via
  the `ao` (agent-orchestrator) CLI. Trigger on intents like "spawn an agent
  session", "start a long-running agent", "persistent session", "agent
  orchestrator", or when the user asks you to delegate a coding task to a
  background agent that manages its own git branch and PR.
triggers:
  - persistent session
  - agent orchestrator
  - ao spawn
  - long-running agent
  - background coding agent
  - spawn an agent
requires:
  - ao
---

# ao — Agent Orchestrator

`ao` is a CLI on this machine that launches parallel AI coding agents (Claude
Code, Codex, Aider, OpenCode) inside isolated git worktrees. Each spawned
agent autonomously writes code, opens a PR, fixes CI, and responds to
reviews. Use `ao` whenever the user asks for a *persistent* or *long-running*
coding task rather than a one-shot edit you run yourself.

## When to use ao vs. one-shot tools

**Use ao when:**
- The user says "spawn a session" / "spawn an agent" / "kick off a background
  agent" / "have an agent fix issue #123".
- The task is expected to take more than a few minutes or involves iterating
  on CI failures and review comments.
- The user wants the work tracked as a separate branch and PR.

**Do NOT use ao when:**
- The user just wants a quick one-shot edit inside the current shell.
- There is no git repo / no issue tracker wired up.

## Discovering whether ao is available

```bash
command -v ao >/dev/null 2>&1 && ao --version
ao status                  # shows config path and active sessions
```

`ao status` always prints the config path it is using as the first line of
output, which is the fastest way to confirm `ao` is installed and configured.

## Core lifecycle

```bash
# 1. (one-time per machine) create or locate the config
ao init                    # interactive — creates agent-orchestrator.yaml
ao status                  # shows where the config lives

# 2. spawn a session for an issue (project is auto-detected from config)
ao spawn 123               # "work on issue 123"
ao spawn --prompt "refactor the auth middleware"
ao spawn --claim-pr 456    # take over an existing PR

# 3. watch progress
ao status                  # list sessions, PRs, CI, review state
ao session logs <session>  # tail the agent's terminal output
```

`ao spawn` auto-starts the per-project lifecycle worker if it is not already
running — you do not need to run `ao start` first just to spawn a session.
`ao start <project>` is only required when you also want the dashboard.

## Common recipes for agents invoking ao

**Spawn for a GitHub issue, non-interactive:**
```bash
ao spawn 482
```

**Spawn with an ad-hoc prompt instead of an issue:**
```bash
ao spawn --prompt "add rate limiting to /api/login"
```

**Take over an existing PR for review iteration:**
```bash
ao spawn --claim-pr https://github.com/org/repo/pull/789
```

**Check what a session is doing right now:**
```bash
ao status --json | jq '.[] | select(.name=="<session-id>")'
```

## Config discovery

`ao` searches (in order):

1. `$AO_CONFIG_PATH`
2. `agent-orchestrator.yaml` found by walking up from CWD (git-style)
3. `~/.agent-orchestrator.yaml` (legacy dotfile)
4. `$XDG_CONFIG_HOME/agent-orchestrator/agent-orchestrator.yaml`
   (defaults to `~/.config/agent-orchestrator/agent-orchestrator.yaml`)
5. `~/.config/agent-orchestrator/config.yaml` (legacy)

If `ao status` reports "No config found", run `ao init` from the repo you
want to manage.

## When things go wrong

- **"No projects configured"** — there is no `projects:` block in the config.
  Run `ao init` or add one manually. Do *not* silently fall back to a
  one-shot run; tell the user.
- **"Multiple projects configured. Specify one: ..."** — pass the project
  name or `cd` into the project's working tree before calling `ao spawn`.
- **Gateway / notifier errors** — run `ao doctor` to diagnose.

## Related

- Dashboard: `ao dashboard` (opens the web UI on localhost)
- Full command list: `ao --help`
- Setup OpenClaw integration: `ao setup openclaw`
