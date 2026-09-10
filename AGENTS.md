# Two-Headed-Wu Public Agent Entry

Two-Headed-Wu is deterministic infrastructure. Keep open-ended reasoning in the current Agent session and use repository declarations for package identity, compatibility, permissions, and recovery.

Before a material change:

1. Confirm that the Git root is this repository, not its parent directory.
2. Read [the constitution](.specify/memory/constitution.md), [the public-edition boundary](docs/public-edition.md), and [the architecture](docs/architecture.md).
3. Run `core/bin/wu resolve --agent two-head-wu --runtime <runtime> --project two-head-wu --json`.
4. Read the affected package's `README.md`, `capability.yaml`, and tests before changing its implementation.
5. Treat package permissions and project bindings as hard boundaries. Discovering a Skill or adapter never grants execution authority.

Before completion:

1. Run `ruby tools/audit-foundation-platform` after changing packages, Catalog, registries, or documentation paths.
2. Run the affected package tests and the public Core resolution command.
3. Check that no credential, personal identifier, machine-specific path, private data, log, cache, or runtime state is staged.
4. Report the exact tests run and any dependency-bound test that could not run.

Do not edit generated runtime Skill surfaces, credentials, private knowledge, or unrelated user changes. Keep private bindings outside this repository and use synthetic fixtures in tests.
