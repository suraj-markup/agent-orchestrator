---
"@aoagents/ao-core": patch
"@aoagents/ao-cli": patch
---

Make `ao` discoverable from OpenClaw and other agents (#482):

- Ship a bundled `SKILL.md` describing the full `ao init` → `ao spawn`
  lifecycle. `ao setup openclaw` now installs it to
  `~/.openclaw/skills/ao.skill.md` so the OpenClaw agent can discover
  and use `ao` without being told it exists.
- Respect `$XDG_CONFIG_HOME` (and `~/.config/agent-orchestrator/`) when
  searching for `agent-orchestrator.yaml`. The dotfile and legacy
  `config.yaml` locations are still honored. Export
  `getConfigSearchPaths()` from core for tooling / error messages.
- `ao status` prints the active config path on the first line so agents
  can discover where the config lives in one call.
- `ConfigNotFoundError` now lists the locations that were searched and
  points at `ao init` as the remediation step.
- `ao spawn` / `ao batch-spawn` translate `ConfigNotFoundError` into a
  clear, non-stack-trace error with explicit next steps for agents
  invoking `ao` programmatically.
