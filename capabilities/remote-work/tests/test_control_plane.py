#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import importlib.util
import tempfile
import unittest
import uuid
import sys
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "server" / "control_plane.py"
sys.path.insert(0, str(SOURCE.parent))
SPEC = importlib.util.spec_from_file_location("two_head_wu_control_plane", SOURCE)
assert SPEC and SPEC.loader
CONTROL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTROL)


class RecoveryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="two-head-wu-control-")
        self.store = CONTROL.Store(Path(self.temporary.name))
        self.store.initialize()
        state = self.store.state()
        state.setdefault("devices", {})["dev-mac-mini-worker-test"] = {
            "name": "mac-mini-worker",
            "role": "mac-mini-worker",
            "secret": "test-only",
            "enabled": True,
            "capabilities": [
                "artifact-relay",
                "capability-adapters",
                "codex-job",
                "research-library-provider",
                "result-package",
            ],
            "protocol_min": CONTROL.PROTOCOL_VERSION,
            "protocol_max": CONTROL.PROTOCOL_VERSION,
            "last_seen_epoch": 1,
        }
        self.store.save_state(state)
        common = {
            "location": "mac-mini",
            "exposure": "callable",
            "status": "active",
            "queueable": True,
            "runtime_requires": ["research-library-provider"],
            "executor_kind": "tool",
            "capability_version": 1,
        }
        capabilities = [
            {
                **common,
                "id": "research-library:search",
                "name": "research search",
                "kind": "database-query",
                "invocation_policy": "auto",
                "side_effect": "read-only",
                "adapter": "research-library:search",
                "replay_class": "safe-read",
                "summary": "safe fixture search",
                "input_schema": {
                    "type": "object",
                    "required": ["query"],
                    "properties": {"query": {"type": "string", "maxLength": 2000}},
                    "additionalProperties": False,
                },
            },
            {
                **common,
                "id": "research-library:get",
                "name": "research get",
                "kind": "database-query",
                "invocation_policy": "auto",
                "side_effect": "read-only",
                "adapter": "research-library:get",
                "replay_class": "safe-read",
                "summary": "safe fixture get",
                "input_schema": {
                    "type": "object",
                    "required": ["work_id"],
                    "properties": {"work_id": {"type": "string", "maxLength": 36}},
                    "additionalProperties": False,
                },
            },
            {
                **common,
                "id": "research-library:export",
                "name": "research export",
                "kind": "artifact",
                "invocation_policy": "confirm",
                "side_effect": "external-write",
                "adapter": "research-library:export",
                "replay_class": "owner-confirmation-required",
                "summary": "safe fixture export",
                "runtime_requires": ["research-library-provider", "artifact-relay"],
                "input_schema": {
                    "type": "object",
                    "required": ["artifact_id", "expected_sha256"],
                    "properties": {
                        "artifact_id": {"type": "string", "maxLength": 36},
                        "expected_sha256": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                    },
                    "additionalProperties": False,
                },
            },
        ]
        CONTROL.write_json(
            self.store.capabilities_dir / "manifest.json",
            {
                "schema_version": 1,
                "catalog_version": "0" * 16,
                "capabilities": capabilities,
                "public_key_sha256": "0" * 64,
                "signature_base64": "test-only",
            },
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def create_job(self) -> dict:
        capsule = b"safe isolated capsule"
        return self.store.create_job(
            "dev-owner-air-test0001",
            {
                "instruction": "test recovery",
                "identity": "owner-auto",
                "project_name": "test",
                "capsule_sha256": hashlib.sha256(capsule).hexdigest(),
                "capsule_base64": base64.b64encode(capsule).decode(),
            },
        )

    def test_owner_v1_state_and_member_v2_registry_are_parallel(self) -> None:
        member = self.store.member_registry.create_user("member-a", user_id="usr-control-a001")
        self.assertEqual(member["role"], "member")
        self.assertEqual(self.store.state()["schema_version"], 1)
        self.assertNotIn("users", self.store.state())
        self.assertEqual(self.store.member_registry.read()["schema_version"], 2)

    def test_worker_member_lease_uses_server_side_codex_binding(self) -> None:
        registry = self.store.member_registry
        provisioned = registry.provision_member("member worker", "member-worker")
        user_id = provisioned["user"]["id"]
        key = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEyKWHzxMxEPT3pigkiU6Ulr/7ZoQWb6wzYTPi87DwlX25aO/ggHinoA6xyVTOAStkdlcx5E8JTA0dqYFfkOTwRg=="
        device = registry.enroll_device(
            user_id, platform="macos", key_provider="secure-enclave",
            public_key_spki_base64=key, device_id="dev-member-worker-air",
        )
        registry.put_grant(user_id, "codex:project-task", ["project-read"], grant_id="grant-member-worker")
        job = registry.create_member_job(
            user_id, device["id"], "call-dddddddddddddddddddddddd",
            "worker identity routing", ["codex:project-task"],
        )
        leased = registry.lease_member_job("dev-mac-mini-worker-test", now_epoch=100)
        assert leased
        self.assertEqual(leased["job"]["id"], job["id"])
        self.assertEqual(leased["identity_alias"], "member-worker")
        failed = registry.transition_member_job(
            "dev-mac-mini-worker-test", job["id"], leased["job"]["execution_lease_id"],
            "failed", failure_code="identity_required", now_epoch=101,
        )
        self.assertEqual(failed["failure_code"], "identity_required")

    def test_legacy_air_identity_is_normalized_to_owner_auto(self) -> None:
        capsule = b"legacy signed Air capsule"
        created = self.store.create_job(
            "dev-owner-air-test0001",
            {
                "instruction": "test compatible rollout",
                "identity": "owner-primary",
                "project_name": "test",
                "capsule_sha256": hashlib.sha256(capsule).hexdigest(),
                "capsule_base64": base64.b64encode(capsule).decode(),
            },
        )
        self.assertEqual(created["identity"], "owner-auto")

        with self.assertRaises(CONTROL.ControlPlaneError):
            self.store.create_job(
                "dev-owner-air-test0001",
                {
                    "instruction": "do not route classmates automatically",
                    "identity": "classmate",
                    "project_name": "test",
                    "capsule_sha256": hashlib.sha256(capsule).hexdigest(),
                    "capsule_base64": base64.b64encode(capsule).decode(),
                },
            )

    def expire_running_lease(self, job_id: str) -> dict:
        job = self.store.job(job_id)
        job["state"] = "running"
        job["lease_expires_at"] = 0
        self.store.save_job(job)
        return job

    def test_safe_stale_attempt_is_requeued_with_a_new_lease(self) -> None:
        created = self.create_job()
        first = self.store.lease("dev-mac-mini-worker-test")
        assert first
        old_lease = first["job"]["lease_id"]
        self.expire_running_lease(created["id"])

        second = self.store.lease("dev-mac-mini-worker-test")
        assert second
        self.assertEqual(second["job"]["id"], created["id"])
        self.assertEqual(second["job"]["attempt"], 2)
        self.assertNotEqual(second["job"]["lease_id"], old_lease)
        with self.assertRaises(CONTROL.ControlPlaneError):
            self.store.heartbeat("dev-mac-mini-worker-test", created["id"], old_lease)

    def test_privileged_attempt_requires_owner_retry(self) -> None:
        created = self.create_job()
        leased = self.store.lease("dev-mac-mini-worker-test")
        assert leased
        self.expire_running_lease(created["id"])
        interaction = self.store.create_interaction(
            created["id"],
            {"kind": "command-approval", "prompt": {"title": "test", "command": "test"}},
        )
        self.store.reply_interaction(created["id"], interaction["id"], {"decision": "accept"})
        stale = self.store.job(created["id"])
        stale["lease_expires_at"] = 0
        self.store.save_job(stale)

        self.assertIsNone(self.store.lease("dev-mac-mini-worker-test"))
        failed = self.store.job(created["id"])
        self.assertEqual(failed["state"], "failed")
        self.assertEqual(failed["recovery_state"], "manual_retry_required")
        retried = self.store.retry_job(created["id"])
        self.assertEqual(retried["state"], "queued")
        self.assertEqual(retried["manual_retry_count"], 1)

    def test_confirmation_class_never_replays_automatically(self) -> None:
        created = self.create_job()
        leased = self.store.lease("dev-mac-mini-worker-test")
        assert leased
        stale = self.expire_running_lease(created["id"])
        stale["replay_class"] = "owner-confirmation-required"
        self.store.save_job(stale)

        self.assertIsNone(self.store.lease("dev-mac-mini-worker-test"))
        failed = self.store.job(created["id"])
        self.assertEqual(failed["state"], "failed")
        self.assertEqual(failed["recovery_state"], "manual_retry_required")

    def test_incompatible_worker_does_not_lease_work(self) -> None:
        created = self.create_job()
        state = self.store.state()
        state["devices"]["dev-mac-mini-worker-test"]["protocol_max"] = CONTROL.PROTOCOL_VERSION - 1
        self.store.save_state(state)
        self.assertIsNone(self.store.lease("dev-mac-mini-worker-test"))
        self.assertEqual(self.store.job(created["id"])["state"], "queued")

    def test_project_delta_is_scoped_to_the_job_lease(self) -> None:
        created = self.create_job()
        content = b"updated from Air\n"
        delta = self.store.append_project_delta(
            created["id"],
            created["project_lease_id"],
            [{
                "path": "README.md",
                "operation": "upsert",
                "base_sha256": None,
                "sha256": hashlib.sha256(content).hexdigest(),
                "content_base64": base64.b64encode(content).decode(),
            }],
        )
        self.assertEqual(delta["sequence"], 1)
        self.assertEqual(self.store.project_deltas(created["id"], 0)[0]["entries"][0]["path"], "README.md")
        with self.assertRaises(CONTROL.ControlPlaneError):
            self.store.append_project_delta(created["id"], "project-" + "0" * 24, [])

    def create_research_export_job(self, *, request_suffix: str = "1") -> dict:
        return self.store.create_capability_job(
            "dev-owner-air-test0001",
            "research-library:export",
            {
                "request_id": "call-" + request_suffix.rjust(24, "0"),
                "owner_confirmed": True,
                "input": {
                    "artifact_id": str(uuid.UUID("00000000-0000-4000-8000-000000000010")),
                    "expected_sha256": "a" * 64,
                },
            },
        )

    def lease_running(self, job_id: str) -> tuple[dict, str]:
        leased = self.store.lease("dev-mac-mini-worker-test")
        assert leased and leased["job"]["id"] == job_id
        lease_id = leased["job"]["lease_id"]
        job = self.store.job(job_id)
        job["state"] = "running"
        self.store.save_job(job)
        return job, lease_id

    def test_research_export_reuses_owner_artifact_relay(self) -> None:
        created = self.create_research_export_job()
        _job, lease_id = self.lease_running(created["id"])
        content = b"complete selected research document\n"
        artifact = self.store.create_job_output_artifact(
            "dev-mac-mini-worker-test",
            created["id"],
            lease_id,
            {
                "request_id": "call-" + "a" * 24,
                "filename": "research-fixture.md",
                "media_type": "text/markdown",
                "sha256": hashlib.sha256(content).hexdigest(),
                "content_base64": base64.b64encode(content).decode(),
            },
        )
        self.assertEqual(artifact["device_id"], "dev-owner-air-test0001")
        self.assertEqual(
            self.store.artifact_dir(artifact["id"]).joinpath("content.bin").read_bytes(), content
        )
        attached = CONTROL.public_job(self.store.job(created["id"]))["output_artifact_ids"]
        self.assertEqual(attached, [artifact["id"]])
        self.assertEqual(CONTROL.public_artifact(artifact)["schema_version"], 1)
        self.assertEqual(
            self.store.resolve_job_artifacts("dev-owner-air-test0001", [artifact["id"]])[0]["id"],
            artifact["id"],
        )
        with self.assertRaises(CONTROL.ControlPlaneError) as denied:
            self.store.resolve_job_artifacts("dev-owner-air-not-owner", [artifact["id"]])
        self.assertEqual(denied.exception.status, 403)

    def test_research_capability_rejects_confirmation_and_schema_injection(self) -> None:
        work_id = "00000000-0000-4000-8000-000000000011"
        artifact_id = "00000000-0000-4000-8000-000000000010"
        for unavailable in ("research-library:bulk", "research-library:rejections"):
            with self.subTest(unavailable=unavailable):
                with self.assertRaises(CONTROL.ControlPlaneError) as absent:
                    self.store.create_capability_job(
                        "dev-owner-air-test0001", unavailable, {"input": {}}
                    )
                self.assertEqual(absent.exception.status, 404)

        with self.assertRaises(CONTROL.ControlPlaneError) as confirmation:
            self.store.create_capability_job(
                "dev-owner-air-test0001",
                "research-library:export",
                {"input": {"artifact_id": artifact_id, "expected_sha256": "a" * 64}},
            )
        self.assertEqual(confirmation.exception.status, 403)

        for capability_id, capability_input in [
            ("research-library:search", {"query": "archive", "database": "/private/library.sqlite3"}),
            ("research-library:get", {"work_id": work_id, "path": "/private/document.pdf"}),
            (
                "research-library:export",
                {"artifact_id": artifact_id, "expected_sha256": "a" * 64, "raw_path": "/private/document.pdf"},
            ),
        ]:
            with self.subTest(capability_id=capability_id):
                with self.assertRaises(CONTROL.ControlPlaneError) as rejected:
                    self.store.create_capability_job(
                        "dev-owner-air-test0001",
                        capability_id,
                        {"owner_confirmed": True, "input": capability_input},
                    )
                self.assertIn("unknown fields", str(rejected.exception))

    def test_research_output_rejects_wrong_worker_and_over_limit_without_chunking(self) -> None:
        created = self.create_research_export_job(request_suffix="2")
        _job, lease_id = self.lease_running(created["id"])
        content = b"123456789"
        payload = {
            "request_id": "call-" + "b" * 24,
            "filename": "research-fixture.md",
            "media_type": "text/markdown",
            "sha256": hashlib.sha256(content).hexdigest(),
            "content_base64": base64.b64encode(content).decode(),
        }
        with self.assertRaises(CONTROL.ControlPlaneError) as wrong_worker:
            self.store.create_job_output_artifact("dev-other-worker", created["id"], lease_id, payload)
        self.assertEqual(wrong_worker.exception.status, 403)

        previous_maximum = CONTROL.MAX_ARTIFACT
        CONTROL.MAX_ARTIFACT = 8
        try:
            with self.assertRaises(CONTROL.ControlPlaneError) as oversized:
                self.store.create_job_output_artifact(
                    "dev-mac-mini-worker-test", created["id"], lease_id, payload
                )
            self.assertEqual(oversized.exception.status, 413)
            self.assertIn("too large", str(oversized.exception))
            self.assertNotIn("output_artifact_ids", self.store.job(created["id"]))
        finally:
            CONTROL.MAX_ARTIFACT = previous_maximum


if __name__ == "__main__":
    unittest.main()
