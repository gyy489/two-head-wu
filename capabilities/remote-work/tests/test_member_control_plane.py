#!/usr/bin/env python3
from __future__ import annotations

import http.client
import base64
import hashlib
import hmac
import importlib.util
import json
import secrets
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT / "server"
sys.path.insert(0, str(SERVER_DIR))
SPEC = importlib.util.spec_from_file_location("member_v2_control_plane", SERVER_DIR / "control_plane.py")
assert SPEC and SPEC.loader
CONTROL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTROL)


class MemberControlPlaneTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="two-head-wu-member-http-")
        self.store = CONTROL.Store(Path(self.temporary.name))
        self.store.initialize()
        owner_state = self.store.state()
        owner_state.setdefault("devices", {})["dev-member-worker-test"] = {
            "name": "air-worker", "role": "mac-mini-air-worker", "secret": "worker-test-secret",
            "enabled": True, "last_seen_epoch": int(time.time()),
        }
        owner_state["devices"]["dev-owner-worker-test"] = {
            "name": "owner-worker", "role": "mac-mini-worker", "secret": "owner-worker-test-secret",
            "enabled": True, "last_seen_epoch": int(time.time()),
        }
        self.store.save_state(owner_state)
        CONTROL.write_json(
            self.store.capabilities_dir / "air-manifest.json",
            {
                "schema_version": 1,
                "catalog_version": "a" * 16,
                "generated_at": "2026-09-01T00:00:00Z",
                "capabilities": [
                    {
                        "id": "codex:project-task", "name": "member codex", "kind": "codex-task",
                        "location": "mac-mini", "exposure": "callable", "status": "active",
                        "invocation_policy": "queue", "side_effect": "isolated-write", "queueable": True,
                        "runtime_requires": ["codex-job"], "summary": "member-scoped project task",
                    },
                    {
                        "id": "research-library:search", "name": "member research", "kind": "database-query",
                        "location": "mac-mini", "exposure": "callable", "status": "active",
                        "invocation_policy": "auto", "side_effect": "read-only", "queueable": True,
                        "runtime_requires": ["research-library-provider"], "summary": "member research search",
                        "input_schema": {
                            "type": "object", "required": ["query"],
                            "properties": {
                                "query": {"type": "string", "maxLength": 2000},
                                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                            },
                            "additionalProperties": False,
                        },
                    },
                    {
                        "id": "research-library:get", "name": "member research get", "kind": "database-query",
                        "location": "mac-mini", "exposure": "callable", "status": "active",
                        "invocation_policy": "auto", "side_effect": "read-only", "queueable": True,
                        "runtime_requires": ["research-library-provider"], "summary": "member research metadata",
                        "input_schema": {
                            "type": "object", "required": ["work_id"],
                            "properties": {
                                "work_id": {"type": "string", "pattern": "^[0-9a-fA-F-]{36}$"},
                                "version": {"type": "string", "maxLength": 36},
                            },
                            "additionalProperties": False,
                        },
                    },
                    {
                        "id": "tool:codex-status", "name": "member Codex status", "kind": "tool",
                        "location": "mac-mini", "exposure": "callable", "status": "active",
                        "invocation_policy": "auto", "side_effect": "read-only", "queueable": True,
                        "runtime_requires": ["codex-status"], "summary": "member's own Codex quota only",
                        "input_schema": {"type": "object", "additionalProperties": False},
                    },
                ],
                "public_key_sha256": "b" * 64,
                "signature_base64": "fixture-signature",
            },
        )
        owner_catalog = CONTROL.read_json(self.store.capabilities_dir / "air-manifest.json")
        owner_catalog["capabilities"].append(
            {
                "id": "memory:notebook", "name": "owner notebook", "kind": "memory",
                "location": "mac-mini", "exposure": "callable", "status": "active",
                "invocation_policy": "queue", "side_effect": "local-write", "queueable": True,
                "runtime_requires": ["protected-owner-adapter"], "summary": "owner-only exact notebook",
                "audience": "owner-air", "confirmation": "none", "executor": "protected-adapter",
                "input_schema": {
                    "type": "object", "required": ["action"],
                    "properties": {
                        "action": {"type": "string", "enum": ["recall", "remember", "correct", "forget"]},
                        "query": {"type": "string", "maxLength": 2000},
                    },
                    "additionalProperties": False,
                },
            }
        )
        owner_catalog["capabilities"].append(
            {
                "id": "workflow:publish-site", "name": "owner protected publish", "kind": "workflow",
                "location": "mac-mini", "exposure": "callable", "status": "active",
                "invocation_policy": "confirm", "side_effect": "external-write", "queueable": True,
                "runtime_requires": ["protected-owner-adapter", "site-publisher"],
                "summary": "fixture owner step-up capability",
                "audience": "owner-step-up", "confirmation": "owner-password", "executor": "protected-adapter",
                "input_schema": {
                    "type": "object", "required": ["project_id", "site_id", "artifact_sha256"],
                    "properties": {
                        "project_id": {"type": "string", "pattern": "^[a-z][a-z0-9-]{0,62}$"},
                        "site_id": {"type": "string", "enum": ["private-site", "public-site"]},
                        "artifact_sha256": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                    },
                    "additionalProperties": False,
                },
            }
        )
        owner_catalog["signature_base64"] = "fixture-owner-signature"
        CONTROL.write_json(self.store.capabilities_dir / "owner-air-manifest.json", owner_catalog)
        self.module_archive = b"member-paper-writing-skill"
        self.module_version = "1" * 16
        self.module_archive_name = f"skill-paper-writing-{self.module_version}.tar.gz"
        CONTROL.atomic_write(self.store.components_dir / self.module_archive_name, self.module_archive, 0o640)
        CONTROL.write_json(
            self.store.components_dir / "air-manifest.json",
            {
                "schema_version": 2,
                "generated_at": "2026-09-01T00:00:00Z",
                "modules": [
                    {
                        "id": "skill:paper-writing", "classification": "portable", "status": "active",
                        "summary": "member paper writing", "default_mode": "local",
                        "version": self.module_version, "archive": self.module_archive_name,
                        "sha256": hashlib.sha256(self.module_archive).hexdigest(), "size": len(self.module_archive),
                        "versions": [
                            {
                                "version": self.module_version, "archive": self.module_archive_name,
                                "sha256": hashlib.sha256(self.module_archive).hexdigest(), "size": len(self.module_archive),
                            },
                        ],
                    },
                    {
                        "id": "skill:paper-navigator", "classification": "portable", "status": "active",
                        "summary": "member paper navigator", "default_mode": "local",
                        "version": "2" * 16, "archive": f"skill-paper-navigator-{'2' * 16}.tar.gz",
                        "sha256": "2" * 64, "size": 12,
                    },
                ],
                "public_key_sha256": "c" * 64,
                "signature_base64": "fixture-module-signature",
            },
        )
        self.registry = self.store.member_registry
        key_a = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEyKWHzxMxEPT3pigkiU6Ulr/7ZoQWb6wzYTPi87DwlX25aO/ggHinoA6xyVTOAStkdlcx5E8JTA0dqYFfkOTwRg=="
        key_b = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEn2eKrYafjlY3pPukUre+yc1h671d5aznnBY/pjeWTvLLZcLBWdVhXV9Fpmfu6fl90v3I/paME/WWUH1LXmeYog=="
        for suffix, platform, provider, key in (
            ("a", "macos", "secure-enclave", key_a),
            ("b", "windows", "tpm-cng", key_b),
        ):
            user_id = f"usr-http-{suffix}000000"
            device_id = f"dev-http-{suffix}000000"
            binding_id = f"cdx-http-{suffix}000000"
            self.registry.create_user(f"member-{suffix}", user_id=user_id)
            self.registry.enroll_device(
                user_id,
                platform=platform,
                key_provider=provider,
                public_key_spki_base64=key,
                device_id=device_id,
            )
            self.registry.bind_codex(user_id, f"member-{suffix}", binding_id=binding_id)
            self.registry.put_grant(
                user_id,
                "codex:project-task",
                ["project-read", "review-result"],
                grant_id=f"grant-http-{suffix}0000",
            )
        owner_user = self.registry.create_user("owner", role="owner", user_id="usr-http-owner0000")
        self.registry.bind_codex(owner_user["id"], "example-owner-air", binding_id="cdx-http-owner0000")
        self.registry.enroll_device(
            owner_user["id"], platform="macos", key_provider="secure-enclave",
            public_key_spki_base64="MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAELly3iPtrPtWoJciboCGcNcpyWKtZTa1M/z83zg8L7wVLHBcdE//zbJwuAH/4lvHw10N6Faks4bGNTtg8OSYHyQ==",
            device_id="dev-http-owner0000",
        )
        self.registry.put_grant(
            owner_user["id"], "memory:notebook", ["recall", "remember", "correct", "forget"],
            grant_id="grant-http-owner-notebook",
        )
        self.registry.put_grant(
            owner_user["id"], "workflow:publish-site", ["private-site"],
            grant_id="grant-http-owner-publish",
        )
        self.registry.put_grant(
            "usr-http-a000000", "research-library:search", ["metadata", "snippets"],
            grant_id="grant-http-a-search",
        )
        self.registry.put_grant(
            "usr-http-a000000", "research-library:get", ["metadata"],
            grant_id="grant-http-a-get",
        )
        self.registry.put_grant(
            "usr-http-a000000", "tool:codex-status", ["self"],
            grant_id="grant-http-a-status",
        )
        self.registry.put_grant(
            "usr-http-a000000", "skill:paper-writing", ["install"],
            grant_id="grant-http-a-paper",
        )
        self.registry.put_grant(
            "usr-http-b000000", "skill:paper-writing", ["install"],
            grant_id="grant-http-b-paper",
        )
        self.registry.put_grant(
            "usr-http-b000000", "skill:paper-writing", ["install"], effect="deny",
            grant_id="grant-http-b-deny",
        )

        self.job_b = self.registry.create_member_job(
            "usr-http-b000000",
            "dev-http-b000000",
            "call-bbbbbbbbbbbbbbbbbbbbbbbb",
            "member b private task",
            ["codex:project-task"],
        )
        self.lease_b = self.registry.create_content_lease(
            "usr-http-b000000",
            self.job_b["id"],
            kind="project-capsule",
            sha256="b" * 64,
            size=64,
            expires_at="2030-09-15T00:00:00Z",
        )
        self.server: CONTROL.Server | None = None
        self.thread: threading.Thread | None = None

    def tearDown(self) -> None:
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        if self.thread:
            self.thread.join(timeout=3)
        self.temporary.cleanup()

    @staticmethod
    def fixture_authenticator(_method: str, _path: str, _body: bytes, headers: dict[str, str]) -> dict[str, str]:
        principal = headers.get("X-Test-Principal", "")
        if principal == "a":
            return {"user_id": "usr-http-a000000", "device_id": "dev-http-a000000"}
        if principal == "b":
            return {"user_id": "usr-http-b000000", "device_id": "dev-http-b000000"}
        if principal == "owner":
            return {"user_id": "usr-http-owner0000", "device_id": "dev-http-owner0000"}
        return {}

    def start_server(self, authenticator=None, approval_verifier=None) -> None:
        self.server = CONTROL.Server(
            ("127.0.0.1", 0), self.store, authenticator, approval_verifier
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def request(self, method: str, path: str, *, principal: str | None = None, payload: dict | None = None) -> tuple[int, dict]:
        assert self.server
        body = json.dumps(payload).encode() if payload is not None else None
        headers = {"Content-Type": "application/json"}
        if principal:
            headers["X-Test-Principal"] = principal
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        data = json.loads(response.read().decode())
        connection.close()
        return response.status, data

    def worker_request(
        self, method: str, path: str, payload: dict | None = None, *,
        device_id: str = "dev-member-worker-test", secret: bytes = b"worker-test-secret",
    ) -> tuple[int, bytes]:
        assert self.server
        body = json.dumps(payload, separators=(",", ":")).encode() if payload is not None else b""
        timestamp = str(int(time.time()))
        nonce = secrets.token_hex(16)
        canonical = "\n".join([method, path, timestamp, nonce, hashlib.sha256(body).hexdigest()])
        signature = hmac.new(secret, canonical.encode(), hashlib.sha256).hexdigest()
        headers = {
            "Content-Type": "application/json", "X-Wu-Device": device_id,
            "X-Wu-Time": timestamp, "X-Wu-Nonce": nonce, "X-Wu-Signature": signature,
        }
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request(method, path, body=body if method == "POST" else None, headers=headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, data

    def test_owner_and_member_workers_cannot_cross_queues(self) -> None:
        self.start_server(self.fixture_authenticator)
        status, _raw = self.worker_request(
            "GET", "/two-head-wu/v1/worker/air-jobs/lease",
            device_id="dev-owner-worker-test", secret=b"owner-worker-test-secret",
        )
        self.assertEqual(status, 403)
        status, _raw = self.worker_request("GET", "/two-head-wu/v1/worker/jobs/lease")
        self.assertEqual(status, 403)

    def binary_request(self, path: str, *, principal: str) -> tuple[int, bytes, str | None]:
        assert self.server
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request("GET", path, headers={"X-Test-Principal": principal})
        response = connection.getresponse()
        data = response.read()
        media_type = response.getheader("Content-Type")
        connection.close()
        return response.status, data, media_type

    def test_v1_and_v2_are_parallel_and_v2_fails_closed_without_authenticator(self) -> None:
        self.start_server()
        status, owner_health = self.request("GET", "/two-head-wu/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(owner_health["scope"], "owner-only")
        status, member_health = self.request("GET", "/two-head-wu/v2/health")
        self.assertEqual(status, 200)
        self.assertEqual(member_health["authentication"], "unavailable")
        status, denied = self.request("GET", "/two-head-wu/v2/me", principal="a")
        self.assertEqual(status, 503)
        self.assertIn("unavailable", denied["error"])

    def test_member_can_create_list_cancel_and_retry_only_own_job(self) -> None:
        self.start_server(self.fixture_authenticator)
        payload = {
            "request_id": "call-aaaaaaaaaaaaaaaaaaaaaaaa",
            "instruction": "member a task",
            "capabilities": ["codex:project-task"],
        }
        status, created = self.request("POST", "/two-head-wu/v2/jobs", principal="a", payload=payload)
        self.assertEqual(status, 201)
        job_id = created["job"]["id"]
        self.assertEqual(created["job"]["user_id"], "usr-http-a000000")

        status, listed = self.request("GET", "/two-head-wu/v2/jobs", principal="a")
        self.assertEqual(status, 200)
        self.assertEqual([item["id"] for item in listed["jobs"]], [job_id])
        self.assertNotIn(self.job_b["id"], [item["id"] for item in listed["jobs"]])

        status, cancelled = self.request("POST", f"/two-head-wu/v2/jobs/{job_id}/cancel", principal="a", payload={})
        self.assertEqual(status, 200)
        self.assertEqual(cancelled["job"]["state"], "cancelled")
        status, retried = self.request("POST", f"/two-head-wu/v2/jobs/{job_id}/retry", principal="a", payload={})
        self.assertEqual(status, 200)
        self.assertEqual(retried["job"]["state"], "queued")

    def test_member_capability_directory_is_independent_and_intersects_active_grants(self) -> None:
        self.start_server(self.fixture_authenticator)
        status, directory = self.request("GET", "/two-head-wu/v2/capabilities", principal="a")
        self.assertEqual(status, 200)
        self.assertEqual(directory["schema_version"], 2)
        self.assertEqual(
            [item["capability_id"] for item in directory["effective_grants"]],
            ["codex:project-task", "research-library:get", "research-library:search", "tool:codex-status"],
        )
        catalog = directory["catalog"]
        self.assertEqual(catalog["signature_base64"], "fixture-signature")
        self.assertNotIn("memory:personal", [item["id"] for item in catalog["capabilities"]])
        status, created = self.request(
            "POST", "/two-head-wu/v2/calls", principal="a",
            payload={
                "request_id": "call-eeeeeeeeeeeeeeeeeeeeeeee",
                "capability_id": "research-library:search",
                "input": {"query": "member research", "limit": 5},
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(created["job"]["kind"], "capability")
        self.assertEqual(created["job"]["capability_id"], "research-library:search")
        status, fetched = self.request(
            "POST", "/two-head-wu/v2/calls", principal="a",
            payload={
                "request_id": "call-343434343434343434343434",
                "capability_id": "research-library:get",
                "input": {"work_id": "00000000-0000-4000-8000-000000000001"},
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(fetched["job"]["capability_id"], "research-library:get")
        status, own_status = self.request(
            "POST", "/two-head-wu/v2/calls", principal="a",
            payload={
                "request_id": "call-565656565656565656565656",
                "capability_id": "tool:codex-status",
                "input": {},
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(own_status["job"]["capability_id"], "tool:codex-status")

    def test_owner_air_gets_notebook_grant_without_exposing_it_to_members(self) -> None:
        self.start_server(self.fixture_authenticator)
        owner_status, owner_directory = self.request(
            "GET", "/two-head-wu/v2/capabilities", principal="owner"
        )
        self.assertEqual(owner_status, 200)
        self.assertEqual(owner_directory["catalog"]["signature_base64"], "fixture-owner-signature")
        self.assertIn(
            "memory:notebook",
            [item["capability_id"] for item in owner_directory["effective_grants"]],
        )
        member_status, member_directory = self.request(
            "GET", "/two-head-wu/v2/capabilities", principal="a"
        )
        self.assertEqual(member_status, 200)
        self.assertNotIn(
            "memory:notebook",
            [item["id"] for item in member_directory["catalog"]["capabilities"]],
        )
        status, created = self.request(
            "POST", "/two-head-wu/v2/calls", principal="owner",
            payload={
                "request_id": "call-787878787878787878787878",
                "capability_id": "memory:notebook",
                "input": {"action": "recall", "query": "project"},
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(created["job"]["capability_id"], "memory:notebook")
        denied, _body = self.request(
            "POST", "/two-head-wu/v2/calls", principal="a",
            payload={
                "request_id": "call-797979797979797979797979",
                "capability_id": "memory:notebook",
                "input": {"action": "recall", "query": "project"},
            },
        )
        self.assertEqual(denied, 403)
        status, denied_status = self.request(
            "POST", "/two-head-wu/v2/calls", principal="b",
            payload={
                "request_id": "call-787878787878787878787878",
                "capability_id": "tool:codex-status",
                "input": {},
            },
        )
        self.assertEqual(status, 403)
        self.assertIn("not granted", denied_status["error"])
        status, invalid = self.request(
            "POST", "/two-head-wu/v2/calls", principal="a",
            payload={
                "request_id": "call-121212121212121212121212",
                "capability_id": "research-library:search",
                "input": {"query": "member research", "limit": 101},
            },
        )
        self.assertEqual(status, 400)
        self.assertIn("maximum", invalid["error"])
        status, denied = self.request(
            "POST", "/two-head-wu/v2/calls", principal="a",
            payload={
                "request_id": "call-ffffffffffffffffffffffff",
                "capability_id": "research-library:export",
                "input": {"artifact_id": "00000000-0000-4000-8000-000000000001", "expected_sha256": "a" * 64},
            },
        )
        self.assertEqual(status, 403)
        self.assertIn("unavailable", denied["error"])

    def test_owner_step_up_key_registration_exact_signature_and_replay_gate(self) -> None:
        seen: list[bytes] = []

        def verifier(_public_key: bytes, signature: bytes, canonical: bytes) -> bool:
            seen.append(canonical)
            return signature == b"fixture-approval-signature"

        self.start_server(self.fixture_authenticator, verifier)
        status, _denied = self.request("GET", "/two-head-wu/v2/approval-key", principal="a")
        self.assertEqual(status, 403)
        status, initial = self.request("GET", "/two-head-wu/v2/approval-key", principal="owner")
        self.assertEqual(status, 200)
        self.assertFalse(initial["registered"])

        public_key = (
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAELly3iPtrPtWoJciboCGcNcpyWKtZTa1M/"
            "z83zg8L7wVLHBcdE//zbJwuAH/4lvHw10N6Faks4bGNTtg8OSYHyQ=="
        )
        signature = base64.b64encode(b"fixture-approval-signature").decode()
        status, registered = self.request(
            "POST", "/two-head-wu/v2/approval-key", principal="owner",
            payload={"public_key_spki_base64": public_key, "proof_signature_base64": signature},
        )
        self.assertEqual(status, 201)
        self.assertTrue(registered["registered"])
        self.assertEqual(
            seen[0],
            self.store.owner_approval_key_canonical(
                "usr-http-owner0000", "dev-http-owner0000", public_key
            ),
        )

        capability_input = {
            "project_id": "paper-site", "site_id": "private-site", "artifact_sha256": "d" * 64
        }
        request_id = "call-909090909090909090909090"
        status, _missing = self.request(
            "POST", "/two-head-wu/v2/calls", principal="owner",
            payload={"request_id": request_id, "capability_id": "workflow:publish-site", "input": capability_input},
        )
        self.assertEqual(status, 403)
        status, outside_scope = self.request(
            "POST", "/two-head-wu/v2/calls", principal="owner",
            payload={
                "request_id": "call-919191919191919191919191",
                "capability_id": "workflow:publish-site",
                "input": capability_input | {"site_id": "public-site"},
            },
        )
        self.assertEqual(status, 403)
        self.assertIn("scope", outside_scope["error"])

        canonical_input = self.store.canonical_capability_input(capability_input)
        input_sha256 = hashlib.sha256(canonical_input).hexdigest()
        expires_at = int(time.time()) + 120
        nonce = "90" * 16
        approval = {
            "input_sha256": input_sha256,
            "expires_at": expires_at,
            "nonce": nonce,
            "signature_base64": signature,
        }
        status, queued = self.request(
            "POST", "/two-head-wu/v2/calls", principal="owner",
            payload={
                "request_id": request_id, "capability_id": "workflow:publish-site",
                "input": capability_input, "approval": approval,
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(queued["job"]["capability_id"], "workflow:publish-site")
        self.assertEqual(
            seen[-1],
            self.store.owner_approval_canonical(
                "usr-http-owner0000", "dev-http-owner0000", request_id,
                "workflow:publish-site", input_sha256, expires_at, nonce,
            ),
        )
        status, replayed = self.request(
            "POST", "/two-head-wu/v2/calls", principal="owner",
            payload={
                "request_id": request_id, "capability_id": "workflow:publish-site",
                "input": capability_input, "approval": approval,
            },
        )
        self.assertEqual(status, 403)
        self.assertIn("replay", replayed["error"])

    def test_member_module_directory_and_archive_require_an_active_grant(self) -> None:
        self.start_server(self.fixture_authenticator)
        status, directory = self.request("GET", "/two-head-wu/v2/modules", principal="a")
        self.assertEqual(status, 200)
        self.assertEqual(directory["catalog"]["signature_base64"], "fixture-module-signature")
        self.assertEqual(
            [item["id"] for item in directory["catalog"]["modules"]],
            ["skill:paper-writing", "skill:paper-navigator"],
        )
        self.assertEqual(directory["effective_modules"], ["skill:paper-writing"])

        status, archive, media_type = self.binary_request(
            f"/two-head-wu/v2/modules/skill%3Apaper-writing/archive?version={self.module_version}",
            principal="a",
        )
        self.assertEqual(status, 200)
        self.assertEqual(archive, self.module_archive)
        self.assertEqual(media_type, "application/gzip")

        status, denied = self.request(
            "GET", "/two-head-wu/v2/modules/skill%3Apaper-navigator/archive", principal="a",
        )
        self.assertEqual(status, 403)
        self.assertIn("not granted", denied["error"])
        status, denied = self.request(
            "GET", "/two-head-wu/v2/modules/skill%3Apaper-writing/archive", principal="b",
        )
        self.assertEqual(status, 403)
        self.assertIn("not granted", denied["error"])

    def test_cross_tenant_job_retry_and_content_metadata_are_rejected(self) -> None:
        self.start_server(self.fixture_authenticator)
        paths = (
            ("GET", f"/two-head-wu/v2/jobs/{self.job_b['id']}", None),
            ("POST", f"/two-head-wu/v2/jobs/{self.job_b['id']}/retry", {}),
            ("GET", f"/two-head-wu/v2/content/{self.lease_b['id']}", None),
        )
        for method, path, payload in paths:
            with self.subTest(path=path):
                status, response = self.request(method, path, principal="a", payload=payload)
                self.assertEqual(status, 403)
                self.assertIn("cross-tenant", response["error"])

    def test_member_content_upload_download_idempotency_and_purge_are_tenant_scoped(self) -> None:
        self.start_server(self.fixture_authenticator)
        status, created = self.request(
            "POST", "/two-head-wu/v2/jobs/draft", principal="a",
            payload={
                "request_id": "call-101010101010101010101010",
                "instruction": "review uploaded notes",
                "capabilities": ["codex:project-task"],
            },
        )
        self.assertEqual(status, 201)
        job_id = created["job"]["id"]
        self.assertEqual(created["job"]["state"], "staging")
        status, missing = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/submit", principal="a", payload={},
        )
        self.assertEqual(status, 409)
        self.assertIn("project capsule", missing["error"])
        content = b"member-a-input-artifact"
        upload = {
            "request_id": "call-202020202020202020202020",
            "kind": "project-capsule",
            "filename": "project.tar.gz",
            "media_type": "application/gzip",
            "sha256": hashlib.sha256(content).hexdigest(),
            "content_base64": base64.b64encode(content).decode(),
        }
        status, first = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/content", principal="a", payload=upload,
        )
        self.assertEqual(status, 201)
        lease_id = first["content_lease"]["id"]
        self.assertEqual(first["content_lease"]["state"], "available")
        self.assertNotIn("content_base64", first["content"])
        status, duplicate = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/content", principal="a", payload=upload,
        )
        self.assertEqual(status, 201)
        self.assertEqual(duplicate["content_lease"]["id"], lease_id)
        self.assertEqual(duplicate["content_lease"]["expires_at"], first["content_lease"]["expires_at"])

        status, downloaded, media_type = self.binary_request(
            f"/two-head-wu/v2/content/{lease_id}/download", principal="a",
        )
        self.assertEqual(status, 200)
        self.assertEqual(downloaded, content)
        self.assertEqual(media_type, "application/gzip")
        for method, path, payload in (
            ("GET", f"/two-head-wu/v2/content/{lease_id}", None),
            ("GET", f"/two-head-wu/v2/content/{lease_id}/download", None),
            ("POST", f"/two-head-wu/v2/content/{lease_id}/purge", {}),
        ):
            with self.subTest(path=path):
                status, denied = self.request(method, path, principal="b", payload=payload)
                self.assertEqual(status, 403)
                self.assertIn("cross-tenant", denied["error"])

        self.registry.cancel_member_job("usr-http-b000000", self.job_b["id"])
        status, raw = self.worker_request("GET", "/two-head-wu/v1/worker/air-jobs/lease")
        self.assertEqual(status, 200)
        self.assertIsNone(json.loads(raw)["job"])
        status, submitted = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/submit", principal="a", payload={},
        )
        self.assertEqual(status, 200)
        self.assertEqual(submitted["job"]["state"], "queued")
        status, raw = self.worker_request("GET", "/two-head-wu/v1/worker/air-jobs/lease")
        self.assertEqual(status, 200)
        leased = json.loads(raw)["job"]
        self.assertEqual(leased["id"], job_id)
        execution_lease_id = leased["execution_lease_id"]
        worker_path = (
            f"/two-head-wu/v1/worker/air-jobs/{job_id}/content/{lease_id}"
            f"?execution_lease_id={execution_lease_id}"
        )
        status, worker_bytes = self.worker_request("GET", worker_path)
        self.assertEqual(status, 200)
        self.assertEqual(worker_bytes, content)
        status, metadata_raw = self.worker_request("GET", worker_path.replace("?", "/metadata?"))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(metadata_raw)["content_lease"]["id"], lease_id)
        status, _denied = self.worker_request(
            "GET", worker_path.replace(execution_lease_id, "work-000000000000000000000000"),
        )
        self.assertEqual(status, 403)

        status, active = self.request(
            "POST", f"/two-head-wu/v2/content/{lease_id}/purge", principal="a", payload={},
        )
        self.assertEqual(status, 409)
        self.assertIn("active", active["error"])
        status, _cancelled = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/cancel", principal="a", payload={},
        )
        self.assertEqual(status, 200)

        status, purged = self.request(
            "POST", f"/two-head-wu/v2/content/{lease_id}/purge", principal="a", payload={},
        )
        self.assertEqual(status, 200)
        self.assertEqual(purged["content_lease"]["state"], "purged")
        self.assertEqual(self.registry.member_job("usr-http-a000000", job_id)["state"], "cancelled")
        status, unavailable = self.request(
            "GET", f"/two-head-wu/v2/content/{lease_id}/download", principal="a",
        )
        self.assertEqual(status, 410)
        self.assertIn("unavailable", unavailable["error"])
        status, retry = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/retry", principal="a", payload={},
        )
        self.assertEqual(status, 200)
        self.assertEqual(retry["job"]["state"], "staging")

    def test_member_interaction_mailbox_requires_exact_tenant_and_worker_lease(self) -> None:
        self.start_server(self.fixture_authenticator)
        status, raw = self.worker_request("GET", "/two-head-wu/v1/worker/air-jobs/lease")
        self.assertEqual(status, 200)
        leased = json.loads(raw)["job"]
        lease_id = leased["execution_lease_id"]
        job_id = leased["id"]
        status, _raw = self.worker_request(
            "POST", f"/two-head-wu/v1/worker/air-jobs/{job_id}/state",
            {"execution_lease_id": lease_id, "state": "running"},
        )
        self.assertEqual(status, 200)
        status, raw = self.worker_request(
            "POST", f"/two-head-wu/v1/worker/air-jobs/{job_id}/interactions",
            {
                "execution_lease_id": lease_id,
                "kind": "command-approval",
                "title": "Approve bounded action",
                "detail": "Run the sanitized action in this task workspace.",
                "action_sha256": hashlib.sha256(b"sanitized-action").hexdigest(),
            },
        )
        self.assertEqual(status, 201)
        interaction = json.loads(raw)["interaction"]
        interaction_id = interaction["id"]
        self.assertEqual(interaction["state"], "pending")
        self.assertNotIn("execution_lease_id", interaction)

        status, denied = self.request(
            "GET", f"/two-head-wu/v2/jobs/{job_id}/interactions", principal="a",
        )
        self.assertEqual(status, 403)
        self.assertIn("cross-tenant", denied["error"])
        status, listed = self.request(
            "GET", f"/two-head-wu/v2/jobs/{job_id}/interactions", principal="b",
        )
        self.assertEqual(status, 200)
        self.assertEqual([item["id"] for item in listed["interactions"]], [interaction_id])
        status, denied_reply = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/interactions/{interaction_id}/reply",
            principal="a", payload={"decision": "accept"},
        )
        self.assertEqual(status, 403)
        self.assertIn("cross-tenant", denied_reply["error"])
        status, replied = self.request(
            "POST", f"/two-head-wu/v2/jobs/{job_id}/interactions/{interaction_id}/reply",
            principal="b", payload={"decision": "accept"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(replied["interaction"]["state"], "answered")
        self.assertEqual(self.registry.member_job("usr-http-b000000", job_id)["state"], "running")

        worker_path = (
            f"/two-head-wu/v1/worker/air-jobs/{job_id}/interactions/{interaction_id}"
            f"?execution_lease_id={lease_id}"
        )
        status, raw = self.worker_request("GET", worker_path)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["interaction"]["reply"], {"decision": "accept"})
        wrong_path = (
            f"/two-head-wu/v1/worker/air-jobs/{job_id}/interactions/{interaction_id}"
            f"?execution_lease_id=work-{'0' * 24}"
        )
        status, raw = self.worker_request("GET", wrong_path)
        self.assertEqual(status, 403)
        self.assertIn("not leased", json.loads(raw)["error"])

    def test_worker_leases_fixed_member_identity_and_returns_result_to_same_tenant(self) -> None:
        self.start_server(self.fixture_authenticator)
        status, raw = self.worker_request("GET", "/two-head-wu/v1/worker/air-jobs/lease")
        self.assertEqual(status, 200)
        leased = json.loads(raw)["job"]
        self.assertEqual(leased["id"], self.job_b["id"])
        self.assertEqual(leased["identity_alias"], "member-b")
        lease_id = leased["execution_lease_id"]
        status, _raw = self.worker_request(
            "POST", f"/two-head-wu/v1/worker/air-jobs/{self.job_b['id']}/state",
            {"execution_lease_id": lease_id, "state": "running"},
        )
        self.assertEqual(status, 200)
        result = b"member-result-package"
        status, raw = self.worker_request(
            "POST", f"/two-head-wu/v1/worker/air-jobs/{self.job_b['id']}/result",
            {
                "execution_lease_id": lease_id,
                "result_sha256": hashlib.sha256(result).hexdigest(),
                "result_base64": base64.b64encode(result).decode(),
            },
        )
        self.assertEqual(status, 200)
        uploaded = json.loads(raw)["job"]
        result_lease_id = uploaded["content_lease_ids"][-1]

        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request(
            "GET", f"/two-head-wu/v2/jobs/{self.job_b['id']}/result",
            headers={"X-Test-Principal": "b"},
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), result)
        connection.close()

        status, denied_receipt = self.request(
            "POST", f"/two-head-wu/v2/content/{result_lease_id}/receipt", principal="a",
            payload={"sha256": hashlib.sha256(result).hexdigest()},
        )
        self.assertEqual(status, 403)
        self.assertIn("cross-tenant", denied_receipt["error"])
        status, bad_receipt = self.request(
            "POST", f"/two-head-wu/v2/content/{result_lease_id}/receipt", principal="b",
            payload={"sha256": "f" * 64},
        )
        self.assertEqual(status, 400)
        self.assertIn("digest mismatch", bad_receipt["error"])
        receipt_payload = {"sha256": hashlib.sha256(result).hexdigest()}
        status, receipt = self.request(
            "POST", f"/two-head-wu/v2/content/{result_lease_id}/receipt", principal="b",
            payload=receipt_payload,
        )
        self.assertEqual(status, 200)
        self.assertEqual(receipt["content_lease"]["state"], "purged")
        self.assertEqual(receipt["content_lease"]["sha256"], receipt_payload["sha256"])
        result_lease = self.registry.member_content_lease("usr-http-b000000", result_lease_id)
        self.assertFalse(self.store.member_content_path(result_lease).exists())
        self.assertEqual(
            self.registry.member_content_lease("usr-http-b000000", self.lease_b["id"])["state"], "purged"
        )
        self.assertEqual(
            self.registry.member_job("usr-http-b000000", self.job_b["id"])["instruction"],
            "[content purged after receipt]",
        )
        status, duplicate = self.request(
            "POST", f"/two-head-wu/v2/content/{result_lease_id}/receipt", principal="b",
            payload=receipt_payload,
        )
        self.assertEqual(status, 200)
        self.assertEqual(duplicate["content_lease"]["state"], "purged")

        status, denied = self.request("GET", f"/two-head-wu/v2/jobs/{self.job_b['id']}", principal="a")
        self.assertEqual(status, 403)
        self.assertIn("cross-tenant", denied["error"])

    def test_ttl_cleanup_purges_due_content_but_retains_redacted_metadata(self) -> None:
        result = self.store.cleanup_member_content(now="2031-01-01T00:00:00Z")
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["purged"], [self.lease_b["id"]])
        retained = self.registry.member_content_lease("usr-http-b000000", self.lease_b["id"])
        self.assertEqual(retained["state"], "purged")
        self.assertEqual(retained["sha256"], "b" * 64)
        self.assertIn("purged_at", retained)
        redacted_job = self.registry.member_job("usr-http-b000000", self.job_b["id"])
        self.assertEqual(redacted_job["state"], "expired")
        self.assertEqual(redacted_job["instruction"], "[content purged after ttl]")
        status = CONTROL.read_json(self.store.member_cleanup_state)
        self.assertEqual(status["result"], "ok")
        self.assertEqual(status["failure_count"], 0)
        self.assertEqual(status["purged"], 1)

    def test_ttl_cleanup_failure_records_redacted_alert_and_retries(self) -> None:
        content_path = self.store.member_content_path(self.lease_b)
        content_path.mkdir(parents=True)
        failed = self.store.cleanup_member_content(now="2031-01-01T00:00:00Z")
        self.assertEqual(failed["failures"], [self.lease_b["id"]])
        self.assertEqual(failed["purged"], [])
        retained = self.registry.member_content_lease("usr-http-b000000", self.lease_b["id"])
        self.assertEqual(retained["state"], "expired")
        status = CONTROL.read_json(self.store.member_cleanup_state)
        self.assertEqual(status["result"], "failed")
        self.assertEqual(status["failure_count"], 1)
        self.assertEqual(
            status["failure_hashes"], [hashlib.sha256(self.lease_b["id"].encode()).hexdigest()[:16]],
        )
        self.assertNotIn(self.lease_b["id"], json.dumps(status))

        content_path.rmdir()
        retried = self.store.cleanup_member_content(now="2031-01-01T01:00:00Z")
        self.assertEqual(retried["failures"], [])
        self.assertEqual(retried["purged"], [self.lease_b["id"]])
        recovered = CONTROL.read_json(self.store.member_cleanup_state)
        self.assertEqual(recovered["result"], "ok")
        self.assertEqual(recovered["failure_count"], 0)

    def test_cleanup_of_interrupted_result_cannot_delete_new_attempt_result(self) -> None:
        old_result = self.registry.create_result_lease(
            "usr-http-b000000", self.job_b["id"], sha256="c" * 64, size=10,
            expires_at="2028-01-01T00:00:00Z", lease_id="content-old-result-attempt", state="expired",
        )
        new_result = self.registry.create_result_lease(
            "usr-http-b000000", self.job_b["id"], sha256="d" * 64, size=10,
            expires_at="2032-01-01T00:00:00Z", lease_id="content-new-result-attempt", state="available",
        )
        old_path = self.store.member_content_path(old_result)
        new_path = self.store.member_content_path(new_result)
        self.assertNotEqual(old_path, new_path)
        CONTROL.atomic_write(old_path, b"old-result")
        CONTROL.atomic_write(new_path, b"new-result")

        cleaned = self.store.cleanup_member_content(now="2029-01-01T00:00:00Z")
        self.assertEqual(cleaned["purged"], [old_result["id"]])
        self.assertFalse(old_path.exists())
        self.assertEqual(new_path.read_bytes(), b"new-result")
        self.assertEqual(
            self.registry.member_content_lease("usr-http-b000000", new_result["id"])["state"],
            "available",
        )


if __name__ == "__main__":
    unittest.main()
