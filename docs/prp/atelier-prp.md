# PRP: Atelier — Shared Container Infrastructure

**Status:** Design complete, ready for audit-before-code phase.
**Role for Claude Code:** Read fully before writing code. Phase 0 is an
audit — produce `AUDIT.md` first.

---

## 1. Objective

Container infrastructure with two independent consumers: the owner working
interactively (`agent-enter <project>`) and Meute's dispatcher working
autonomously (pulling the same tagged images for ephemeral build/test
containers). Atelier owns image definitions and the entry mechanism; it has
no knowledge of Meute, spare-quota dispatch, or pipeline stages — those
concepts don't belong here.

**Consumption boundary (the reason this is its own repo):** Meute pins to
Atelier's image tags. Meute never edits a Containerfile or `agent-enter.sh`.
A daily-driver change here doesn't touch Meute until the pin is bumped, and
Meute's dispatcher never destabilizes what you use to work interactively.

## 2. Non-negotiable constraints

- **Rootless Podman is the default and only runtime this repo targets.**
  docker-ce/container-use is a Meute-side concern for one optional
  capability — irrelevant here.
- `--cap-drop=ALL`, `--security-opt no-new-privileges`, no `$HOME` mounts,
  only the project directory bind-mounted.
- Network egress allow-listed at the container level — paired with the
  owner's existing firewall project, restricted to API hosts + `github.com`.
- Persistent containers use a no-op foreground process (`sleep infinity`) so
  `podman exec -it` can attach on demand without losing session state.

## 3. Repository structure

```
atelier/
├── docs/prp/atelier-prp.md       # this file
├── containers/
│   ├── agent-base/
│   │   └── Containerfile         # claude/codex/pi CLIs, git, gh, non-root user, egress hook
│   └── <project>/
│       └── Containerfile         # FROM agent-base, project-specific toolchain
├── scripts/
│   └── agent-enter.sh            # already drafted — reference implementation below
└── README.md
```

## 4. Phased build order

| Phase | Build agent | Review agent |
|---|---|---|
| 0 — Audit | Fable (interactive, owner present) | — |
| 1 — `agent-base` image | Sonnet (`claude -p`) | Codex (adversarial — defines the security posture every consumer inherits) |
| 2 — `agent-enter.sh` + per-project overlay convention | Sonnet (`claude -p`) | Codex (light pass — porting an existing reference implementation) |

**Phase 0 — Audit**
Answer the open questions below. Confirm or challenge the repo structure.

**Phase 1 — `agent-base` container image**
*Build: Sonnet. Review: Codex, adversarial — non-root user and base
security posture, treat as security-sensitive regardless of how small the
diff looks.*
Non-root user, pinned versions of `claude`, `codex`, `pi` + `pi-flow`,
`git`, `gh`. No toolchain-specific packages — those belong in per-project
overlay images. Include the egress allow-list hook point even if actual
firewall rules land later.

**Phase 2 — Entry mechanism and per-project overlay convention**
*Build: Sonnet. Review: Codex, light pass — reference implementation
already exists (Section 5); this is porting/adapting, not new design.*
Establish the `agent-<project>:latest` tagging convention per-project
Containerfiles build against, and wire in `agent-enter.sh` (three-layer
state machine: tmux session → container → shell, creating whichever layer
is missing).

## 5. Reference implementation already produced

**`scripts/agent-enter.sh`** — walks tmux-session → container → shell,
creating whichever layer is missing. Session exists → attach. Container
running → exec in. Neither → create fresh off `agent-<project>:latest`.
Available from the prior design session's outputs; request it rather than
re-deriving the logic from this description alone.

## 6. Open questions for Phase 0 audit

- Rebuild/drift cadence for persistent containers — fixed schedule, or
  triggered by a Containerfile change in that project?
- Image tag/version scheme — does Meute pin to a specific digest, or track
  `latest` and accept drift? (Answering this here, not in Meute's audit,
  since Atelier owns the tagging contract.)
- Registry — local-only (built on Tower, never pushed), or published to
  `ghcr.io/bearyjd/` alongside `bazzite-tower`, matching existing convention?
