# Hello capability

This package demonstrates the smallest useful Two-Headed-Wu delivery unit: a manifest, one stable
interface, a deterministic adapter, and an acceptance test.

```bash
ruby tools/validate-capability examples/hello-capability/capability.yaml
examples/hello-capability/tests/test_hello.sh
examples/hello-capability/adapters/hello --name Ada
```

The adapter emits JSON and performs no network access, secret access, or filesystem writes. It can
run directly, from Codex, or behind an OpenClaw integration that honors `hello.greet.v1`.

The example is intentionally not a showcase feature. Its purpose is to make package structure,
interface stability, testability, and runtime independence easy to inspect.
