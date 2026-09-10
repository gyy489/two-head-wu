# Security boundary

Public capability packages should be useful without disclosing the operator's private environment.

## Safe to publish

- architecture and interface documentation;
- sanitized schemas and manifests;
- deterministic source code whose dependencies are public;
- synthetic fixtures and tests;
- permission requirements and approval behavior;
- reproducible build, validation, recovery, and rollback instructions.

## Keep private

- passwords, tokens, cookies, private keys, and recovery codes;
- personal memory, conversations, documents, and customer data;
- account identifiers and live resource bindings;
- private server names, addresses, tunnels, and deployment topology;
- absolute machine paths, device identifiers, logs, caches, and runtime state;
- capabilities that cannot yet be separated from private data or privileged infrastructure.

## Secret references

A declaration may state that a secret is required and refer to it symbolically, for example
`env://SERVICE_TOKEN` or a platform secret-store URI. The reference identifies how the runtime
obtains the value; it is not the value itself. Tests must use synthetic values.

## Authorization

Discovery, installation, and model awareness do not grant authorization. Execution requires an
allowed project binding, runtime, interface, data scope, and approval policy. A capability should
fail closed when any required declaration is missing.

## Reporting

Do not open a public issue containing a credential or private operational detail. Use GitHub's
private vulnerability reporting channel when enabled, or contact the repository owner privately.
See the repository-level [security policy](../SECURITY.md).
