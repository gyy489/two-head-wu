# OpenClaw integration

OpenClaw is required for the complete Two-Headed-Wu runtime experience: persistent channels,
scheduled tasks, background sessions, and OpenClaw-specific adapters. It is not required to read
the architecture, author packages, validate manifests, or run the standalone hello example.

## Prerequisite

Install OpenClaw by following the current instructions in the
[official OpenClaw repository](https://github.com/openclaw/openclaw). This project intentionally
does not duplicate version-sensitive OpenClaw installation commands.

Before integrating a capability, confirm that:

- OpenClaw itself starts and passes its own diagnostics;
- Codex or another intended reasoning runtime is configured;
- the Two-Headed-Wu integration has read access to public package declarations;
- private bindings and secret references are stored outside this repository;
- the selected capability explicitly lists OpenClaw as `native` or `compatible`.

## Integration contract

An OpenClaw integration should be a thin caller:

1. receive a user event or scheduled trigger;
2. ask Two-Headed-Wu to resolve the current project, runtime, and intent;
3. show or request any required approval;
4. invoke the returned Capability ID and Interface ID;
5. return structured output and retain only policy-compliant runtime evidence.

OpenClaw configuration must not become a second hidden capability catalog. Package identity,
interfaces, permissions, dependencies, and recovery remain in deterministic declarations.

## What happens without OpenClaw

Without OpenClaw, the persistent operational shell is unavailable. Standalone capability adapters,
tests, schemas, and validation still work. A project can integrate them directly or through another
runtime that honors the same binding and interface rules.

The complete private deployment is intentionally not reproducible from this public repository.
This guide defines the boundary needed to build a compatible integration without exposing private
state or owner-specific topology.
