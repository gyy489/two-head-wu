# Build a capability

This workflow turns the included hello package into a new independently testable capability.

## 1. Copy the package skeleton

```bash
cp -R examples/hello-capability examples/my-capability
```

Rename the package ID, interface ID, summary, and implementation. IDs use lowercase words joined
with hyphens; interface IDs should be namespaced and versioned, for example
`my-capability.run.v1`.

## 2. Declare the contract

Edit `capability.yaml` before expanding the implementation. State the real runtime compatibility,
permissions, dependencies, tests, and recovery method. Do not mark an integration as compatible
until its acceptance test passes.

Use [the public schema](../schemas/capability.schema.yaml) as the full field reference and compare
your manifest with [the runnable example](../examples/hello-capability/capability.yaml).

## 3. Implement through a stable interface

Place deterministic code in `adapters/` or `workflows/`; put model-facing instructions in
`skills/`. The interface entry point is part of the contract, while internal modules remain package
private. Structured JSON input/output is recommended for programmatic adapters.

## 4. Keep private material outside the package

Use symbolic references such as `env://SERVICE_TOKEN` in deployment configuration. Never commit
secret values, personal data, machine-specific absolute paths, logs, caches, or live account
bindings. Synthetic fixtures belong in tests.

## 5. Validate and test

```bash
ruby tools/validate-capability examples/my-capability/capability.yaml
examples/my-capability/tests/test_hello.sh
```

The included validator checks the package-level invariants needed for the starter workflow. The
JSON Schema remains the normative contract; production environments should additionally validate
against it and enforce project bindings at invocation time.

## 6. Integrate with a project

Create a binding like [project-binding.yaml](../examples/project-binding.yaml). A binding selects a
capability, release policy, compatible runtimes, and the precise interfaces available to that
project. Merely installing the package is not authorization.

## 7. Prepare a release

Before publishing:

- run all declared tests from a clean clone;
- review network, filesystem, secret, and approval requirements;
- verify every documentation and entry-point path;
- check that disabling the package does not break unrelated capabilities;
- record a practical rollback path;
- scan the diff for credentials and private operational information.

If OpenClaw hosts the capability, continue with [OpenClaw setup](openclaw-setup.md).
