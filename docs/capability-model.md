# Capability model

A capability package is a complete, versioned unit of functionality. A Skill is one possible
component of a capability; it is not the universal container for code, services, data, or runtime
permissions.

## Package layout

```text
capabilities/<capability-id>/
├── capability.yaml   identity, interfaces, compatibility, permissions, recovery
├── skills/           optional instructions for intelligent executors
├── agents/           optional reusable agent definitions
├── adapters/         optional deterministic program entry points
├── workflows/        optional repeatable multi-step operations
└── tests/            health, compatibility, and acceptance checks
```

Only `capability.yaml` is structurally mandatory. A package adds the component directories it
actually needs; visual symmetry is not a design goal.

## Manifest contract

The public contract is [capability.schema.yaml](../schemas/capability.schema.yaml). Every package
declares:

- a stable lowercase ID and semantic version;
- status, summary, and documentation paths;
- installation ownership and runtime mode;
- named interfaces and their entry points;
- owned or referenced components;
- runtime compatibility;
- filesystem, network, secret, and risk boundaries;
- declared capability dependencies;
- source of truth, rebuild behavior, and rollback;
- executable acceptance tests.

## Interfaces over implementation paths

Callers identify `hello-capability` and `hello.greet.v1`; they do not depend on the package's
private class names. The package may later replace its adapter implementation while retaining the
interface contract.

An interface ID should be stable and versioned. A breaking request or response change receives a
new interface version. A package version may change without breaking an interface.

## Dependencies

Dependencies are allowed when they are explicit and narrow. Each dependency names another
capability and a compatible version range, plus a short purpose. Dependency graphs must remain
acyclic. A package must not read another package's private files or mutable state.

An optional provider should be represented in the compatibility or binding layer and produce a
clear degraded result when missing. Hidden fallback to a broader tool undermines authorization.

## Permissions are descriptive and enforceable

The manifest declares required network, secret, and filesystem access. A declaration does not by
itself grant access: the project binding and runtime policy must also allow it. High-risk actions
should require an explicit approval gate close to execution.

## Independent lifecycle test

A package is meaningfully decoupled when it can be:

1. validated and tested on its own;
2. released and versioned without changing unrelated packages;
3. disabled or removed while unrelated capabilities keep working;
4. replaced behind its stable interfaces;
5. rolled back to a previously verified version;
6. operated without copying secrets or private runtime state into source.

The included [hello capability](../examples/hello-capability/README.md) is deliberately small, so
the contract is visible without production complexity.
