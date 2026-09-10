# Spec Kit Governance Capability

This package lets Two-Headed-Wu discover and validate the GitHub Spec Kit installation used to
govern this project. It owns installation facts, scope, recovery guidance, the machine-readable
Change Capsule contract, and deterministic read-only validators. Spec Kit remains the owner of
files under `.specify/`, `.agents/skills/`, and `.claude/skills/`.

## Scope

- Codex is the default project integration.
- Claude Code is the compatible fallback integration.
- Generated `speckit-*` Skills are project-local and are never synchronized into
  `skills/.active` by this package.
- OpenClaw does not receive this development capability.
- The adapters perform no network request, installation, update, credential access, or file write.
- A worktree normally has one Change Capsule in `in-progress` or `review` state. When history contains
  another active Capsule from parallel development, `.specify/feature.json` must select the one owned by
  this worktree; all Capsules are still schema-validated, but only the selected Capsule governs its diff.
- Active and planned Capsules must reference modules in the current Project Map; completed or
  cancelled Capsules may retain retired module IDs as historical migration evidence.
- Staged paths outside `writable_paths`, forbidden paths, oversized commits, and undeclared
  cross-capability changes fail before commit.

## Interface

```bash
capabilities/spec-kit-governance/adapters/spec-kit-governance status
capabilities/spec-kit-governance/adapters/spec-kit-governance doctor
capabilities/spec-kit-governance/adapters/change-governance status
capabilities/spec-kit-governance/adapters/change-governance validate --change specs/<id>/change.yaml
capabilities/spec-kit-governance/adapters/change-governance gate --scope staged
core/bin/wu run spec-kit-health
core/bin/wu 变更检查 status
```

The command contract is documented in
`specs/001-project-structure-governance/contracts/spec-kit-governance-cli.md`.
The large-project governance design and authoring flow are documented in
`specs/004-ai-project-change-governance/spec.md` and its
`quickstart.md`; the YAML contract is
`capabilities/spec-kit-governance/contracts/change-capsule.schema.yaml`.

## Recovery

The accepted CLI version is recorded in `.specify/init-options.json`. To reconstruct the current
project integration on a machine with `uv` and Git:

```bash
uv tool install specify-cli==0.16.2
specify init --here --force --integration codex --integration-options="--skills"
specify integration install claude
capabilities/spec-kit-governance/adapters/spec-kit-governance doctor
```

Recovery must preserve the project constitution, feature specifications, and `change.yaml`
capsules. Review the Git diff
before accepting regenerated integration files. Do not install optional extensions, presets, or
bundles unless a later specification explicitly approves them.
