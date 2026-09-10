# Architecture Notes

## Design goal

Two-Headed-Wu separates reasoning from infrastructure. An AI agent may interpret a user's goal,
but project scope, available capabilities, permissions, versions, and approval requirements come
from deterministic declarations.

## Resolution model

```text
Project + Agent + Runtime + Intent
                |
                v
        deterministic resolver
                |
                v
Project Binding + Capability Version + Allowed Interface + Approval Policy
```

Finding an installed component does not grant permission to execute it. Execution requires a
matching project binding, runtime exposure, interface declaration, data scope, and—where
applicable—human approval.

## Capability package

A capability is the unit of delivery and recovery. A package may contain Skills, adapters, MCP
servers, workflows, services, schemas, and tests, but exposes them through named stable
interfaces. Each package declares:

- identity and semantic version;
- exported interfaces;
- dependencies and compatibility;
- filesystem, network, and secret requirements;
- tests, recovery, and rollback behavior.

## State boundary

Source code and reproducible declarations may be public. Credentials, account bindings, personal
documents, conversations, databases, deployment targets, logs, and machine paths stay in
owner-controlled runtime storage. Public examples use placeholders and generated fixtures only.

## Repository strategy

The private development repository remains the integration source for the owner's complete system.
This public repository explains the architecture. Selected capabilities will be published only
after they can run independently without private configuration or data.
