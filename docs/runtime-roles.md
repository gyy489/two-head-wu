# Runtime roles

The full system combines three distinct responsibilities. Keeping them separate is what makes the
architecture understandable and maintainable.

| Layer | Primary responsibility | Owns durable policy? | Required for this example? |
|---|---|---:|---:|
| OpenClaw | Persistent channels, scheduled tasks, background sessions, runtime integration | No | No |
| Codex | Interpret goals, reason about code, implement and operate within granted scope | No | No, but recommended for development |
| Two-Headed-Wu | Resolve capabilities, bindings, versions, interfaces, permissions, and recovery | Yes | The public contract and validator are included |

## OpenClaw: operational shell

OpenClaw keeps agent-facing channels and long-running workflows available beyond a single coding
session. In the complete personal system it is the host for persistent entry points, schedules,
and background execution. It calls Two-Headed-Wu through a thin integration and must not become the
only source of package or authorization facts.

## Codex: primary engine

Codex is the primary intelligent executor. It interprets a user's intent, chooses when a declared
capability is relevant, writes and reviews implementation code, and explains outcomes. It receives
bounded capability information from Two-Headed-Wu; it does not invent permissions or silently
expand the project scope.

Another reasoning runtime can replace Codex if it honors the same deterministic interface and
permission boundary. Codex is the primary choice, not an architectural singleton.

## Two-Headed-Wu: deterministic control plane

Two-Headed-Wu owns the stable facts used by every runtime:

- which capability packages and releases exist;
- which interfaces they expose;
- which projects and runtimes may use them;
- which filesystem, network, secret, and approval boundaries apply;
- how packages are tested, diagnosed, upgraded, and rolled back.

It does not perform open-ended reasoning. It narrows and validates the execution surface for the
agent that does.

## Graceful degradation

The public authoring workflow and hello example run without OpenClaw. If OpenClaw is absent, the
system loses its persistent channels, schedules, background sessions, and OpenClaw-specific
adapters—but manifest validation and standalone capability interfaces remain usable.

If Codex is absent, deterministic tools can still run directly, but the primary conversational
reasoning and implementation loop is absent. If a capability provider is absent, the resolver
should return an explicit unavailable result rather than falling through to an undeclared tool.
