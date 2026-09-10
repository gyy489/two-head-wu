# Provider provenance

The deployment contract targets OpenLIT `2.0.0`, published 2026-08-28.

- Upstream repository: https://github.com/openlit/openlit
- Upstream tag: `openlit-2.0.0`
- Upstream commit: `bd3e64519b25e55b564606625e29f89d80decf7e`
- OpenLIT arm64 image:
  `ghcr.io/openlit/openlit@sha256:13369868868680efee0fbbdf6a109b8229a364f02e3310ce28a0c6cd95f149e2`
- ClickHouse arm64 image:
  `clickhouse/clickhouse-server@sha256:4b14982a78c47d9ecc76ac3b13a0bfd2a31eed1f486fff6e944bcc5e08da2da9`
- ClickHouse tag associated with that digest: `24.4.1`
- Bundled Collector version in the OpenLIT image: `otelcol-contrib 0.142.0`

`clickhouse-init.sh` is an exact copy of
`assets/clickhouse-init.sh` at the upstream tag. The Compose file,
loopback bindings, trace-only collector pipeline, retention, privacy transform,
and storage mounts are Two-Headed-Wu integration configuration and intentionally
differ from OpenLIT's general-purpose example.

The pinned image's bundled `otelcol-contrib` also runs as a dedicated Compose
service. This isolates ingestion health from OpenLIT 2.0.0's UI-side OpAMP
supervisor without adding another provider or database.

Upgrade procedure:

1. select a released OpenLIT tag;
2. verify its commit and arm64 image digest;
3. refresh the exact initialization asset and record its checksum;
4. update the pinned provider/ClickHouse digests;
5. validate Collector config against the pinned image;
6. run fresh lifecycle, privacy, and bounded Codex ingestion acceptance tests.
