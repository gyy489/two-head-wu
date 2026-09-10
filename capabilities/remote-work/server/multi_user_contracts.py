#!/usr/bin/env python3
"""Closed v2 Air-user contracts for the Two-Headed-Wu relay.

This module is deliberately independent from the legacy owner-only v1 control plane.
It validates data before persistence and makes tenant, identity, device, grant,
content-retention, and state-transition invariants executable.
"""

from __future__ import annotations

import base64
import copy
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import tempfile
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 2
ID_PATTERNS = {
    "user": re.compile(r"^usr-[a-z0-9][a-z0-9-]{7,63}$"),
    "device": re.compile(r"^dev-[a-z0-9][a-z0-9-]{7,95}$"),
    "codex_binding": re.compile(r"^cdx-[a-z0-9][a-z0-9-]{7,63}$"),
    "grant": re.compile(r"^grant-[a-z0-9][a-z0-9-]{7,63}$"),
    "content_lease": re.compile(r"^content-[a-z0-9][a-z0-9-]{7,63}$"),
    "job": re.compile(r"^job-[a-z0-9][a-z0-9-]{7,95}$"),
    "interaction": re.compile(r"^ask-[a-f0-9]{16}$"),
}
CAPABILITY_RE = re.compile(r"^[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$")
REQUEST_RE = re.compile(r"^call-[a-f0-9]{24}$")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
ALIAS_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
SCOPE_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
WORK_LEASE_RE = re.compile(r"^work-[a-f0-9]{24}$")
LEGACY_PSEUDO_IDENTITIES = {"owner-auto", "owner-local-catalog"}
OWNER_IDENTITY_ALIASES = {"owner-primary", "owner-secondary"}
FORBIDDEN_FIELDS = {
    "access_token", "auth", "auth_json", "cookie", "credential", "database_url",
    "password", "private_key", "refresh_token", "secret", "ssh_key", "token",
}
SECRET_CANARY = "CANARY_DO_NOT_EXPORT_"
P256_SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")
PAIRING_TOKEN_RE = re.compile(r"^pair-[A-Za-z0-9_-]{43}$")

STATE_TRANSITIONS = {
    "job": {
        "staging": {"queued", "cancelled", "expired"},
        "queued": {"leased", "cancelled", "expired"},
        "leased": {"running", "queued", "failed", "cancelled"},
        "running": {"waiting_user", "uploading", "queued", "failed", "cancelled"},
        "waiting_user": {"running", "queued", "failed", "cancelled", "expired"},
        "uploading": {"succeeded", "failed"},
        "succeeded": set(), "failed": set(), "cancelled": set(), "expired": set(),
    },
    "artifact": {
        "staged": {"available", "expired"}, "available": {"received", "expired"},
        "received": {"purged"}, "expired": {"purged"}, "purged": set(),
    },
    "interaction": {
        "pending": {"answered", "denied", "cancelled", "expired"},
        "answered": set(), "denied": set(), "cancelled": set(), "expired": set(),
    },
    "result": {
        "assembling": {"available", "failed"}, "available": {"received", "expired"},
        "received": {"purged"}, "expired": {"purged"}, "failed": {"purged"}, "purged": set(),
    },
    "receipt": {
        "issued": {"confirmed", "rejected", "expired"},
        "confirmed": set(), "rejected": set(), "expired": set(),
    },
}


class ContractError(ValueError):
    pass


class TenantAccessError(ContractError):
    """An authenticated member attempted to cross a tenant boundary."""


