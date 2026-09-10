<!--
Sync Impact Report
- Version change: template → 1.0.0
- Added principles: deterministic infrastructure; four-part ownership; capability-first
  packaging; least privilege; authoritative data isolation; portability and compatibility;
  evidence-based completion
- Added sections: Security and System Boundaries; Development Workflow and Quality Gates
- Removed sections: none; template placeholders were fully resolved
- Follow-up TODOs: none
-->

# Two-Headed-Wu Constitution

## Core Principles

### I. Deterministic Infrastructure, External Intelligence

Two-Headed-Wu MUST remain deterministic infrastructure rather than a reasoning Agent. The Core
MUST NOT use model inference to decide permissions, resource ownership, or whether an action is
allowed. Codex is the primary reasoning and implementation runtime; Claude Code is a replaceable
fallback; OpenClaw provides persistent channels, schedules, and background execution. Reasoning
remains with the current caller, while Two-Headed-Wu returns declared facts and allowed interfaces.

### II. Four-Part Ownership Is Mandatory

Every new runtime responsibility MUST have one authoritative home:

- `core/` owns stable deterministic commands, contracts, validation, and policy enforcement.
- `catalog/` owns indexes and references to projects, resources, policies, deployments, packages,
  and workflows; it MUST NOT duplicate external source data.
- `capabilities/` owns reusable delivery units containing optional Skills, Agents, adapters,
  workflows, and tests.
- `var/` owns generated state, cache, runtime contexts, logs, and other rebuildable local data.

`docs/`, `development/`, and `specs/` document the system and its evolution; they MUST NOT become
an undeclared runtime source of truth.

### III. Capability-First Packaging and Stable Interfaces

A reusable function that combines instructions, executable tools, adapters, workflows, or
permissions MUST be represented as a versioned capability package. A Skill is an instruction
interface and MUST NOT be treated as executable authorization. Capability packages MUST declare
their dependencies, exported interfaces, compatibility, requested permissions, tests, and
recovery expectations. Callers MUST resolve allowed capabilities through `wu` instead of relying
on remembered paths or copying implementation details into project prompts.

### IV. Least Privilege and Explicit Approval

Plaintext passwords, tokens, private keys, browser password stores, and unrelated personal data
MUST NOT enter source control, Catalog records, Agent prompts, logs, reports, or generated
deployment packages. Catalog entries MAY store provider references such as Apple Keychain or a
future vault identifier. Installed or discoverable capabilities grant no permission by themselves;
project policy, Agent allowlists, runtime exposure, data scope, and action approval MUST all agree.
Destructive actions, external writes, deployments, account changes, and cross-project data access
MUST require an explicit declared policy and the configured human approval gate.

### V. Authoritative Data Stays Isolated

Project source, papers, personal records, customer data, and vector databases MUST remain in their
authoritative systems or dedicated encrypted storage. Two-Headed-Wu stores their location,
classification, owner, and access rules, not unnecessary copies. Personal, customer, and
cross-customer data spaces MUST be isolated. A deployment profile MUST export only the minimum
Agents, capabilities, resource bindings, and policies required for that deployment.

### VI. Portability, Versioning, and Compatibility

Every managed external dependency MUST have enough metadata to reconstruct it: source, pinned or
accepted version, installation method, configuration boundary, and health check. Generated runtime
surfaces MUST be rebuildable from canonical sources and registries. Path moves, contract changes,
Skill reclassification, and runtime migrations MUST include affected references, compatibility
handling, validation, and rollback instructions. Existing working interfaces MUST NOT be removed
until their replacement has passed an end-to-end migration test.

### VII. Evidence Before Completion

No structural, capability, security, or deployment change is complete without proportionate
verification. At minimum, changed contracts and commands MUST have tests; registry and runtime
changes MUST pass `wu doctor`; Agent and Skill topology changes MUST pass the strict cartographer
audit. Logs and reports MUST record outcomes without secret values. Claims of success MUST cite the
command, test, generated audit, or other reproducible evidence that supports them.

## Security and System Boundaries

- The Git repository MUST contain reproducible source, declarations, documentation, specifications,
  and tests only. Machine environments, dependency installations, generated runtime state, private
  knowledge, account bindings, credentials, and logs MUST remain ignored or outside the repository.
- Third-party source checkouts MAY remain beside the project for local use, but the repository MUST
  track a manifest containing the upstream source and pinned revision instead of an accidental
  embedded Git repository.
- Project-local development tooling, including Spec Kit generated Agent Skills, MUST stay scoped to
  the project by default. Two-Headed-Wu MAY manage its installation and health checks without
  exposing those Skills through the global shared Skill surface.
- New Skills MUST enter through the declared lifecycle: inbox, source classification, audit,
  explicit approval, registry update, activation, and generated runtime surfaces.
- Skill source location MUST primarily express provenance: official provider, personal, or audited
  third party. Domain, risk, permissions, and project applicability MUST be registry metadata rather
  than competing directory taxonomies.

## Development Workflow and Quality Gates

1. Establish a clean local Git baseline before a structural migration; no remote publication is
   implied by a local commit.
2. Every material feature or migration MUST have a Spec Kit specification with bounded scope,
   independently testable user scenarios, functional requirements, and measurable success criteria.
3. Planning MUST identify affected authoritative files, compatibility surfaces, security impact,
   migration stages, rollback, and validation commands before implementation.
4. Tasks MUST be ordered, reference exact project-relative paths, and map to requirements or user
   stories. Unresolved constitution conflicts block implementation.
5. Implementation MUST preserve unrelated user changes and MUST NOT move runtime directories merely
   for visual cleanliness. Migrations proceed in independently verifiable stages.
6. Completion requires applicable tests, Spec Kit consistency analysis, `wu doctor`, strict topology
   audit, an updated development report, and a reviewable Git diff.
7. Architecture decisions with long-term consequences MUST be recorded under
   `development/decisions/`; feature artifacts live under `specs/`; milestone and validation results
   live under `development/reports/`.

## Governance

This constitution is the highest project-level development policy. Specifications, plans, tasks,
capability manifests, scripts, and documentation MUST comply with it. Amendments require an explicit
rationale, an impact statement, a migration or compatibility note when applicable, and a recorded
change in Git.

Constitution versions follow semantic versioning: MAJOR for incompatible principle removal or
redefinition, MINOR for a new principle or materially expanded obligation, and PATCH for
clarification that does not change obligations. Every feature plan and final review MUST perform a
constitution check. Exceptions MUST be documented before implementation, limited in duration and
scope, and approved by the owner; undocumented exceptions are invalid.

**Version**: 1.0.0 | **Ratified**: 2026-08-11 | **Last Amended**: 2026-08-11
