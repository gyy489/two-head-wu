#!/usr/bin/env python3
from __future__ import annotations

import copy
import concurrent.futures
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "server"
sys.path.insert(0, str(SERVER))
import multi_user_contracts as CONTRACTS  # noqa: E402

CONTROL_SPEC = importlib.util.spec_from_file_location("owner_v1_control_plane", SERVER / "control_plane.py")
assert CONTROL_SPEC and CONTROL_SPEC.loader
CONTROL = importlib.util.module_from_spec(CONTROL_SPEC)
CONTROL_SPEC.loader.exec_module(CONTROL)


class MultiUserContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = json.loads((ROOT / "tests" / "fixtures" / "multi-user-v2.json").read_text(encoding="utf-8"))

    def bundle(self) -> dict:
        return copy.deepcopy(self.fixture["bundle"])

    def test_valid_two_tenant_bundle_and_exact_grants(self) -> None:
        result = CONTRACTS.validate_bundle(self.bundle())
        self.assertEqual([item["id"] for item in result["users"]], ["usr-member-a001", "usr-member-b002"])
        self.assertEqual(result["jobs"][0]["capability_envelope"]["secret_access"], "none")

        denied = self.bundle()
        denied["jobs"][0]["capability_envelope"]["capabilities"].append("memory:personal")
        with self.assertRaisesRegex(CONTRACTS.ContractError, "not granted"):
            CONTRACTS.validate_bundle(denied)

    def test_cross_tenant_and_second_active_device_are_rejected(self) -> None:
        crossed = self.bundle()
        crossed["jobs"][0]["device_id"] = self.fixture["attacks"]["cross_tenant_device"]
        with self.assertRaisesRegex(CONTRACTS.ContractError, "cross-tenant"):
            CONTRACTS.validate_bundle(crossed)

        duplicate = self.bundle()
        second = copy.deepcopy(duplicate["devices"][0])
        second["id"] = "dev-member-a-second"
        duplicate["devices"].append(second)
        with self.assertRaisesRegex(CONTRACTS.ContractError, "more than one active Air"):
            CONTRACTS.validate_bundle(duplicate)

    def test_revocation_owner_fallback_and_secret_canary_fail_closed(self) -> None:
        revoked = self.bundle()
        revoked["codex_bindings"][0]["status"] = "revoked"
        revoked["codex_bindings"][0]["revoked_at"] = "2026-09-01T01:00:00Z"
        revoked["jobs"][0]["state"] = "queued"
        with self.assertRaisesRegex(CONTRACTS.ContractError, "must be active"):
            CONTRACTS.validate_bundle(revoked)

        fallback = self.bundle()
        fallback["codex_bindings"][0]["identity_alias"] = self.fixture["attacks"]["owner_fallback_alias"]
        with self.assertRaisesRegex(CONTRACTS.ContractError, "legacy pseudo-identity"):
            CONTRACTS.validate_bundle(fallback)

        spoofed_owner = self.bundle()
        spoofed_owner["codex_bindings"][0]["identity_alias"] = "owner-primary"
        with self.assertRaisesRegex(CONTRACTS.ContractError, "non-owner"):
            CONTRACTS.validate_bundle(spoofed_owner)

        canary = self.bundle()
        canary["jobs"][0]["instruction"] = self.fixture["attacks"]["secret_canary"]
        with self.assertRaisesRegex(CONTRACTS.ContractError, "secret canary"):
            CONTRACTS.validate_bundle(canary)

    def test_state_machines_and_idempotency_scope(self) -> None:
        recovery = self.fixture["attacks"]["disconnect_transition"]
        self.assertEqual(CONTRACTS.transition(recovery["entity"], recovery["from"], recovery["to"]), "queued")
        self.assertEqual(CONTRACTS.transition("result", "available", "received"), "received")
        self.assertEqual(CONTRACTS.transition("receipt", "issued", "confirmed"), "confirmed")
        with self.assertRaises(CONTRACTS.ContractError):
            CONTRACTS.transition("job", "succeeded", "running")
        first = CONTRACTS.idempotency_scope("usr-member-a001", "dev-member-a-macos", "call-aaaaaaaaaaaaaaaaaaaaaaaa")
        second = CONTRACTS.idempotency_scope("usr-member-b002", "dev-member-b-windows", "call-aaaaaaaaaaaaaaaaaaaaaaaa")
        self.assertNotEqual(first, second)

    def test_schema_is_closed_and_owner_v1_snapshot_is_unchanged(self) -> None:
        schema = yaml.safe_load((ROOT / "contracts" / "multi-user-v2.schema.yaml").read_text(encoding="utf-8"))
        self.assertFalse(schema["additionalProperties"])
        self.assertTrue(all(definition.get("additionalProperties") is False for definition in schema["$defs"].values()))

        snapshot = self.fixture["owner_v1_snapshot"]
        owner_policy = yaml.safe_load((ROOT / "policies" / "owner-only.yaml").read_text(encoding="utf-8"))
        owner_job = yaml.safe_load((ROOT / "contracts" / "job.schema.yaml").read_text(encoding="utf-8"))
        self.assertEqual(CONTROL.API_PREFIX, snapshot["api_prefix"])
        self.assertEqual(CONTROL.PROTOCOL_VERSION, snapshot["protocol_version"])
        self.assertEqual(sorted(owner_policy["scope"]["allowed_devices"]), snapshot["device_roles"])
        self.assertEqual(owner_policy["scope"]["allowed_identity_aliases"], snapshot["owner_pool"])
        self.assertEqual(owner_policy["scope"]["classmates"], snapshot["classmates"])
        self.assertEqual(owner_job["properties"]["owner"]["const"], snapshot["job_owner"])
        self.assertEqual(owner_job["properties"]["identity"]["enum"], snapshot["job_identities"])

    def test_member_registry_persists_single_device_binding_and_grants(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-registry-") as temporary:
            path = Path(temporary) / "state" / "members-v2.json"
            registry = CONTRACTS.MemberRegistry(path)
            registry.initialize()
            member = registry.create_user("member-a", user_id="usr-registry-a001")
            key = self.fixture["bundle"]["devices"][0]["public_key_spki_base64"]
            first = registry.enroll_device(member["id"], platform="macos", key_provider="secure-enclave", public_key_spki_base64=key, device_id="dev-registry-a-first")
            with self.assertRaisesRegex(CONTRACTS.ContractError, "must be revoked"):
                registry.enroll_device(member["id"], platform="macos", key_provider="secure-enclave", public_key_spki_base64=key, device_id="dev-registry-a-second")
            registry.revoke_device(member["id"], first["id"])
            second = registry.enroll_device(member["id"], platform="macos", key_provider="secure-enclave", public_key_spki_base64=key, device_id="dev-registry-a-second")
            binding = registry.bind_codex(member["id"], "member-a", binding_id="cdx-registry-a001")
            grant = registry.put_grant(member["id"], "research-library:search", ["metadata", "snippets"], grant_id="grant-registry-search")
            registry.put_grant(member["id"], "codex:project-task", ["project-read", "review-result"], grant_id="grant-registry-codex")
            job = registry.create_job(member["id"], second["id"], binding["id"], "call-bbbbbbbbbbbbbbbbbbbbbbbb", "review this project", ["codex:project-task"], job_id="job-registry-project")
            lease = registry.create_content_lease(member["id"], job["id"], kind="project-capsule", sha256="b" * 64, size=128, expires_at="2030-09-15T00:00:00Z", lease_id="content-registry-project")
            result_lease = registry.create_result_lease(
                member["id"], job["id"], sha256="c" * 64, size=256, expires_at="2030-09-15T00:00:00Z"
            )
            with self.assertRaisesRegex(CONTRACTS.ContractError, "digest mismatch"):
                registry.confirm_content_receipt(member["id"], result_lease["id"], "d" * 64)
            received = registry.confirm_content_receipt(member["id"], result_lease["id"], "c" * 64)
            self.assertEqual(received["state"], "received")
            self.assertEqual(
                registry.confirm_content_receipt(member["id"], result_lease["id"], "c" * 64)["received_at"],
                received["received_at"],
            )
            purged = registry.mark_content_purged(member["id"], result_lease["id"])
            self.assertEqual(purged["state"], "purged")
            self.assertEqual(registry.confirm_content_receipt(member["id"], result_lease["id"], "c" * 64)["state"], "purged")
            ready = registry.prepare_content_cleanup(now="2031-01-01T00:00:00Z")
            self.assertEqual([item["id"] for item in ready], [lease["id"]])
            self.assertEqual(registry.mark_content_purged(member["id"], lease["id"])["state"], "purged")

            reopened = CONTRACTS.MemberRegistry(path)
            reopened.initialize()
            saved = reopened.read()
            self.assertEqual(second["status"], "active")
            self.assertEqual(binding["routing_mode"], "air-fixed")
            self.assertEqual(grant["effect"], "allow")
            self.assertEqual(lease["state"], "staged")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len([item for item in saved["devices"] if item["status"] == "active"]), 1)
            self.assertEqual(saved["jobs"][0]["content_lease_ids"], ["content-registry-project", result_lease["id"]])

    def test_owner_uses_the_same_air_device_and_worker_path_as_members(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-owner-air-") as temporary:
            registry = CONTRACTS.MemberRegistry(Path(temporary) / "air-v2.json")
            registry.initialize()
            owner = registry.provision_air_user("owner", "owner-primary", role="owner")
            member = registry.provision_air_user("member", "classmate-air", role="member")
            self.assertEqual(owner["codex_binding"]["identity_alias"], "owner-primary")
            with self.assertRaisesRegex(CONTRACTS.ContractError, "require an owner"):
                registry.provision_air_user("spoofed owner account", "owner-secondary", role="member")
            second_owner = registry.provision_air_user("second owner account", "owner-secondary", role="owner")
            self.assertEqual(second_owner["user"]["role"], "owner")

            keys = [item["public_key_spki_base64"] for item in self.fixture["bundle"]["devices"]]
            owner_device = registry.enroll_device(
                owner["user"]["id"], platform="macos", key_provider="secure-enclave",
                public_key_spki_base64=keys[0], device_id="dev-owner-unified-air",
            )
            member_device = registry.enroll_device(
                member["user"]["id"], platform="windows", key_provider="tpm-cng",
                public_key_spki_base64=keys[1], device_id="dev-member-unified-air",
            )
            self.assertEqual(owner_device["role"], "air")
            self.assertEqual(member_device["role"], "air")

            for principal, device, suffix, request_char in (
                (owner, owner_device, "owner", "a"), (member, member_device, "member", "b")
            ):
                user_id = principal["user"]["id"]
                registry.put_grant(
                    user_id, "codex:project-task", ["project-read"],
                    grant_id=f"grant-unified-{suffix}-task",
                )
                registry.create_member_job(
                    user_id, device["id"], f"call-{request_char * 24}",
                    f"{suffix} unified task", ["codex:project-task"],
                )

            first = registry.lease_member_job("dev-unified-air-worker", now_epoch=1000)
            second = registry.lease_member_job("dev-unified-air-worker", now_epoch=1000)
            assert first and second
            self.assertEqual(
                {first["job"]["user_id"], second["job"]["user_id"]},
                {owner["user"]["id"], member["user"]["id"]},
            )

    def test_air_user_and_profile_grants_are_idempotent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-air-provision-") as temporary:
            registry = CONTRACTS.MemberRegistry(Path(temporary) / "air-v2.json")
            registry.initialize()
            first = registry.ensure_air_user("owner-primary", role="owner")
            repeated = registry.ensure_air_user("owner-primary", role="owner")
            second_owner = registry.ensure_air_user("owner-secondary", role="owner")
            self.assertTrue(first["created"])
            self.assertFalse(repeated["created"])
            self.assertEqual(first["user"]["id"], repeated["user"]["id"])
            self.assertNotEqual(first["user"]["id"], second_owner["user"]["id"])
            with self.assertRaisesRegex(CONTRACTS.ContractError, "owner Air user"):
                registry.ensure_air_user("owner-primary", role="member")

            grant = registry.ensure_grant(first["user"]["id"], "research-library:search", ["metadata", "snippets"])
            repeated_grant = registry.ensure_grant(
                first["user"]["id"], "research-library:search", ["snippets", "metadata"]
            )
            self.assertTrue(grant["created"])
            self.assertFalse(repeated_grant["created"])
            self.assertEqual(grant["grant"]["id"], repeated_grant["grant"]["id"])
            with self.assertRaisesRegex(CONTRACTS.ContractError, "does not match"):
                registry.ensure_grant(first["user"]["id"], "research-library:search", ["metadata"])

    def test_member_registry_rejects_owner_alias_and_cross_tenant_revoke(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-registry-") as temporary:
            registry = CONTRACTS.MemberRegistry(Path(temporary) / "members-v2.json")
            registry.initialize()
            first = registry.create_user("member-a", user_id="usr-registry-a001")
            second = registry.create_user("member-b", user_id="usr-registry-b002")
            key = self.fixture["bundle"]["devices"][0]["public_key_spki_base64"]
            device = registry.enroll_device(first["id"], platform="macos", key_provider="secure-enclave", public_key_spki_base64=key, device_id="dev-registry-a-first")
            with self.assertRaisesRegex(CONTRACTS.ContractError, "legacy pseudo-identity"):
                registry.bind_codex(first["id"], "owner-auto")
            with self.assertRaisesRegex(CONTRACTS.ContractError, "require an owner"):
                registry.bind_codex(first["id"], "owner-secondary")
            with self.assertRaisesRegex(CONTRACTS.ContractError, "cross-tenant"):
                registry.revoke_device(second["id"], device["id"])
            with self.assertRaisesRegex(CONTRACTS.ContractError, "already bound"):
                registry.enroll_device(second["id"], platform="macos", key_provider="secure-enclave", public_key_spki_base64=key, device_id="dev-registry-b-first")

    def test_member_job_lease_carries_only_fixed_binding_and_requires_exact_worker_lease(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-lease-") as temporary:
            registry = CONTRACTS.MemberRegistry(Path(temporary) / "members-v2.json")
            registry.initialize()
            provisioned = registry.provision_member("member lease", "member-lease")
            user_id = provisioned["user"]["id"]
            key = self.fixture["bundle"]["devices"][0]["public_key_spki_base64"]
            device = registry.enroll_device(
                user_id, platform="macos", key_provider="secure-enclave",
                public_key_spki_base64=key, device_id="dev-member-lease-air",
            )
            registry.put_grant(user_id, "codex:project-task", ["project-read"], grant_id="grant-member-lease")
            job = registry.create_member_job(
                user_id, device["id"], "call-cccccccccccccccccccccccc",
                "fixed identity task", ["codex:project-task"],
            )
            leased = registry.lease_member_job("dev-mini-worker-v2", now_epoch=1000)
            assert leased
            self.assertEqual(leased["job"]["id"], job["id"])
            self.assertEqual(leased["identity_alias"], "member-lease")
            self.assertEqual(leased["user_role"], "member")
            self.assertNotIn("identity_alias", leased["job"])
            self.assertNotIn("user_role", leased["job"])
            lease_id = leased["job"]["execution_lease_id"]
            running = registry.transition_member_job(
                "dev-mini-worker-v2", job["id"], lease_id, "running", now_epoch=1001,
            )
            self.assertEqual(running["state"], "running")
            with self.assertRaisesRegex(CONTRACTS.TenantAccessError, "not leased"):
                registry.transition_member_job(
                    "dev-other-worker-v2", job["id"], lease_id, "failed",
                    failure_code="identity_required", now_epoch=1002,
                )
            released = registry.lease_member_job("dev-mini-worker-v2", now_epoch=1182)
            assert released
            self.assertEqual(released["job"]["attempt"], 2)
            self.assertNotEqual(released["job"]["execution_lease_id"], lease_id)
            stale_lease_id = lease_id
            lease_id = released["job"]["execution_lease_id"]
            with self.assertRaisesRegex(CONTRACTS.TenantAccessError, "not leased"):
                registry.transition_member_job(
                    "dev-mini-worker-v2", job["id"], stale_lease_id, "uploading", now_epoch=1183,
                )
            registry.transition_member_job(
                "dev-mini-worker-v2", job["id"], lease_id, "running", now_epoch=1183,
            )
            registry.transition_member_job(
                "dev-mini-worker-v2", job["id"], lease_id, "uploading", now_epoch=1184,
            )
            interrupted_result = registry.create_result_lease(
                user_id, job["id"], sha256="f" * 64, size=64,
                expires_at="2030-09-15T00:00:00Z",
            )
            recovered = registry.lease_member_job("dev-mini-worker-v2", now_epoch=1365)
            assert recovered
            self.assertEqual(recovered["job"]["attempt"], 3)
            self.assertEqual(
                registry.member_content_lease(user_id, interrupted_result["id"])["state"], "expired",
            )
            with self.assertRaisesRegex(CONTRACTS.TenantAccessError, "not leased"):
                registry.transition_member_job(
                    "dev-mini-worker-v2", job["id"], lease_id, "succeeded", now_epoch=1366,
                )
            lease_id = recovered["job"]["execution_lease_id"]
            failed = registry.transition_member_job(
                "dev-mini-worker-v2", job["id"], lease_id, "failed",
                failure_code="identity_required", now_epoch=1366,
            )
            self.assertEqual(failed["failure_code"], "identity_required")

    def test_concurrent_member_creation_and_leasing_never_duplicates_or_crosses_tenants(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-concurrency-") as temporary:
            registry = CONTRACTS.MemberRegistry(Path(temporary) / "members-v2.json")
            registry.initialize()
            members = []
            for index, suffix in enumerate(("a", "b")):
                key = self.fixture["bundle"]["devices"][index]["public_key_spki_base64"]
                provisioned = registry.provision_member(f"concurrent {suffix}", f"concurrent-{suffix}")
                user_id = provisioned["user"]["id"]
                device = registry.enroll_device(
                    user_id, platform="macos", key_provider="secure-enclave",
                    public_key_spki_base64=key, device_id=f"dev-concurrent-{suffix}-air",
                )
                registry.put_grant(
                    user_id, "codex:project-task", ["project-read"],
                    grant_id=f"grant-concurrent-{suffix}",
                )
                members.append((user_id, device["id"], suffix))

            def create(member: tuple[str, str, str]) -> dict:
                user_id, device_id, suffix = member
                return registry.create_member_job(
                    user_id, device_id, "call-777777777777777777777777",
                    f"tenant {suffix} task", ["codex:project-task"],
                )

            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                created = list(pool.map(create, members * 4))
            ids_by_user = {
                user_id: {job["id"] for job in created if job["user_id"] == user_id}
                for user_id, _device_id, _suffix in members
            }
            self.assertTrue(all(len(values) == 1 for values in ids_by_user.values()))
            self.assertEqual(len(set().union(*ids_by_user.values())), 2)

            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                leased = list(pool.map(
                    lambda worker: registry.lease_member_job(worker, now_epoch=1000),
                    ("dev-mini-concurrent-a", "dev-mini-concurrent-b"),
                ))
            self.assertTrue(all(leased))
            leased_jobs = [value["job"] for value in leased if value]
            self.assertEqual(len({job["id"] for job in leased_jobs}), 2)
            self.assertEqual({job["user_id"] for job in leased_jobs}, set(ids_by_user))
            for value, wrong_worker in zip(leased, ("dev-mini-concurrent-b", "dev-mini-concurrent-a")):
                assert value
                job = value["job"]
                with self.assertRaisesRegex(CONTRACTS.TenantAccessError, "not leased"):
                    registry.transition_member_job(
                        wrong_worker, job["id"], job["execution_lease_id"], "failed",
                        failure_code="execution_failed", now_epoch=1001,
                    )
                registry.transition_member_job(
                    job["worker_id"], job["id"], job["execution_lease_id"], "failed",
                    failure_code="execution_failed", now_epoch=1001,
                )

    def test_member_interaction_is_bound_to_tenant_job_and_exact_worker_lease(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-interaction-") as temporary:
            registry = CONTRACTS.MemberRegistry(Path(temporary) / "members-v2.json")
            registry.initialize()
            provisioned = registry.provision_member("member interaction", "member-interaction")
            user_id = provisioned["user"]["id"]
            key = self.fixture["bundle"]["devices"][0]["public_key_spki_base64"]
            device = registry.enroll_device(
                user_id, platform="macos", key_provider="secure-enclave",
                public_key_spki_base64=key, device_id="dev-member-interaction-air",
            )
            registry.put_grant(
                user_id, "codex:project-task", ["project-read"], grant_id="grant-member-interaction",
            )
            job = registry.create_member_job(
                user_id, device["id"], "call-dddddddddddddddddddddddd",
                "interaction task", ["codex:project-task"],
            )
            content = registry.create_content_lease(
                user_id, job["id"], kind="input-artifact", sha256="d" * 64, size=32,
                expires_at="2030-09-15T00:00:00Z", lease_id="content-interaction-input",
            )
            leased = registry.lease_member_job("dev-mini-interaction-worker", now_epoch=1000)
            assert leased
            lease_id = leased["job"]["execution_lease_id"]
            registry.transition_member_job(
                "dev-mini-interaction-worker", job["id"], lease_id, "running", now_epoch=1001,
            )
            interaction = registry.create_member_interaction(
                "dev-mini-interaction-worker", job["id"], lease_id,
                kind="command-approval", title="Approve bounded action",
                detail="Run the already-sanitized action in this task workspace.",
                action_sha256="e" * 64, expires_at="2030-09-15T00:00:00Z", now_epoch=1002,
                interaction_id="ask-1111111111111111",
            )
            self.assertEqual(registry.member_job(user_id, job["id"])["state"], "waiting_user")
            with self.assertRaisesRegex(CONTRACTS.TenantAccessError, "cross-tenant"):
                registry.list_member_interactions("usr-other-member01", job["id"])
            with self.assertRaisesRegex(CONTRACTS.TenantAccessError, "not leased"):
                registry.worker_member_interaction(
                    "dev-other-interaction-worker", job["id"], lease_id, interaction["id"], now_epoch=1003,
                )
            answered = registry.reply_member_interaction(
                user_id, job["id"], interaction["id"], decision="accept",
            )
            self.assertEqual(answered["state"], "answered")
            self.assertEqual(registry.member_job(user_id, job["id"])["state"], "running")
            self.assertEqual(
                registry.worker_member_interaction(
                    "dev-mini-interaction-worker", job["id"], lease_id, interaction["id"], now_epoch=1003,
                )["reply"],
                {"decision": "accept"},
            )

            question = registry.create_member_interaction(
                "dev-mini-interaction-worker", job["id"], lease_id,
                kind="user-input", title="Choose a bounded option", detail="Select A or B; do not enter secrets.",
                action_sha256="f" * 64, expires_at="2030-09-15T00:00:00Z", now_epoch=1004,
                interaction_id="ask-2222222222222222",
            )
            registry.expire_content_for_member(user_id, content["id"])
            saved = registry.read()
            stored_question = next(item for item in saved["interactions"] if item["id"] == question["id"])
            self.assertEqual(stored_question["state"], "expired")
            self.assertEqual(stored_question["reply"], {"decision": "cancel"})
            self.assertEqual(registry.member_job(user_id, job["id"])["state"], "expired")

            registry.retry_member_job(user_id, job["id"])
            released = registry.lease_member_job("dev-mini-interaction-worker", now_epoch=1005)
            assert released
            new_lease_id = released["job"]["execution_lease_id"]
            registry.transition_member_job(
                "dev-mini-interaction-worker", job["id"], new_lease_id, "running", now_epoch=1006,
            )
            cancelled_question = registry.create_member_interaction(
                "dev-mini-interaction-worker", job["id"], new_lease_id,
                kind="user-input", title="Confirm cancellation", detail="This prompt is cancelled with its task.",
                action_sha256="a" * 64, expires_at="2030-09-15T00:00:00Z", now_epoch=1007,
                interaction_id="ask-3333333333333333",
            )
            cancelled = registry.cancel_member_job(user_id, job["id"])
            self.assertEqual(cancelled["state"], "cancelled")
            saved = registry.read()
            stored_cancelled = next(
                item for item in saved["interactions"] if item["id"] == cancelled_question["id"]
            )
            self.assertEqual(stored_cancelled["state"], "cancelled")
            self.assertEqual(stored_cancelled["reply"], {"decision": "cancel"})

    def test_member_capability_job_idempotency_cannot_change_payload(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-call-") as temporary:
            registry = CONTRACTS.MemberRegistry(Path(temporary) / "members-v2.json")
            registry.initialize()
            provisioned = registry.provision_member("member call", "member-call")
            user_id = provisioned["user"]["id"]
            key = self.fixture["bundle"]["devices"][0]["public_key_spki_base64"]
            device = registry.enroll_device(
                user_id, platform="macos", key_provider="secure-enclave",
                public_key_spki_base64=key, device_id="dev-member-call-air",
            )
            registry.put_grant(
                user_id, "research-library:search", ["metadata", "snippets"],
                grant_id="grant-member-call-search",
            )
            request_id = "call-999999999999999999999999"
            first = registry.create_member_capability_job(
                user_id, device["id"], request_id, "research-library:search", {"query": "first"},
            )
            duplicate = registry.create_member_capability_job(
                user_id, device["id"], request_id, "research-library:search", {"query": "first"},
            )
            self.assertEqual(first["id"], duplicate["id"])
            with self.assertRaisesRegex(CONTRACTS.ContractError, "different member job"):
                registry.create_member_capability_job(
                    user_id, device["id"], request_id, "research-library:search", {"query": "changed"},
                )

    def test_one_time_pairing_persists_only_token_hash_and_requires_revoke_before_repair(self) -> None:
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-pairing-") as temporary:
            root = Path(temporary)
            registry = CONTRACTS.MemberRegistry(root / "members-v2.json")
            registry.initialize()
            provisioned = registry.provision_member("member pair", "member-pair")
            pairings = CONTRACTS.MemberEnrollmentStore(root / "member-enrollments-v2.json", registry)
            pairings.initialize()
            user_id = provisioned["user"]["id"]
            token = pairings.issue(user_id, "windows", 600, now_epoch=1_788_300_000)
            state_text = pairings.state_path.read_text(encoding="utf-8")
            self.assertNotIn(token, state_text)
            self.assertIn(pairings.token_hash(token), state_text)
            self.assertEqual(pairings.inspect(token, now_epoch=1_788_300_001)["key_provider"], "tpm-cng")

            key = self.fixture["bundle"]["devices"][1]["public_key_spki_base64"]
            device = pairings.consume(token, public_key_spki_base64=key, now_epoch=1_788_300_002)
            self.assertEqual(device["user_id"], user_id)
            with self.assertRaisesRegex(CONTRACTS.ContractError, "unavailable"):
                pairings.consume(token, public_key_spki_base64=key, now_epoch=1_788_300_003)
            with self.assertRaisesRegex(CONTRACTS.ContractError, "must be revoked"):
                pairings.issue(user_id, "windows", 600, now_epoch=1_788_300_004)
            registry.revoke_device(user_id, device["id"])
            replacement = pairings.issue(user_id, "windows", 600, now_epoch=1_788_300_005)
            with self.assertRaisesRegex(CONTRACTS.ContractError, "unavailable"):
                pairings.inspect(replacement, now_epoch=1_788_300_606)


if __name__ == "__main__":
    unittest.main()
