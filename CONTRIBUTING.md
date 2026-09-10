# Contributing

Contributions that clarify the architecture, strengthen deterministic validation, or improve the
public example are welcome.

Before opening a pull request:

1. keep private data, credentials, account bindings, and machine-specific state out of the change;
2. preserve the separation between OpenClaw, Codex, and Two-Headed-Wu responsibilities;
3. declare capability dependencies and permissions explicitly;
4. run `ruby tools/validate-capability examples/hello-capability/capability.yaml`;
5. run `examples/hello-capability/tests/test_hello.sh`;
6. explain any interface-breaking change and provide a migration path.

New production capabilities are usually better published as separate repositories after they can
be tested without the owner's private environment. This repository stays focused on the shared
architecture and authoring contract.
