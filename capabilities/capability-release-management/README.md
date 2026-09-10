# Capability Release Management

`0.1.1` adds trace-safe `wu invoke` observations containing only project, conversation,
Capability/Interface identity, success, and duration metadata; arguments and output are never emitted.

This package gives future projects a stable interface to versioned Capability releases. It keeps
discovery and bindings in Catalog, installs verified immutable slots under `var/`, and switches an
active project pointer only after manifest, permission, interface, digest, and smoke-test checks.

Existing projects are not opted in automatically. The `two-head-wu` project now has three explicit,
reviewed bindings for `research-library`, `research-ingestion`, and `local-translation`; their presence is a
project authorization fact, not an automatic opt-in rule.

The stable contract is `project + capability + runtime + interface`; callers never depend on an
Adapter's source path. A startup script, CI job, or existing scheduler can run the automatic update
command before invoking the interface. This package deliberately does not add a resident daemon.

## Commands

```bash
wu packages status --project <project> --json
wu packages resolve --project <project> --json
wu packages update --project <project>                 # dry-run
wu packages update --project <project> --capability <id> --to <version> --apply
wu packages update --project <project> --automatic     # scheduler dry-run
wu packages update --project <project> --automatic --apply
wu packages rollback --project <project> --capability <id> --to <version> --apply
wu invoke <capability> --project <project> --runtime <runtime> --interface <id> -- [args...]
```

`--apply` writes only beneath `WU_CAPABILITY_RELEASE_HOME`, or
`var/capability-releases/` by default. Discovery and installation do not grant invocation;
the legacy project registry must already authorize the package, and the V2 binding must allow the
runtime and interface.

## Release lifecycle

1. Register an immutable release and digest in `catalog/capability_releases.yaml`.
2. Add an opt-in project record to `catalog/project_capability_bindings.yaml`.
3. Preview resolution and update plans.
4. Apply the update. The manager copies or extracts into a temporary slot, verifies all contracts,
   runs registered smoke tests without a shell, then atomically replaces the active symlink.
5. An explicit `update --to` may preinstall any version still allowed by the binding; it cannot
   bypass the SemVer, interface, permission, runtime, or project checks.
6. Use explicit rollback to switch to a previously installed compatible slot.

An active pointer selects the Release for a new operation; it is not a durable job identity. Long-running
ingestion records the physical installed slots and content digests at job creation and resolves those exact slots on
resume. Switching the active pointer therefore affects new jobs only. Installed slots are intentionally retained—
there is no automatic garbage collection—because an unfinished job may still reference an older compatible Release.
If such a slot is missing or fails integrity verification, resume stops recoverably instead of substituting the active
Release.

Network artifact distribution and signatures are deliberately outside version 0.1. Local directory
and Git-tree sources are supported; Git-tree releases additionally verify the registered tree ID.

## Binding policies

| Policy | Selection | Automatic mode |
|---|---|---|
| `pinned` | One exact version | Always skipped |
| `compatible` | Highest available version satisfying the SemVer requirement | Runs only with `automatic: true` |
| `latest-stable` | Highest stable version satisfying the requirement | Runs only with `automatic: true` |

The release and binding must carry the same permission digest. Required interface versions and the
runtime must also remain inside the project's existing authorization. Changing any of those facts
requires a reviewed Catalog change; discovery alone never expands access.

## Runtime safety

Installed slots are content-addressed, made read-only, and checked again before status, update,
invocation, or rollback. Interface paths must stay inside the slot and be executable. Registered
smoke tests use argument arrays rather than a shell. Concurrent updates for one Capability share an
exclusive file lock, each smoke test has a 60-second default timeout, and activation uses an atomic
symlink replacement.

Directory digests exclude only known runtime/editor caches such as `__pycache__`, `.pytest_cache`,
`.DS_Store`, and bytecode/swap files. These are removed before a slot is frozen, and their later
appearance makes slot verification fail. Actual source, contracts, tests, and documentation remain
covered by the release digest. The digest is checked again after staging smoke tests, so a test that
accidentally mutates package content cannot install a release.

Version 0.1 executes registered Capability code with the current operating-system account; it is
not an OS sandbox. Capability permissions and smoke tests therefore remain reviewed source facts.