def _closed(value: Any, *, label: str, required: set[str], allowed: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    missing = required - value.keys()
    unknown = value.keys() - allowed
    if missing:
        raise ContractError(f"{label} missing fields: {', '.join(sorted(missing))}")
    if unknown:
        raise ContractError(f"{label} unknown fields: {', '.join(sorted(unknown))}")
    _reject_secret_material(value, label)
    if value.get("schema_version") != SCHEMA_VERSION:
        raise ContractError(f"{label} schema_version must be {SCHEMA_VERSION}")
    return copy.deepcopy(value)


def _reject_secret_material(value: Any, path: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).lower().replace("-", "_")
            if normalized in FORBIDDEN_FIELDS:
                raise ContractError(f"{path}.{key} is a forbidden secret-bearing field")
            _reject_secret_material(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_secret_material(child, f"{path}[{index}]")
    elif isinstance(value, str) and SECRET_CANARY in value:
        raise ContractError(f"{path} contains a secret canary")


def _id(kind: str, value: Any) -> str:
    text = str(value)
    if not ID_PATTERNS[kind].fullmatch(text):
        raise ContractError(f"invalid {kind} id")
    return text


def _timestamp(value: Any, label: str) -> str:
    text = str(value)
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ContractError(f"{label} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise ContractError(f"{label} must include a timezone")
    return text


def validate_user(raw: Any) -> dict[str, Any]:
    fields = {"schema_version", "id", "role", "status", "display_name", "created_at", "updated_at"}
    item = _closed(raw, label="user", required=fields - {"updated_at"}, allowed=fields)
    _id("user", item["id"])
    if item["role"] not in {"owner", "member"} or item["status"] not in {"active", "suspended", "revoked"}:
        raise ContractError("invalid user role or status")
    if not isinstance(item["display_name"], str) or not 1 <= len(item["display_name"]) <= 80:
        raise ContractError("invalid user display_name")
    _timestamp(item["created_at"], "user.created_at")
    if "updated_at" in item:
        _timestamp(item["updated_at"], "user.updated_at")
    return item


def validate_device(raw: Any) -> dict[str, Any]:
    fields = {"schema_version", "id", "user_id", "role", "platform", "key_provider", "public_key_spki_base64", "status", "created_at", "revoked_at"}
    item = _closed(raw, label="device", required=fields - {"revoked_at"}, allowed=fields)
    _id("device", item["id"]); _id("user", item["user_id"])
    if item["role"] != "air":
        raise ContractError("invalid device role")
    expected = {"macos": "secure-enclave", "windows": "tpm-cng"}
    if item["platform"] not in expected or item["key_provider"] != expected[item["platform"]]:
        raise ContractError("device key provider does not match platform")
    if item["status"] not in {"pending", "active", "revoked"}:
        raise ContractError("invalid device status")
    p256_public_key_der(item["public_key_spki_base64"])
    _timestamp(item["created_at"], "device.created_at")
    if item["status"] == "revoked" and "revoked_at" not in item:
        raise ContractError("revoked device requires revoked_at")
    if "revoked_at" in item:
        _timestamp(item["revoked_at"], "device.revoked_at")
    return item


def p256_public_key_der(value: Any) -> bytes:
    try:
        public_key = base64.b64decode(value, validate=True)
    except Exception as error:
        raise ContractError("invalid device public key") from error
    if len(public_key) != 91 or not public_key.startswith(P256_SPKI_PREFIX):
        raise ContractError("device public key must be a P-256 SPKI public key")
    return public_key


def validate_codex_binding(raw: Any) -> dict[str, Any]:
    fields = {"schema_version", "id", "user_id", "identity_alias", "routing_mode", "status", "created_at", "revoked_at"}
    item = _closed(raw, label="codex_binding", required=fields - {"revoked_at"}, allowed=fields)
    _id("codex_binding", item["id"]); _id("user", item["user_id"])
    if not ALIAS_RE.fullmatch(str(item["identity_alias"])) or item["identity_alias"] in LEGACY_PSEUDO_IDENTITIES:
        raise ContractError("Air Codex identity is invalid or is a legacy pseudo-identity")
    if item["routing_mode"] != "air-fixed" or item["status"] not in {"active", "revoked"}:
        raise ContractError("Air Codex binding must be fixed and active or revoked")
    _timestamp(item["created_at"], "codex_binding.created_at")
    if item["status"] == "revoked" and "revoked_at" not in item:
        raise ContractError("revoked Codex binding requires revoked_at")
    if "revoked_at" in item:
        _timestamp(item["revoked_at"], "codex_binding.revoked_at")
    return item


def validate_grant(raw: Any) -> dict[str, Any]:
    fields = {"schema_version", "id", "user_id", "capability_id", "effect", "status", "scopes", "created_at", "expires_at"}
    item = _closed(raw, label="grant", required=fields - {"expires_at"}, allowed=fields)
    _id("grant", item["id"]); _id("user", item["user_id"])
    if not CAPABILITY_RE.fullmatch(str(item["capability_id"])):
        raise ContractError("invalid grant capability_id")
    if item["effect"] not in {"allow", "deny"} or item["status"] not in {"active", "revoked"}:
        raise ContractError("invalid grant effect or status")
    if not isinstance(item["scopes"], list) or len(item["scopes"]) > 32 or len(item["scopes"]) != len(set(item["scopes"])) or any(not SCOPE_RE.fullmatch(str(scope)) for scope in item["scopes"]):
        raise ContractError("grant scopes must be exact bounded identifiers")
    _timestamp(item["created_at"], "grant.created_at")
    if "expires_at" in item:
        _timestamp(item["expires_at"], "grant.expires_at")
    return item


def validate_content_lease(raw: Any) -> dict[str, Any]:
    fields = {"schema_version", "id", "user_id", "job_id", "kind", "state", "sha256", "size", "receipt_required", "created_at", "expires_at", "received_at", "purged_at"}
    item = _closed(raw, label="content_lease", required=fields - {"received_at", "purged_at"}, allowed=fields)
    _id("content_lease", item["id"]); _id("user", item["user_id"]); _id("job", item["job_id"])
    if item["kind"] not in {"project-capsule", "input-artifact", "result-package"} or item["state"] not in STATE_TRANSITIONS["artifact"]:
        raise ContractError("invalid content lease kind or state")
    if not SHA256_RE.fullmatch(str(item["sha256"])) or type(item["size"]) is not int or not 0 <= item["size"] <= 50 * 1024 * 1024:
        raise ContractError("invalid content lease digest or size")
    if type(item["receipt_required"]) is not bool:
        raise ContractError("content lease receipt_required must be boolean")
    created = _timestamp(item["created_at"], "content_lease.created_at")
    expires = _timestamp(item["expires_at"], "content_lease.expires_at")
    if datetime.fromisoformat(expires.replace("Z", "+00:00")) <= datetime.fromisoformat(created.replace("Z", "+00:00")):
        raise ContractError("content lease must expire after creation")
    if item["state"] == "received" and "received_at" not in item:
        raise ContractError("received content requires received_at")
    if item["state"] == "purged" and "purged_at" not in item:
        raise ContractError("purged content requires purged_at")
    for field in ("received_at", "purged_at"):
        if field in item:
            _timestamp(item[field], f"content_lease.{field}")
    return item


def validate_job(raw: Any) -> dict[str, Any]:
    lease_fields = {"worker_id", "execution_lease_id", "lease_expires_at"}
    execution_fields = {*lease_fields, "attempt", "failure_code"}
    capability_fields = {"capability_id", "capability_input"}
    fields = {"schema_version", "id", "request_id", "user_id", "device_id", "codex_binding_id", "kind", "state", "instruction", "capability_envelope", "content_lease_ids", "created_at", "updated_at", "submission_mode", *execution_fields, *capability_fields}
    item = _closed(
        raw, label="job",
        required=fields - {"updated_at", "submission_mode"} - execution_fields - capability_fields,
        allowed=fields,
    )
    _id("job", item["id"]); _id("user", item["user_id"]); _id("device", item["device_id"]); _id("codex_binding", item["codex_binding_id"])
    if not REQUEST_RE.fullmatch(str(item["request_id"])) or item["kind"] not in {"codex", "capability"} or item["state"] not in STATE_TRANSITIONS["job"]:
        raise ContractError("invalid job request, kind, or state")
    if not isinstance(item["instruction"], str) or not 1 <= len(item["instruction"]) <= 20_000:
        raise ContractError("invalid job instruction")
    envelope = _closed(item["capability_envelope"], label="job.capability_envelope", required={"capabilities", "egress_profile", "secret_access", "result_mode"}, allowed={"schema_version", "capabilities", "egress_profile", "secret_access", "result_mode"})
    capabilities = envelope["capabilities"]
    if not isinstance(capabilities, list) or len(capabilities) > 64 or len(capabilities) != len(set(capabilities)) or any(not CAPABILITY_RE.fullmatch(str(value)) for value in capabilities):
        raise ContractError("invalid capability envelope")
    if item["kind"] == "capability":
        if set(capability_fields) - item.keys() or not CAPABILITY_RE.fullmatch(str(item.get("capability_id", ""))):
            raise ContractError("member capability job is incomplete")
        if capabilities != [item["capability_id"]] or not isinstance(item["capability_input"], dict):
            raise ContractError("member capability job envelope is invalid")
        if len(json.dumps(item["capability_input"], ensure_ascii=False).encode()) > 1024 * 1024:
            raise ContractError("member capability input is too large")
    elif capability_fields & item.keys():
        raise ContractError("Codex job cannot carry a direct capability payload")
    if "submission_mode" in item and (item["kind"] != "codex" or item["submission_mode"] != "capsule-draft"):
        raise ContractError("invalid member job submission mode")
    if item["state"] == "staging" and item.get("submission_mode") != "capsule-draft":
        raise ContractError("staging member job must require a project capsule")
    if envelope["egress_profile"] not in {"none", "registered-only"} or envelope["secret_access"] != "none" or envelope["result_mode"] != "review-only":
        raise ContractError("capability envelope violates member safety profile")
    lease_ids = item["content_lease_ids"]
    if not isinstance(lease_ids, list) or len(lease_ids) > 32 or len(lease_ids) != len(set(lease_ids)):
        raise ContractError("invalid content lease references")
    for value in lease_ids:
        _id("content_lease", value)
    present_lease_fields = lease_fields & item.keys()
    if present_lease_fields:
        if not lease_fields <= item.keys() or "attempt" not in item:
            raise ContractError("member job execution lease is incomplete")
        _id("device", item["worker_id"])
        if not WORK_LEASE_RE.fullmatch(str(item["execution_lease_id"])):
            raise ContractError("invalid member job execution lease")
        if type(item["lease_expires_at"]) is not int or item["lease_expires_at"] < 0:
            raise ContractError("invalid member job lease expiry")
    if "attempt" in item and (type(item["attempt"]) is not int or not 1 <= item["attempt"] <= 3):
        raise ContractError("invalid member job attempt")
    if item["state"] in {"leased", "running", "waiting_user", "uploading"} and not present_lease_fields:
        raise ContractError("active member job requires an execution lease")
    if "failure_code" in item and item["failure_code"] not in {"identity_required", "authorization_required", "execution_failed", "lease_expired"}:
        raise ContractError("invalid member job failure code")
    _timestamp(item["created_at"], "job.created_at")
    if "updated_at" in item:
        _timestamp(item["updated_at"], "job.updated_at")
    return item


def validate_interaction(raw: Any) -> dict[str, Any]:
    optional = {"reply", "replied_at"}
    fields = {
        "schema_version", "id", "user_id", "job_id", "execution_lease_id", "kind", "state",
        "title", "detail", "action_sha256", "created_at", "expires_at", *optional,
    }
    item = _closed(raw, label="interaction", required=fields - optional, allowed=fields)
    _id("interaction", item["id"]); _id("user", item["user_id"]); _id("job", item["job_id"])
    if not WORK_LEASE_RE.fullmatch(str(item["execution_lease_id"])):
        raise ContractError("invalid interaction execution lease")
    if item["kind"] not in {"command-approval", "user-input"} or item["state"] not in STATE_TRANSITIONS["interaction"]:
        raise ContractError("invalid interaction kind or state")
    if not isinstance(item["title"], str) or not 1 <= len(item["title"]) <= 200:
        raise ContractError("invalid interaction title")
    if not isinstance(item["detail"], str) or not 1 <= len(item["detail"]) <= 4000:
        raise ContractError("invalid interaction detail")
    if not SHA256_RE.fullmatch(str(item["action_sha256"])):
        raise ContractError("invalid interaction action digest")
    created = _timestamp(item["created_at"], "interaction.created_at")
    expires = _timestamp(item["expires_at"], "interaction.expires_at")
    if datetime.fromisoformat(expires.replace("Z", "+00:00")) <= datetime.fromisoformat(created.replace("Z", "+00:00")):
        raise ContractError("interaction must expire after creation")
    if item["state"] == "pending":
        if optional & item.keys():
            raise ContractError("pending interaction cannot have a reply")
    else:
        if not optional <= item.keys() or not isinstance(item["reply"], dict):
            raise ContractError("terminal interaction requires a reply")
        reply = item["reply"]
        if set(reply) not in ({"decision"}, {"decision", "answer"}):
            raise ContractError("interaction reply fields are invalid")
        expected = {
            "answered": {"accept", "answer"}, "denied": {"decline"},
            "cancelled": {"cancel"}, "expired": {"cancel"},
        }
        if reply.get("decision") not in expected[item["state"]]:
            raise ContractError("interaction reply does not match state")
        if reply.get("decision") == "answer":
            if item["kind"] != "user-input" or not isinstance(reply.get("answer"), str) or not 1 <= len(reply["answer"]) <= 4000:
                raise ContractError("user-input interaction requires a bounded answer")
        elif reply.get("decision") == "accept" and item["kind"] != "command-approval":
            raise ContractError("only command approvals can be accepted")
        elif "answer" in reply:
            raise ContractError("non-answer interaction cannot carry answer text")
        _timestamp(item["replied_at"], "interaction.replied_at")
    return item


VALIDATORS = {
    "users": validate_user, "devices": validate_device, "codex_bindings": validate_codex_binding,
    "grants": validate_grant, "content_leases": validate_content_lease, "jobs": validate_job,
    "interactions": validate_interaction,
}


def validate_bundle(raw: Any) -> dict[str, Any]:
    fields = {"schema_version", *VALIDATORS.keys()}
    bundle = _closed(raw, label="bundle", required=fields, allowed=fields)
    normalized: dict[str, Any] = {"schema_version": SCHEMA_VERSION}
    indexes: dict[str, dict[str, dict[str, Any]]] = {}
    for collection, validator in VALIDATORS.items():
        values = bundle[collection]
        if not isinstance(values, list) or len(values) > 256:
            raise ContractError(f"{collection} must be a bounded list")
        normalized[collection] = [validator(value) for value in values]
        index = {item["id"]: item for item in normalized[collection]}
        if len(index) != len(values):
            raise ContractError(f"{collection} contains duplicate ids")
        indexes[collection] = index

    active_devices: dict[str, int] = {}
    active_bindings: dict[str, int] = {}
    for device in normalized["devices"]:
        user = indexes["users"].get(device["user_id"])
        if not user:
            raise ContractError("device references an unknown user")
        if device["role"] != "air":
            raise ContractError("every v2 user device must use the unified air role")
        if device["status"] == "active":
            active_devices[device["user_id"]] = active_devices.get(device["user_id"], 0) + 1
    for binding in normalized["codex_bindings"]:
        user = indexes["users"].get(binding["user_id"])
        if not user:
            raise ContractError("Codex binding references an unknown user")
        if binding["identity_alias"] in OWNER_IDENTITY_ALIASES and user["role"] != "owner":
            raise ContractError("owner Codex identity alias is bound to a non-owner user")
        if binding["status"] == "active":
            active_bindings[binding["user_id"]] = active_bindings.get(binding["user_id"], 0) + 1
    if any(count > 1 for count in active_devices.values()):
        raise ContractError("a user has more than one active Air device")
    if any(count > 1 for count in active_bindings.values()):
        raise ContractError("a user has more than one active Codex binding")
    grants_by_user: dict[str, dict[str, set[str]]] = {}
    for grant in normalized["grants"]:
        if grant["user_id"] not in indexes["users"]:
            raise ContractError("grant references an unknown user")
        if grant["status"] == "active":
            grants_by_user.setdefault(grant["user_id"], {}).setdefault(grant["capability_id"], set()).add(grant["effect"])
    for job in normalized["jobs"]:
        user = indexes["users"].get(job["user_id"])
        device = indexes["devices"].get(job["device_id"])
        binding = indexes["codex_bindings"].get(job["codex_binding_id"])
        if not user or not device or not binding:
            raise ContractError("job references unknown user, device, or Codex binding records")
        if device["user_id"] != job["user_id"] or binding["user_id"] != job["user_id"]:
            raise ContractError("cross-tenant job binding rejected")
        active_job = job["state"] in {"staging", "queued", "leased", "running", "waiting_user", "uploading"}
        if active_job and (user["status"] != "active" or device["status"] != "active" or binding["status"] != "active"):
            raise ContractError("job device and Codex binding must be active")
        for capability in job["capability_envelope"]["capabilities"]:
            effects = grants_by_user.get(job["user_id"], {}).get(capability, set())
            if "allow" not in effects or "deny" in effects:
                raise ContractError(f"job capability is not granted: {capability}")
    for lease in normalized["content_leases"]:
        job = indexes["jobs"].get(lease["job_id"])
        if not job or job["user_id"] != lease["user_id"]:
            raise ContractError("cross-tenant content lease rejected")
        if lease["id"] not in job["content_lease_ids"]:
            raise ContractError("content lease is not referenced by its job")
    for interaction in normalized["interactions"]:
        job = indexes["jobs"].get(interaction["job_id"])
        if not job or job["user_id"] != interaction["user_id"]:
            raise ContractError("cross-tenant interaction rejected")
        if interaction["state"] == "pending" and (
            job["state"] != "waiting_user" or job.get("execution_lease_id") != interaction["execution_lease_id"]
        ):
            raise ContractError("pending interaction has no active waiting job lease")
    return normalized


def transition(entity: str, current: str, target: str) -> str:
    transitions = STATE_TRANSITIONS.get(entity)
    if not transitions or current not in transitions or target not in transitions[current]:
        raise ContractError(f"invalid {entity} transition: {current} -> {target}")
    return target


def idempotency_scope(user_id: str, device_id: str, request_id: str) -> str:
    if not REQUEST_RE.fullmatch(request_id):
        raise ContractError("invalid request id")
    return f"{_id('user', user_id)}:{_id('device', device_id)}:{request_id}"


class MemberRegistry:
    """Small atomic registry for v2 principals; no credential material is accepted."""

    def __init__(self, state_path: Path) -> None:
        self.state_path = state_path.resolve()
        self.lock_path = self.state_path.with_suffix(".lock")
        self.thread_lock = threading.RLock()

    @staticmethod
    def empty_bundle() -> dict[str, Any]:
        return {"schema_version": SCHEMA_VERSION, "users": [], "devices": [], "codex_bindings": [], "grants": [], "content_leases": [], "jobs": [], "interactions": []}

    def initialize(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state_path.parent, 0o700)
        self.lock_path.touch(mode=0o600, exist_ok=True)
        os.chmod(self.lock_path, 0o600)
        if not self.state_path.exists():
            self._atomic_write(self.empty_bundle())
        validate_bundle(self.read())

    @contextmanager
    def transaction(self):
        with self.thread_lock, self.lock_path.open("a+b") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def read(self) -> dict[str, Any]:
        if not self.state_path.is_file():
            raise ContractError("member registry is not initialized")
        with self.state_path.open("r", encoding="utf-8") as handle:
            return validate_bundle(json.load(handle))

    def _atomic_write(self, value: dict[str, Any]) -> None:
        validate_bundle(value)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{self.state_path.name}.", dir=str(self.state_path.parent))
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.state_path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    @staticmethod
    def _new_id(prefix: str) -> str:
        return f"{prefix}-{secrets.token_hex(8)}"

    @staticmethod
    def _now() -> str:
        return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    @staticmethod
    def _find(bundle: dict[str, Any], collection: str, item_id: str) -> dict[str, Any]:
        item = next((entry for entry in bundle[collection] if entry["id"] == item_id), None)
        if not item:
            raise ContractError(f"unknown {collection} record")
        return item

    def create_user(self, display_name: str, *, role: str = "member", user_id: str | None = None) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            item = validate_user({"schema_version": SCHEMA_VERSION, "id": user_id or self._new_id("usr"), "role": role, "status": "active", "display_name": display_name, "created_at": self._now()})
            if any(entry["id"] == item["id"] for entry in bundle["users"]):
                raise ContractError("user id already exists")
            bundle["users"].append(item)
            self._atomic_write(bundle)
            return copy.deepcopy(item)

    def provision_air_user(self, display_name: str, identity_alias: str, *, role: str = "member") -> dict[str, Any]:
        """Atomically create one Air user and its fixed isolated Codex reference."""
        with self.transaction():
            bundle = self.read()
            if role not in {"owner", "member"}:
                raise ContractError("Air user role must be owner or member")
            if identity_alias in OWNER_IDENTITY_ALIASES and role != "owner":
                raise ContractError("owner Codex identity aliases require an owner Air user")
            user = validate_user({
                "schema_version": SCHEMA_VERSION,
                "id": self._new_id("usr"),
                "role": role,
                "status": "active",
                "display_name": display_name,
                "created_at": self._now(),
            })
            binding = validate_codex_binding({
                "schema_version": SCHEMA_VERSION,
                "id": self._new_id("cdx"),
                "user_id": user["id"],
                "identity_alias": identity_alias,
                "routing_mode": "air-fixed",
                "status": "active",
                "created_at": self._now(),
            })
            if any(item["identity_alias"] == identity_alias and item["status"] == "active" for item in bundle["codex_bindings"]):
                raise ContractError("Codex identity alias is already bound to an active user")
            bundle["users"].append(user)
            bundle["codex_bindings"].append(binding)
            self._atomic_write(bundle)
            return {"user": copy.deepcopy(user), "codex_binding": copy.deepcopy(binding)}

    def ensure_air_user(self, identity_alias: str, *, role: str = "member") -> dict[str, Any]:
        """Idempotently provision the opaque Air user keyed by its Mini identity alias."""
        with self.transaction():
            bundle = self.read()
            if role not in {"owner", "member"}:
                raise ContractError("Air user role must be owner or member")
            if identity_alias in OWNER_IDENTITY_ALIASES and role != "owner":
                raise ContractError("owner Codex identity aliases require an owner Air user")
            active = next(
                (
                    item for item in bundle["codex_bindings"]
                    if item["identity_alias"] == identity_alias and item["status"] == "active"
                ),
                None,
            )
            if active:
                user = self._find(bundle, "users", active["user_id"])
                if user["status"] != "active" or user["role"] != role or user["display_name"] != identity_alias:
                    raise ContractError("existing Air identity does not match the requested role")
                return {
                    "created": False,
                    "user": copy.deepcopy(user),
                    "codex_binding": copy.deepcopy(active),
                }
            user = validate_user({
                "schema_version": SCHEMA_VERSION,
                "id": self._new_id("usr"),
                "role": role,
                "status": "active",
                "display_name": identity_alias,
                "created_at": self._now(),
            })
            binding = validate_codex_binding({
                "schema_version": SCHEMA_VERSION,
                "id": self._new_id("cdx"),
                "user_id": user["id"],
                "identity_alias": identity_alias,
                "routing_mode": "air-fixed",
                "status": "active",
                "created_at": self._now(),
            })
            bundle["users"].append(user)
            bundle["codex_bindings"].append(binding)
            self._atomic_write(bundle)
            return {
                "created": True,
                "user": copy.deepcopy(user),
                "codex_binding": copy.deepcopy(binding),
            }

    def provision_member(self, display_name: str, identity_alias: str) -> dict[str, Any]:
        """Compatibility alias for the pre-deployment member-only CLI."""
        return self.provision_air_user(display_name, identity_alias, role="member")

    def enroll_device(self, user_id: str, *, platform: str, key_provider: str, public_key_spki_base64: str, device_id: str | None = None) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            user = self._find(bundle, "users", user_id)
            if user["role"] not in {"owner", "member"} or user["status"] != "active":
                raise ContractError("only an active Air user can enroll an Air")
            if any(entry["user_id"] == user_id and entry["status"] == "active" for entry in bundle["devices"]):
                raise ContractError("old active device must be revoked before re-enrollment")
            if any(entry["public_key_spki_base64"] == public_key_spki_base64 and entry["status"] == "active" for entry in bundle["devices"]):
                raise ContractError("device public key is already bound to an active user")
            item = validate_device({"schema_version": SCHEMA_VERSION, "id": device_id or self._new_id("dev"), "user_id": user_id, "role": "air", "platform": platform, "key_provider": key_provider, "public_key_spki_base64": public_key_spki_base64, "status": "active", "created_at": self._now()})
            bundle["devices"].append(item)
            self._atomic_write(bundle)
            return copy.deepcopy(item)

    def revoke_device(self, user_id: str, device_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            item = self._find(bundle, "devices", device_id)
            if item["user_id"] != user_id:
                raise ContractError("cross-tenant device revocation rejected")
            if item["status"] != "revoked":
                item["status"] = "revoked"
                item["revoked_at"] = self._now()
                self._atomic_write(bundle)
            return copy.deepcopy(item)

    def bind_codex(self, user_id: str, identity_alias: str, *, binding_id: str | None = None) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            user = self._find(bundle, "users", user_id)
            if user["role"] not in {"owner", "member"} or user["status"] != "active":
                raise ContractError("only an active Air user can receive a Codex binding")
            if identity_alias in OWNER_IDENTITY_ALIASES and user["role"] != "owner":
                raise ContractError("owner Codex identity aliases require an owner Air user")
            if any(entry["user_id"] == user_id and entry["status"] == "active" for entry in bundle["codex_bindings"]):
                raise ContractError("active Codex binding already exists")
            if any(entry["identity_alias"] == identity_alias and entry["status"] == "active" for entry in bundle["codex_bindings"]):
                raise ContractError("Codex identity alias is already bound to an active user")
            item = validate_codex_binding({"schema_version": SCHEMA_VERSION, "id": binding_id or self._new_id("cdx"), "user_id": user_id, "identity_alias": identity_alias, "routing_mode": "air-fixed", "status": "active", "created_at": self._now()})
            bundle["codex_bindings"].append(item)
            self._atomic_write(bundle)
            return copy.deepcopy(item)

    def revoke_codex_binding(self, user_id: str, binding_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            item = self._find(bundle, "codex_bindings", binding_id)
            if item["user_id"] != user_id:
                raise ContractError("cross-tenant Codex revocation rejected")
            if item["status"] != "revoked":
                item["status"] = "revoked"
                item["revoked_at"] = self._now()
                self._atomic_write(bundle)
            return copy.deepcopy(item)

    def put_grant(self, user_id: str, capability_id: str, scopes: list[str], *, effect: str = "allow", grant_id: str | None = None) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            self._find(bundle, "users", user_id)
            item = validate_grant({"schema_version": SCHEMA_VERSION, "id": grant_id or self._new_id("grant"), "user_id": user_id, "capability_id": capability_id, "effect": effect, "status": "active", "scopes": scopes, "created_at": self._now()})
            bundle["grants"].append(item)
            self._atomic_write(bundle)
            return copy.deepcopy(item)

    def ensure_grant(self, user_id: str, capability_id: str, scopes: list[str], *, effect: str = "allow") -> dict[str, Any]:
        """Create one exact grant, or return the already-active exact grant without duplication."""
        with self.transaction():
            bundle = self.read()
            self._find(bundle, "users", user_id)
            candidate = validate_grant({
                "schema_version": SCHEMA_VERSION,
                "id": self._new_id("grant"),
                "user_id": user_id,
                "capability_id": capability_id,
                "effect": effect,
                "status": "active",
                "scopes": scopes,
                "created_at": self._now(),
            })
            active = [
                item for item in bundle["grants"]
                if item["user_id"] == user_id and item["capability_id"] == capability_id and item["status"] == "active"
            ]
            if active:
                exact = next(
                    (
                        item for item in active
                        if item["effect"] == effect and set(item["scopes"]) == set(candidate["scopes"])
                    ),
                    None,
                )
                if exact and len(active) == 1:
                    return {"created": False, "grant": copy.deepcopy(exact)}
                raise ContractError("existing active grant does not match the requested profile")
            bundle["grants"].append(candidate)
            self._atomic_write(bundle)
            return {"created": True, "grant": copy.deepcopy(candidate)}

    def revoke_grant(self, user_id: str, grant_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            item = self._find(bundle, "grants", grant_id)
            if item["user_id"] != user_id:
                raise ContractError("cross-tenant grant revocation rejected")
            if item["status"] != "revoked":
                item["status"] = "revoked"
                self._atomic_write(bundle)
            return copy.deepcopy(item)

    def create_job(self, user_id: str, device_id: str, codex_binding_id: str, request_id: str, instruction: str, capabilities: list[str], *, job_id: str | None = None, kind: str = "codex", capability_id: str | None = None, capability_input: dict[str, Any] | None = None, initial_state: str = "queued") -> dict[str, Any]:
        if initial_state not in {"staging", "queued"}:
            raise ContractError("member job initial state is invalid")
        with self.transaction():
            bundle = self.read()
            scope = idempotency_scope(user_id, device_id, request_id)
            for existing in bundle["jobs"]:
                if idempotency_scope(existing["user_id"], existing["device_id"], existing["request_id"]) == scope:
                    same_request = (
                        existing["kind"] == kind
                        and existing["codex_binding_id"] == codex_binding_id
                        and existing["instruction"] == instruction
                        and existing["capability_envelope"]["capabilities"] == capabilities
                        and existing.get("capability_id") == capability_id
                        and existing.get("capability_input") == capability_input
                    )
                    if not same_request:
                        raise ContractError("request id already belongs to a different member job")
                    return copy.deepcopy(existing)
            raw_job = {
                "schema_version": SCHEMA_VERSION,
                "id": job_id or self._new_id("job"),
                "request_id": request_id,
                "user_id": user_id,
                "device_id": device_id,
                "codex_binding_id": codex_binding_id,
                "kind": kind,
                "state": initial_state,
                "instruction": instruction,
                "capability_envelope": {
                    "schema_version": SCHEMA_VERSION,
                    "capabilities": capabilities,
                    "egress_profile": "none" if kind == "codex" else "registered-only",
                    "secret_access": "none",
                    "result_mode": "review-only",
                },
                "content_lease_ids": [],
                "created_at": self._now(),
            }
            if kind == "capability":
                raw_job["capability_id"] = capability_id
                raw_job["capability_input"] = capability_input
            if initial_state == "staging":
                raw_job["submission_mode"] = "capsule-draft"
            item = validate_job(raw_job)
            bundle["jobs"].append(item)
            self._atomic_write(bundle)
            return copy.deepcopy(item)

    def create_content_lease(self, user_id: str, job_id: str, *, kind: str, sha256: str, size: int, expires_at: str, receipt_required: bool = True, lease_id: str | None = None, state: str = "staged") -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            job = self._find(bundle, "jobs", job_id)
            if job["user_id"] != user_id:
                raise ContractError("cross-tenant content lease rejected")
            requested_id = lease_id or self._new_id("content")
            existing = next((item for item in bundle["content_leases"] if item["id"] == requested_id), None)
            if existing:
                expected = {
                    "user_id": user_id, "job_id": job_id, "kind": kind, "sha256": sha256,
                    "size": size, "expires_at": expires_at, "receipt_required": receipt_required,
                }
                if all(existing.get(key) == value for key, value in expected.items()):
                    return copy.deepcopy(existing)
                raise ContractError("content request id belongs to different content")
            item = validate_content_lease({
                "schema_version": SCHEMA_VERSION,
                "id": requested_id,
                "user_id": user_id,
                "job_id": job_id,
                "kind": kind,
                "state": state,
                "sha256": sha256,
                "size": size,
                "receipt_required": receipt_required,
                "created_at": self._now(),
                "expires_at": expires_at,
            })
            bundle["content_leases"].append(item)
            job["content_lease_ids"].append(item["id"])
            self._atomic_write(bundle)
            return copy.deepcopy(item)

    def mark_content_available(self, user_id: str, lease_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            lease = self._owned(bundle, "content_leases", _id("content_lease", lease_id), user_id)
            self._owned(bundle, "jobs", lease["job_id"], user_id)
            if lease["state"] == "staged":
                lease["state"] = transition("artifact", lease["state"], "available")
                self._atomic_write(bundle)
            elif lease["state"] != "available":
                raise ContractError("content lease is not publishable")
            return copy.deepcopy(lease)

    def expire_content_for_member(self, user_id: str, lease_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            lease = self._owned(bundle, "content_leases", _id("content_lease", lease_id), user_id)
            job = self._owned(bundle, "jobs", lease["job_id"], user_id)
            if job["state"] in {"leased", "running", "uploading"}:
                raise ContractError("active member content cannot be purged")
            if lease["state"] in {"staged", "available"}:
                lease["state"] = transition("artifact", lease["state"], "expired")
                if job["state"] in {"staging", "queued", "waiting_user"}:
                    if job["state"] == "waiting_user":
                        self._close_pending_interactions(
                            bundle, job["id"], state="expired", replied_at=self._now()
                        )
                    job["state"] = transition("job", job["state"], "expired")
                    job["instruction"] = "[content purged by member]"
                    if "capability_input" in job:
                        job["capability_input"] = {}
                    job["updated_at"] = self._now()
                self._atomic_write(bundle)
            elif lease["state"] not in {"received", "expired", "purged"}:
                raise ContractError("content lease cannot be purged")
            return copy.deepcopy(lease)

    def create_result_lease(
        self, user_id: str, job_id: str, *, sha256: str, size: int, expires_at: str,
        lease_id: str | None = None, state: str = "available",
    ) -> dict[str, Any]:
        return self.create_content_lease(
            user_id, job_id, kind="result-package", sha256=sha256, size=size,
            expires_at=expires_at, receipt_required=True, lease_id=lease_id, state=state,
        )

    def principal(self, user_id: str, device_id: str) -> dict[str, Any]:
        """Resolve an active Air user, device, and fixed Codex binding atomically."""
        with self.transaction():
            bundle = self.read()
            user = self._find(bundle, "users", _id("user", user_id))
            device = self._find(bundle, "devices", _id("device", device_id))
            if user["role"] not in {"owner", "member"} or user["status"] != "active":
                raise TenantAccessError("Air principal is unavailable")
            if device["user_id"] != user_id:
                raise TenantAccessError("cross-tenant device use rejected")
            if device["role"] != "air" or device["status"] != "active":
                raise TenantAccessError("Air device is unavailable")
            bindings = [
                item for item in bundle["codex_bindings"]
                if item["user_id"] == user_id and item["status"] == "active"
            ]
            if len(bindings) != 1:
                raise TenantAccessError("Air Codex binding is unavailable")
            return {
                "user": copy.deepcopy(user),
                "device": copy.deepcopy(device),
                "codex_binding": copy.deepcopy(bindings[0]),
            }

    @staticmethod
    def _owned(bundle: dict[str, Any], collection: str, item_id: str, user_id: str) -> dict[str, Any]:
        item = MemberRegistry._find(bundle, collection, item_id)
        if item.get("user_id") != user_id:
            raise TenantAccessError(f"cross-tenant {collection} access rejected")
        return item

    def list_jobs(self, user_id: str) -> list[dict[str, Any]]:
        with self.transaction():
            bundle = self.read()
            self._find(bundle, "users", _id("user", user_id))
            return [copy.deepcopy(item) for item in bundle["jobs"] if item["user_id"] == user_id]

    def member_job(self, user_id: str, job_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            return copy.deepcopy(self._owned(bundle, "jobs", _id("job", job_id), user_id))

    def member_job_for_worker(self, worker_id: str, job_id: str, execution_lease_id: str) -> dict[str, Any]:
        worker_id = _id("device", worker_id)
        job_id = _id("job", job_id)
        if not WORK_LEASE_RE.fullmatch(str(execution_lease_id)):
            raise TenantAccessError("valid member execution lease is required")
        with self.transaction():
            bundle = self.read()
            job = self._find(bundle, "jobs", job_id)
            if job.get("worker_id") != worker_id or job.get("execution_lease_id") != execution_lease_id:
                raise TenantAccessError("member job is not leased to this worker")
            if job["state"] not in {"leased", "running", "waiting_user", "uploading"}:
                raise TenantAccessError("member job lease is inactive")
            return copy.deepcopy(job)

    @staticmethod
    def _close_pending_interactions(
        bundle: dict[str, Any], job_id: str, *, state: str, replied_at: str
    ) -> None:
        for interaction in bundle["interactions"]:
            if interaction["job_id"] == job_id and interaction["state"] == "pending":
                interaction["state"] = transition("interaction", "pending", state)
                interaction["reply"] = {"decision": "cancel"}
                interaction["replied_at"] = replied_at

    def create_member_interaction(
        self,
        worker_id: str,
        job_id: str,
        execution_lease_id: str,
        *,
        kind: str,
        title: str,
        detail: str,
        action_sha256: str,
        expires_at: str,
        interaction_id: str | None = None,
        now_epoch: int | None = None,
    ) -> dict[str, Any]:
        worker_id = _id("device", worker_id)
        job_id = _id("job", job_id)
        if not WORK_LEASE_RE.fullmatch(str(execution_lease_id)):
            raise TenantAccessError("valid member execution lease is required")
        with self.transaction():
            bundle = self.read()
            job = self._find(bundle, "jobs", job_id)
            if job.get("worker_id") != worker_id or job.get("execution_lease_id") != execution_lease_id:
                raise TenantAccessError("member job is not leased to this worker")
            observed_epoch = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
            if int(job.get("lease_expires_at", 0)) < observed_epoch:
                raise ContractError("member job lease has expired")
            if job["state"] != "running":
                raise ContractError("member interaction requires a running job")
            if any(item["job_id"] == job_id and item["state"] == "pending" for item in bundle["interactions"]):
                raise ContractError("member job already has a pending interaction")
            now = self._now()
            interaction = validate_interaction({
                "schema_version": SCHEMA_VERSION,
                "id": interaction_id or f"ask-{secrets.token_hex(8)}",
                "user_id": job["user_id"],
                "job_id": job_id,
                "execution_lease_id": execution_lease_id,
                "kind": kind,
                "state": "pending",
                "title": title,
                "detail": detail,
                "action_sha256": action_sha256,
                "created_at": now,
                "expires_at": expires_at,
            })
            job["state"] = transition("job", job["state"], "waiting_user")
            job["lease_expires_at"] = observed_epoch + 600
            job["updated_at"] = now
            bundle["interactions"].append(interaction)
            self._atomic_write(bundle)
            return copy.deepcopy(interaction)

    def worker_member_interaction(
        self, worker_id: str, job_id: str, execution_lease_id: str, interaction_id: str,
        *, now_epoch: int | None = None,
    ) -> dict[str, Any]:
        worker_id = _id("device", worker_id)
        job_id = _id("job", job_id)
        interaction_id = _id("interaction", interaction_id)
        if not WORK_LEASE_RE.fullmatch(str(execution_lease_id)):
            raise TenantAccessError("valid member execution lease is required")
        with self.transaction():
            bundle = self.read()
            job = self._find(bundle, "jobs", job_id)
            if job.get("worker_id") != worker_id or job.get("execution_lease_id") != execution_lease_id:
                raise TenantAccessError("member job is not leased to this worker")
            observed_epoch = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
            if job["state"] not in {"running", "waiting_user"} or int(job.get("lease_expires_at", 0)) < observed_epoch:
                raise TenantAccessError("member job lease is inactive")
            interaction = self._find(bundle, "interactions", interaction_id)
            if interaction["job_id"] != job_id or interaction["execution_lease_id"] != execution_lease_id:
                raise TenantAccessError("member interaction is not attached to this job lease")
            return copy.deepcopy(interaction)

    def list_member_interactions(self, user_id: str, job_id: str) -> list[dict[str, Any]]:
        with self.transaction():
            bundle = self.read()
            self._owned(bundle, "jobs", _id("job", job_id), user_id)
            return [
                copy.deepcopy(item) for item in bundle["interactions"]
                if item["job_id"] == job_id and item["user_id"] == user_id
            ]

    def reply_member_interaction(
        self,
        user_id: str,
        job_id: str,
        interaction_id: str,
        *,
        decision: str,
        answer: str | None = None,
    ) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            job = self._owned(bundle, "jobs", _id("job", job_id), user_id)
            interaction = self._owned(bundle, "interactions", _id("interaction", interaction_id), user_id)
            if interaction["job_id"] != job["id"]:
                raise TenantAccessError("member interaction is not attached to this job")
            if interaction["state"] != "pending" or job["state"] != "waiting_user":
                raise ContractError("member interaction is no longer pending")
            now = self._now()
            if datetime.fromisoformat(interaction["expires_at"].replace("Z", "+00:00")) <= datetime.now(timezone.utc):
                interaction["state"] = transition("interaction", interaction["state"], "expired")
                interaction["reply"] = {"decision": "cancel"}
                interaction["replied_at"] = now
                job["state"] = transition("job", job["state"], "queued")
                for field in ("worker_id", "execution_lease_id", "lease_expires_at"):
                    job.pop(field, None)
                job["updated_at"] = now
                self._atomic_write(bundle)
                raise ContractError("member interaction has expired")
            allowed = {"command-approval": {"accept", "decline", "cancel"}, "user-input": {"answer", "decline", "cancel"}}
            if decision not in allowed[interaction["kind"]]:
                raise ContractError("interaction decision does not match kind")
            reply: dict[str, Any] = {"decision": decision}
            if decision == "answer":
                if not isinstance(answer, str) or not 1 <= len(answer) <= 4000:
                    raise ContractError("user-input interaction requires a bounded answer")
                reply["answer"] = answer
            elif answer is not None:
                raise ContractError("only an answer decision can carry answer text")
            target = {"accept": "answered", "answer": "answered", "decline": "denied", "cancel": "cancelled"}[decision]
            interaction["state"] = transition("interaction", interaction["state"], target)
            interaction["reply"] = reply
            interaction["replied_at"] = now
            job["state"] = transition("job", job["state"], "cancelled" if decision == "cancel" else "running")
            job["updated_at"] = now
            self._atomic_write(bundle)
            return copy.deepcopy(interaction)

    def member_content_lease(self, user_id: str, lease_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            lease = self._owned(bundle, "content_leases", _id("content_lease", lease_id), user_id)
            self._owned(bundle, "jobs", lease["job_id"], user_id)
            return copy.deepcopy(lease)

    def confirm_content_receipt(self, user_id: str, lease_id: str, sha256: str) -> dict[str, Any]:
        if not SHA256_RE.fullmatch(str(sha256)):
            raise ContractError("invalid content receipt digest")
        with self.transaction():
            bundle = self.read()
            lease = self._owned(bundle, "content_leases", _id("content_lease", lease_id), user_id)
            self._owned(bundle, "jobs", lease["job_id"], user_id)
            if lease["kind"] != "result-package" or not lease["receipt_required"]:
                raise ContractError("content lease does not accept a receipt")
            if not hmac.compare_digest(lease["sha256"], sha256):
                raise ContractError("content receipt digest mismatch")
            if lease["state"] == "available":
                lease["state"] = transition("artifact", lease["state"], "received")
                lease["received_at"] = self._now()
                for sibling in bundle["content_leases"]:
                    if sibling["job_id"] == lease["job_id"] and sibling["id"] != lease["id"] and sibling["state"] in {"staged", "available"}:
                        sibling["state"] = transition("artifact", sibling["state"], "expired")
                job = self._owned(bundle, "jobs", lease["job_id"], user_id)
                job["instruction"] = "[content purged after receipt]"
                if "capability_input" in job:
                    job["capability_input"] = {}
                job["updated_at"] = self._now()
                self._atomic_write(bundle)
            elif lease["state"] not in {"received", "purged"}:
                raise ContractError("content lease is not receivable")
            return copy.deepcopy(lease)

    def member_job_cleanup_candidates(self, user_id: str, job_id: str) -> list[dict[str, Any]]:
        with self.transaction():
            bundle = self.read()
            self._owned(bundle, "jobs", _id("job", job_id), user_id)
            return [
                copy.deepcopy(lease) for lease in bundle["content_leases"]
                if lease["job_id"] == job_id and lease["user_id"] == user_id and lease["state"] in {"received", "expired"}
            ]

    def prepare_content_cleanup(self, *, now: str | None = None) -> list[dict[str, Any]]:
        observed_at = _timestamp(now or self._now(), "content cleanup time")
        observed = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
        changed = False
        with self.transaction():
            bundle = self.read()
            jobs = {job["id"]: job for job in bundle["jobs"]}
            redact_jobs: set[str] = set()
            ready: list[dict[str, Any]] = []
            for lease in bundle["content_leases"]:
                expires = datetime.fromisoformat(lease["expires_at"].replace("Z", "+00:00"))
                if lease["state"] in {"staged", "available"} and expires <= observed:
                    job = jobs[lease["job_id"]]
                    if job["state"] in {"leased", "running", "uploading"}:
                        continue
                    lease["state"] = transition("artifact", lease["state"], "expired")
                    if job["state"] in {"staging", "queued", "waiting_user"}:
                        if job["state"] == "waiting_user":
                            self._close_pending_interactions(
                                bundle, job["id"], state="expired", replied_at=self._now()
                            )
                        job["state"] = transition("job", job["state"], "expired")
                    redact_jobs.add(job["id"])
                    changed = True
                if lease["state"] in {"received", "expired"}:
                    ready.append(copy.deepcopy(lease))
            for job_id in redact_jobs:
                job = jobs[job_id]
                job["instruction"] = "[content purged after ttl]"
                if "capability_input" in job:
                    job["capability_input"] = {}
                job["updated_at"] = self._now()
            if changed:
                self._atomic_write(bundle)
            return ready

    def mark_content_purged(self, user_id: str, lease_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            lease = self._owned(bundle, "content_leases", _id("content_lease", lease_id), user_id)
            self._owned(bundle, "jobs", lease["job_id"], user_id)
            if lease["state"] == "purged":
                return copy.deepcopy(lease)
            if lease["state"] not in {"received", "expired"}:
                raise ContractError("content lease is not ready to purge")
            lease["state"] = transition("artifact", lease["state"], "purged")
            lease["purged_at"] = self._now()
            self._atomic_write(bundle)
            return copy.deepcopy(lease)

    def member_grants(self, user_id: str) -> list[dict[str, Any]]:
        with self.transaction():
            bundle = self.read()
            user = self._find(bundle, "users", _id("user", user_id))
            if user["role"] not in {"owner", "member"} or user["status"] != "active":
                raise TenantAccessError("Air principal is unavailable")
            return [copy.deepcopy(item) for item in bundle["grants"] if item["user_id"] == user_id]

    def air_user(self, user_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            user = self._find(bundle, "users", _id("user", user_id))
            if user["role"] not in {"owner", "member"} or user["status"] != "active":
                raise TenantAccessError("Air principal is unavailable")
            return copy.deepcopy(user)

    def create_member_job(
        self,
        user_id: str,
        device_id: str,
        request_id: str,
        instruction: str,
        capabilities: list[str],
    ) -> dict[str, Any]:
        principal = self.principal(user_id, device_id)
        return self.create_job(
            user_id,
            device_id,
            principal["codex_binding"]["id"],
            request_id,
            instruction,
            capabilities,
        )

    def create_member_job_draft(
        self,
        user_id: str,
        device_id: str,
        request_id: str,
        instruction: str,
        capabilities: list[str],
    ) -> dict[str, Any]:
        principal = self.principal(user_id, device_id)
        return self.create_job(
            user_id,
            device_id,
            principal["codex_binding"]["id"],
            request_id,
            instruction,
            capabilities,
            initial_state="staging",
        )

    def activate_member_job(self, user_id: str, job_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            job = self._owned(bundle, "jobs", _id("job", job_id), user_id)
            if job["state"] != "staging" or job.get("submission_mode") != "capsule-draft":
                raise ContractError("member job draft is no longer staging")
            capsules = [
                lease for lease in bundle["content_leases"]
                if lease["job_id"] == job["id"] and lease["user_id"] == user_id
                and lease["kind"] == "project-capsule" and lease["state"] == "available"
            ]
            if len(capsules) != 1 or capsules[0]["id"] not in job["content_lease_ids"]:
                raise ContractError("member job draft requires exactly one available project capsule")
            job["state"] = transition("job", job["state"], "queued")
            job["updated_at"] = self._now()
            self._atomic_write(bundle)
            return copy.deepcopy(job)

    def create_member_capability_job(
        self,
        user_id: str,
        device_id: str,
        request_id: str,
        capability_id: str,
        capability_input: dict[str, Any],
    ) -> dict[str, Any]:
        principal = self.principal(user_id, device_id)
        return self.create_job(
            user_id,
            device_id,
            principal["codex_binding"]["id"],
            request_id,
            f"Invoke member capability {capability_id}",
            [capability_id],
            kind="capability",
            capability_id=capability_id,
            capability_input=capability_input,
        )

    def cancel_member_job(self, user_id: str, job_id: str) -> dict[str, Any]:
        with self.transaction():
            bundle = self.read()
            job = self._owned(bundle, "jobs", _id("job", job_id), user_id)
            if job["state"] not in {"staging", "queued", "leased", "running", "waiting_user"}:
                raise ContractError("job can no longer be cancelled")
            now = self._now()
            self._close_pending_interactions(bundle, job["id"], state="cancelled", replied_at=now)
            job["state"] = transition("job", job["state"], "cancelled")
            job["updated_at"] = now
            self._atomic_write(bundle)
            return copy.deepcopy(job)

    def retry_member_job(self, user_id: str, job_id: str) -> dict[str, Any]:
        """Manual member retry; ownership is checked before resetting terminal state."""
        with self.transaction():
            bundle = self.read()
            job = self._owned(bundle, "jobs", _id("job", job_id), user_id)
            if job["state"] not in {"failed", "cancelled", "expired"}:
                raise ContractError("job is not retryable")
            available_capsule = any(
                lease["job_id"] == job["id"] and lease["user_id"] == user_id
                and lease["kind"] == "project-capsule" and lease["state"] == "available"
                for lease in bundle["content_leases"]
            )
            job["state"] = (
                "queued" if job.get("submission_mode") != "capsule-draft" or available_capsule else "staging"
            )
            for field in ("worker_id", "execution_lease_id", "lease_expires_at", "attempt", "failure_code"):
                job.pop(field, None)
            job["updated_at"] = self._now()
            self._atomic_write(bundle)
            return copy.deepcopy(job)

    def lease_member_job(self, worker_id: str, *, now_epoch: int | None = None, ttl: int = 180) -> dict[str, Any] | None:
        """Lease one v2 job and return only its server-authoritative fixed identity alias."""
        worker_id = _id("device", worker_id)
        now = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
        if not 30 <= ttl <= 600:
            raise ContractError("member job lease ttl is invalid")
        with self.transaction():
            bundle = self.read()
            for job in bundle["jobs"]:
                if job["state"] in {"leased", "running", "waiting_user", "uploading"} and int(job.get("lease_expires_at", now + 1)) <= now:
                    changed_at = self._now()
                    self._close_pending_interactions(bundle, job["id"], state="expired", replied_at=changed_at)
                    if job["state"] == "uploading":
                        for content in bundle["content_leases"]:
                            if (
                                content["job_id"] == job["id"]
                                and content["kind"] == "result-package"
                                and content["state"] in {"staged", "available"}
                            ):
                                content["state"] = transition("artifact", content["state"], "expired")
                    if int(job.get("attempt", 1)) >= 3:
                        job["state"] = "failed"
                        job["failure_code"] = "lease_expired"
                    else:
                        job["state"] = "queued"
                        for field in ("worker_id", "execution_lease_id", "lease_expires_at"):
                            job.pop(field, None)
                    job["updated_at"] = changed_at

            queued = sorted((item for item in bundle["jobs"] if item["state"] == "queued"), key=lambda item: (item["created_at"], item["id"]))
            if not queued:
                self._atomic_write(bundle)
                return None
            job = queued[0]
            binding = self._find(bundle, "codex_bindings", job["codex_binding_id"])
            user = self._find(bundle, "users", job["user_id"])
            if binding["user_id"] != job["user_id"] or binding["status"] != "active" or binding["routing_mode"] != "air-fixed":
                raise ContractError("Air job fixed identity binding is unavailable")
            if user["status"] != "active" or user["role"] not in {"owner", "member"}:
                raise ContractError("Air job user is unavailable")
            job["state"] = transition("job", job["state"], "leased")
            job["worker_id"] = worker_id
            job["execution_lease_id"] = f"work-{secrets.token_hex(12)}"
            job["lease_expires_at"] = now + ttl
            job["attempt"] = int(job.get("attempt", 0)) + 1
            job.pop("failure_code", None)
            job["updated_at"] = self._now()
            self._atomic_write(bundle)
            return {
                "job": copy.deepcopy(job),
                "identity_alias": binding["identity_alias"],
                "user_role": user["role"],
            }

    def transition_member_job(
        self,
        worker_id: str,
        job_id: str,
        execution_lease_id: str,
        target: str,
        *,
        failure_code: str | None = None,
        now_epoch: int | None = None,
    ) -> dict[str, Any]:
        worker_id = _id("device", worker_id)
        if not WORK_LEASE_RE.fullmatch(str(execution_lease_id)):
            raise TenantAccessError("valid member job lease is required")
        now = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
        with self.transaction():
            bundle = self.read()
            job = self._find(bundle, "jobs", _id("job", job_id))
            if job.get("worker_id") != worker_id or job.get("execution_lease_id") != execution_lease_id:
                raise TenantAccessError("member job is not leased to this worker")
            if int(job.get("lease_expires_at", 0)) < now:
                raise ContractError("member job lease has expired")
            if job["state"] == "waiting_user" and any(
                item["job_id"] == job["id"] and item["state"] == "pending" for item in bundle["interactions"]
            ):
                raise ContractError("pending member interaction must be answered by its member")
            job["state"] = transition("job", job["state"], target)
            if target in {"running", "waiting_user", "uploading"}:
                job["lease_expires_at"] = now + 180
            if failure_code is not None:
                if target != "failed" or failure_code not in {"identity_required", "authorization_required", "execution_failed", "lease_expired"}:
                    raise ContractError("invalid member job failure code")
                job["failure_code"] = failure_code
            job["updated_at"] = self._now()
            self._atomic_write(bundle)
            return copy.deepcopy(job)

    def heartbeat_member_job(
        self, worker_id: str, job_id: str, execution_lease_id: str, *, now_epoch: int | None = None
    ) -> dict[str, Any]:
        worker_id = _id("device", worker_id)
        if not WORK_LEASE_RE.fullmatch(str(execution_lease_id)):
            raise TenantAccessError("valid member job lease is required")
        now = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
        with self.transaction():
            bundle = self.read()
            job = self._find(bundle, "jobs", _id("job", job_id))
            if job.get("worker_id") != worker_id or job.get("execution_lease_id") != execution_lease_id:
                raise TenantAccessError("member job is not leased to this worker")
            if job["state"] in {"leased", "running", "waiting_user", "uploading"}:
                job["lease_expires_at"] = now + 180
                job["updated_at"] = self._now()
                self._atomic_write(bundle)
            return copy.deepcopy(job)


class MemberEnrollmentStore:
    """One-time member pairing records; only SHA-256 token hashes are persisted."""

    def __init__(self, state_path: Path, registry: MemberRegistry) -> None:
        self.state_path = state_path.resolve()
        self.lock_path = self.state_path.with_suffix(".lock")
        self.registry = registry
        self.thread_lock = threading.RLock()

    @staticmethod
    def empty_state() -> dict[str, Any]:
        return {"schema_version": SCHEMA_VERSION, "enrollments": {}}

    def initialize(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state_path.parent, 0o700)
        self.lock_path.touch(mode=0o600, exist_ok=True)
        os.chmod(self.lock_path, 0o600)
        if not self.state_path.exists():
            self._atomic_write(self.empty_state())
        self.read()

    @contextmanager
    def transaction(self):
        with self.thread_lock, self.lock_path.open("a+b") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    @staticmethod
    def _validate(raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict) or set(raw) != {"schema_version", "enrollments"} or raw.get("schema_version") != SCHEMA_VERSION:
            raise ContractError("member enrollment state is invalid")
        enrollments = raw.get("enrollments")
        if not isinstance(enrollments, dict) or len(enrollments) > 256:
            raise ContractError("member enrollment state is invalid")
        for token_hash, item in enrollments.items():
            if not SHA256_RE.fullmatch(str(token_hash)) or not isinstance(item, dict):
                raise ContractError("member enrollment record is invalid")
            if set(item) != {"user_id", "platform", "key_provider", "created_at", "expires_at_epoch", "used_at"}:
                raise ContractError("member enrollment record is invalid")
            _id("user", item["user_id"])
            expected = {"macos": "secure-enclave", "windows": "tpm-cng"}
            if item["platform"] not in expected or item["key_provider"] != expected[item["platform"]]:
                raise ContractError("member enrollment platform is invalid")
            _timestamp(item["created_at"], "member_enrollment.created_at")
            if type(item["expires_at_epoch"]) is not int or item["expires_at_epoch"] <= 0:
                raise ContractError("member enrollment expiry is invalid")
            if item["used_at"] is not None:
                _timestamp(item["used_at"], "member_enrollment.used_at")
        return copy.deepcopy(raw)

    def read(self) -> dict[str, Any]:
        if not self.state_path.is_file():
            raise ContractError("member enrollment store is not initialized")
        with self.state_path.open("r", encoding="utf-8") as handle:
            return self._validate(json.load(handle))

    def _atomic_write(self, value: dict[str, Any]) -> None:
        self._validate(value)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{self.state_path.name}.", dir=str(self.state_path.parent))
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.state_path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    @staticmethod
    def token_hash(token: str) -> str:
        if not PAIRING_TOKEN_RE.fullmatch(token):
            raise ContractError("invalid member pairing token")
        return hashlib.sha256(token.encode("ascii")).hexdigest()

    def issue(self, user_id: str, platform: str, ttl: int, *, now_epoch: int | None = None) -> str:
        if ttl < 60 or ttl > 86_400:
            raise ContractError("member pairing ttl must be between 60 and 86400 seconds")
        bundle = self.registry.read()
        user = MemberRegistry._find(bundle, "users", _id("user", user_id))
        if user["role"] not in {"owner", "member"} or user["status"] != "active":
            raise ContractError("only an active Air user can receive a pairing token")
        if any(item["user_id"] == user_id and item["status"] == "active" for item in bundle["devices"]):
            raise ContractError("old active device must be revoked before pairing")
        if len([item for item in bundle["codex_bindings"] if item["user_id"] == user_id and item["status"] == "active"]) != 1:
            raise ContractError("Air user requires exactly one active Codex binding before pairing")
        expected = {"macos": "secure-enclave", "windows": "tpm-cng"}
        if platform not in expected:
            raise ContractError("unsupported member Air platform")
        now = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
        token = "pair-" + secrets.token_urlsafe(32)
        token_hash = self.token_hash(token)
        with self.transaction():
            state = self.read()
            state["enrollments"] = {
                key: item for key, item in state["enrollments"].items()
                if item["expires_at_epoch"] >= now and item["used_at"] is None and item["user_id"] != user_id
            }
            state["enrollments"][token_hash] = {
                "user_id": user_id,
                "platform": platform,
                "key_provider": expected[platform],
                "created_at": datetime.fromtimestamp(now, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                "expires_at_epoch": now + ttl,
                "used_at": None,
            }
            self._atomic_write(state)
        return token

    def inspect(self, token: str, *, now_epoch: int | None = None) -> dict[str, Any]:
        now = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
        with self.transaction():
            item = self.read()["enrollments"].get(self.token_hash(token))
            if not item or item["used_at"] is not None or item["expires_at_epoch"] < now:
                raise ContractError("member pairing token is unavailable")
            return copy.deepcopy(item)

    def consume(
        self,
        token: str,
        *,
        public_key_spki_base64: str,
        now_epoch: int | None = None,
    ) -> dict[str, Any]:
        now = int(now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp())
        with self.transaction():
            state = self.read()
            token_hash = self.token_hash(token)
            item = state["enrollments"].get(token_hash)
            if not item or item["used_at"] is not None or item["expires_at_epoch"] < now:
                raise ContractError("member pairing token is unavailable")
            device = self.registry.enroll_device(
                item["user_id"],
                platform=item["platform"],
                key_provider=item["key_provider"],
                public_key_spki_base64=public_key_spki_base64,
            )
            item["used_at"] = datetime.fromtimestamp(now, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
            self._atomic_write(state)
            return device
