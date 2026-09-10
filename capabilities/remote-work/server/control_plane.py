#!/usr/bin/env python3
"""Minimal owner-only Two-Headed-Wu relay.

The service owns only its configured runtime root. TLS termination belongs to a guarded reverse proxy;
the service itself binds loopback by default and never launches remote commands.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, unquote, urlsplit

from member_auth import MemberAuthenticationError, MemberSignatureAuthenticator
from multi_user_contracts import (
    ContractError,
    MemberEnrollmentStore,
    MemberRegistry,
    TenantAccessError,
    p256_public_key_der,
)


VERSION = "0.12.0"
PROTOCOL_VERSION = 2
API_PREFIX = os.environ.get("WU_REMOTE_API_PREFIX", "/two-head-wu/v1").rstrip("/")
MEMBER_API_PREFIX = os.environ.get("WU_REMOTE_MEMBER_API_PREFIX", "/two-head-wu/v2").rstrip("/")
DEFAULT_ROOT = Path(os.environ.get("WU_REMOTE_SERVER_ROOT", "/srv/two-head-wu")).resolve()
MAX_BODY = 70 * 1024 * 1024
MAX_CAPSULE = 50 * 1024 * 1024
MAX_RESULT = 50 * 1024 * 1024
MAX_ARTIFACT = 50 * 1024 * 1024
REQUEST_WINDOW = 300
NONCE_RETENTION = 900
DEVICE_RE = re.compile(r"^dev-[a-z0-9-]{8,96}$")
JOB_RE = re.compile(r"^job-[a-z0-9-]{8,96}$")
MODULE_RE = re.compile(r"^[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$")
MODULE_VERSION_RE = re.compile(r"^[a-f0-9]{16}$")
MODEL_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
TOOL_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
CAPABILITY_RE = re.compile(r"^[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$")
INTERACTION_RE = re.compile(r"^ask-[a-f0-9]{16}$")
LEASE_RE = re.compile(r"^lease-[a-f0-9]{24}$")
HEX_64_RE = re.compile(r"^[a-f0-9]{64}$")
NONCE_RE = re.compile(r"^[a-f0-9]{32}$")
RELEASE_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{12}$")
REQUEST_ID_RE = re.compile(r"^call-[a-f0-9]{24}$")
ARTIFACT_RE = re.compile(r"^art-[a-f0-9]{24}$")
PROJECT_LEASE_RE = re.compile(r"^project-[a-f0-9]{24}$")
OWNER_APPROVAL_SCHEME = "TWO-HEAD-WU-OWNER-APPROVAL-V1"
OWNER_APPROVAL_KEY_SCHEME = "TWO-HEAD-WU-OWNER-APPROVAL-KEY-V1"
OWNER_APPROVAL_WINDOW = 300
MAX_JOB_ATTEMPTS = 3
MAX_PROJECT_DELTA = 8 * 1024 * 1024
MAX_PROJECT_DELTA_ENTRIES = 256
TRANSITIONS = {
    "queued": {"leased", "cancelled", "expired"},
    "leased": {"running", "queued", "failed", "cancelled"},
    "running": {"waiting_user", "uploading", "failed", "cancelled"},
    "waiting_user": {"running", "failed", "cancelled", "expired"},
    "uploading": {"succeeded", "failed"},
    "succeeded": set(),
    "failed": set(),
    "cancelled": set(),
    "expired": set(),
}


class ControlPlaneError(Exception):
    def __init__(self, message: str, status: int = HTTPStatus.BAD_REQUEST) -> None:
        super().__init__(message)
        self.status = int(status)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def write_json(path: Path, value: Any, mode: int = 0o600) -> None:
    atomic_write(path, (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(), mode)


def read_json(path: Path, default: Any = None) -> Any:
    if not path.is_file():
        if default is not None:
            return default
        raise ControlPlaneError("required state is unavailable", HTTPStatus.SERVICE_UNAVAILABLE)
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


class Store:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.lock = threading.RLock()
        self.state_dir = self.root / "state" / "remote-work"
        self.components_dir = self.root / "components" / "published"
        self.capabilities_dir = self.root / "capabilities" / "published"
        self.jobs_dir = self.root / "jobs" / "relay"
        self.member_jobs_dir = self.root / "jobs" / "members-v2"
        self.artifacts_dir = self.root / "artifacts" / "relay"
        self.releases_dir = self.root / "releases"
        self.server_state = self.state_dir / "server.json"
        self.nonce_state = self.state_dir / "nonces.json"
        self.models_state = self.state_dir / "models.json"
        self.member_cleanup_state = self.state_dir / "member-cleanup-v2.json"
        self.owner_approval_state = self.state_dir / "owner-approvals-v2.json"
        self.member_registry = MemberRegistry(self.state_dir / "members-v2.json")
        self.member_enrollments = MemberEnrollmentStore(self.state_dir / "member-enrollments-v2.json", self.member_registry)
        self.process_lock = self.state_dir / ".control-plane.lock"
        self.local_state = threading.local()

    def initialize(self) -> None:
        for path, mode in [
            (self.state_dir, 0o700),
            (self.components_dir, 0o750),
            (self.capabilities_dir, 0o750),
            (self.jobs_dir, 0o750),
            (self.member_jobs_dir, 0o700),
            (self.artifacts_dir, 0o750),
            (self.releases_dir, 0o750),
        ]:
            path.mkdir(parents=True, exist_ok=True, mode=mode)
            os.chmod(path, mode)
        if not self.server_state.exists():
            write_json(
                self.server_state,
                {"schema_version": 1, "devices": {}, "enrollments": {}, "created_at": utc_now()},
            )
        if not self.nonce_state.exists():
            write_json(self.nonce_state, {"schema_version": 1, "nonces": {}})
        if not self.models_state.exists():
            write_json(self.models_state, {"schema_version": 1, "worker_id": None, "models": []})
        if not self.member_cleanup_state.exists():
            write_json(
                self.member_cleanup_state,
                {
                    "schema_version": 1,
                    "result": "never-run",
                    "last_run_at": None,
                    "prepared": 0,
                    "purged": 0,
                    "failure_count": 0,
                    "failure_hashes": [],
                },
            )
        if not self.owner_approval_state.exists():
            write_json(
                self.owner_approval_state,
                {"schema_version": 1, "keys": {}, "nonces": {}},
            )
        self.member_registry.initialize()
        self.member_enrollments.initialize()
        self.process_lock.touch(mode=0o600, exist_ok=True)
        os.chmod(self.process_lock, 0o600)

    @contextmanager
    def transaction(self):
        """Serialize threads and short-lived admin processes against one state root."""
        with self.lock:
            depth = getattr(self.local_state, "transaction_depth", 0)
            if depth:
                self.local_state.transaction_depth = depth + 1
                try:
                    yield
                finally:
                    self.local_state.transaction_depth -= 1
                return
            with self.process_lock.open("a+b") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                self.local_state.transaction_depth = 1
                try:
                    yield
                finally:
                    self.local_state.transaction_depth = 0
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def state(self) -> dict[str, Any]:
        return read_json(self.server_state)

    def save_state(self, value: dict[str, Any]) -> None:
        value["updated_at"] = utc_now()
        write_json(self.server_state, value)

    def member_content_path(self, lease: dict[str, Any]) -> Path:
        directory = self.member_jobs_dir / str(lease["job_id"])
        if lease["kind"] == "result-package":
            return directory / "results" / f"{lease['id']}.tar.gz"
        if lease["kind"] == "project-capsule":
            return directory / "project.tar.gz"
        if lease["kind"] == "input-artifact":
            return directory / "inputs" / f"{lease['id']}.bin"
        raise ControlPlaneError("content lease kind is unavailable", HTTPStatus.SERVICE_UNAVAILABLE)

    def member_content_metadata_path(self, lease: dict[str, Any]) -> Path:
        path = self.member_content_path(lease)
        return path.with_name(f"{path.name}.json")

    @staticmethod
    def member_content_id(user_id: str, job_id: str, request_id: str) -> str:
        if not REQUEST_ID_RE.fullmatch(request_id):
            raise ControlPlaneError("invalid member content request id")
        digest = hashlib.sha256(f"{user_id}\0{job_id}\0{request_id}".encode()).hexdigest()[:24]
        return f"content-{digest}"

    @staticmethod
    def member_result_content_id(user_id: str, job_id: str, execution_lease_id: str) -> str:
        if not re.fullmatch(r"work-[a-f0-9]{24}", execution_lease_id):
            raise ControlPlaneError("invalid member result execution lease")
        digest = hashlib.sha256(
            f"{user_id}\0{job_id}\0result-package\0{execution_lease_id}".encode()
        ).hexdigest()[:24]
        return f"content-{digest}"

    def create_member_content(self, user_id: str, job_id: str, payload: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
        allowed = {"request_id", "kind", "filename", "media_type", "sha256", "content_base64"}
        if set(payload) != allowed:
            raise ContractError("member content requires exactly request_id, kind, filename, media_type, sha256, and content_base64")
        job = self.member_registry.member_job(user_id, job_id)
        if job["state"] not in {"staging", "queued"}:
            raise ControlPlaneError("member job no longer accepts content", HTTPStatus.CONFLICT)
        kind = str(payload["kind"])
        if kind not in {"project-capsule", "input-artifact"}:
            raise ContractError("member input content kind is invalid")
        filename = self.validate_artifact_name(payload["filename"])
        if kind == "project-capsule" and not filename.lower().endswith(".tar.gz"):
            raise ContractError("member project capsule must be a tar.gz archive")
        media_type = str(payload["media_type"])
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-/]{0,126}", media_type):
            raise ContractError("member content media type is invalid")
        try:
            content = base64.b64decode(payload["content_base64"], validate=True)
        except (ValueError, TypeError):
            raise ContractError("member content encoding is invalid")
        if not content or len(content) > MAX_ARTIFACT:
            raise ControlPlaneError("member content is empty or too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        digest = hashlib.sha256(content).hexdigest()
        if not hmac.compare_digest(digest, str(payload["sha256"])):
            raise ContractError("member content hash mismatch")
        lease_id = self.member_content_id(user_id, job_id, str(payload["request_id"]))
        existing_leases = [
            self.member_registry.member_content_lease(user_id, value) for value in job["content_lease_ids"]
        ]
        existing_size = sum(item["size"] for item in existing_leases if item["id"] != lease_id and item["state"] != "purged")
        if existing_size + len(content) > MAX_CAPSULE:
            raise ControlPlaneError("member job content exceeds the aggregate limit", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        if kind == "project-capsule" and any(item["kind"] == kind and item["id"] != lease_id for item in existing_leases):
            raise ControlPlaneError("member job already has a project capsule", HTTPStatus.CONFLICT)
        existing_lease = next((item for item in existing_leases if item["id"] == lease_id), None)
        expires_at = existing_lease["expires_at"] if existing_lease else (
            (datetime.now(timezone.utc) + timedelta(days=14)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        )
        lease = self.member_registry.create_content_lease(
            user_id, job_id, kind=kind, sha256=digest, size=len(content), expires_at=expires_at,
            receipt_required=False, lease_id=lease_id, state="staged",
        )
        metadata = {
            "schema_version": 2, "id": lease_id, "user_id": user_id, "job_id": job_id,
            "filename": filename, "media_type": media_type, "sha256": digest, "size": len(content),
        }
        path = self.member_content_path(lease)
        existing_metadata = read_json(self.member_content_metadata_path(lease), {})
        if lease["state"] == "available":
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest or existing_metadata != metadata:
                raise ControlPlaneError("member content idempotency state is inconsistent", HTTPStatus.SERVICE_UNAVAILABLE)
            return lease, metadata
        atomic_write(path, content)
        write_json(self.member_content_metadata_path(lease), metadata)
        return self.member_registry.mark_content_available(user_id, lease_id), metadata

    def purge_member_content(self, user_id: str, lease_id: str) -> dict[str, Any]:
        lease = self.member_registry.expire_content_for_member(user_id, lease_id)
        if lease["state"] == "purged":
            return lease
        for path in (self.member_content_path(lease), self.member_content_metadata_path(lease)):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            except OSError as error:
                raise ControlPlaneError("member content cleanup failed", HTTPStatus.SERVICE_UNAVAILABLE) from error
        return self.member_registry.mark_content_purged(user_id, lease_id)

    def confirm_member_content_receipt(self, user_id: str, lease_id: str, sha256: str) -> dict[str, Any]:
        lease = self.member_registry.member_content_lease(user_id, lease_id)
        if lease["state"] == "available":
            path = self.member_content_path(lease)
            if not path.is_file() or not hmac.compare_digest(hashlib.sha256(path.read_bytes()).hexdigest(), lease["sha256"]):
                raise ControlPlaneError("member content failed receipt verification", HTTPStatus.SERVICE_UNAVAILABLE)
        lease = self.member_registry.confirm_content_receipt(user_id, lease_id, sha256)
        for candidate in self.member_registry.member_job_cleanup_candidates(user_id, lease["job_id"]):
            for path in (self.member_content_path(candidate), self.member_content_metadata_path(candidate)):
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
                except OSError as error:
                    raise ControlPlaneError("member content cleanup failed", HTTPStatus.SERVICE_UNAVAILABLE) from error
            self.member_registry.mark_content_purged(user_id, candidate["id"])
        return self.member_registry.member_content_lease(user_id, lease_id)

    def cleanup_member_content(self, *, now: str | None = None) -> dict[str, Any]:
        ready = self.member_registry.prepare_content_cleanup(now=now)
        purged = []
        failures = []
        for lease in ready:
            try:
                for path in (self.member_content_path(lease), self.member_content_metadata_path(lease)):
                    try:
                        path.unlink()
                    except FileNotFoundError:
                        pass
                purged.append(self.member_registry.mark_content_purged(lease["user_id"], lease["id"])["id"])
            except OSError:
                failures.append(lease["id"])
        result = {"prepared": len(ready), "purged": sorted(purged), "failures": sorted(failures)}
        write_json(
            self.member_cleanup_state,
            {
                "schema_version": 1,
                "result": "failed" if failures else "ok",
                "last_run_at": utc_now(),
                "prepared": len(ready),
                "purged": len(purged),
                "failure_count": len(failures),
                "failure_hashes": sorted(hashlib.sha256(value.encode()).hexdigest()[:16] for value in failures),
            },
        )
        return result

    def issue_enrollment(self, device_name: str, role: str, ttl: int) -> str:
        if role not in {"owner-air", "mac-mini-worker", "mac-mini-air-worker"}:
            raise ControlPlaneError("unsupported device role")
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", device_name):
            raise ControlPlaneError("invalid device name")
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        with self.transaction():
            state = self.state()
            state.setdefault("enrollments", {})[digest] = {
                "device_name": device_name,
                "role": role,
                "expires_at": int(time.time()) + ttl,
                "used": False,
                "created_at": utc_now(),
            }
            self.save_state(state)
        return token

    def enrollment(self, token: str, *, consume: bool) -> dict[str, Any]:
        digest = hashlib.sha256(token.encode()).hexdigest()
        with self.transaction():
            state = self.state()
            entry = state.get("enrollments", {}).get(digest)
            if not entry or entry.get("used") or int(entry.get("expires_at", 0)) < int(time.time()):
                raise ControlPlaneError("enrollment is invalid or expired", HTTPStatus.UNAUTHORIZED)
            if consume:
                entry["used"] = True
                entry["used_at"] = utc_now()
                self.save_state(state)
            return dict(entry)

    def enroll(self, token: str, requested_name: str) -> dict[str, str]:
        with self.transaction():
            enrollment = self.enrollment(token, consume=False)
            expected = enrollment["device_name"]
            if requested_name != expected:
                raise ControlPlaneError("device name does not match enrollment", HTTPStatus.FORBIDDEN)
            self.enrollment(token, consume=True)
            device_id = f"dev-{requested_name}-{secrets.token_hex(4)}"
            device_secret = secrets.token_urlsafe(32)
            state = self.state()
            state.setdefault("devices", {})[device_id] = {
                "name": requested_name,
                "role": enrollment["role"],
                "secret": device_secret,
                "enabled": True,
                "created_at": utc_now(),
                "last_seen_at": utc_now(),
                "last_seen_epoch": int(time.time()),
            }
            self.save_state(state)
            return {"device_id": device_id, "device_secret": device_secret, "role": enrollment["role"]}

    def device(self, device_id: str) -> dict[str, Any]:
        if not DEVICE_RE.fullmatch(device_id):
            raise ControlPlaneError("invalid device", HTTPStatus.UNAUTHORIZED)
        entry = self.state().get("devices", {}).get(device_id)
        if not entry or not entry.get("enabled"):
            raise ControlPlaneError("device is not authorized", HTTPStatus.UNAUTHORIZED)
        return dict(entry, id=device_id)

    def touch_device(self, device_id: str) -> None:
        with self.transaction():
            state = self.state()
            entry = state.get("devices", {}).get(device_id)
            if not entry:
                return
            now = int(time.time())
            if now - int(entry.get("last_seen_epoch", 0)) < 30:
                return
            entry["last_seen_epoch"] = now
            entry["last_seen_at"] = utc_now()
            self.save_state(state)

    def update_presence(self, device_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        raw = payload.get("capabilities", [])
        if not isinstance(raw, list) or len(raw) > 32:
            raise ControlPlaneError("invalid device capabilities")
        capabilities = []
        for value in raw:
            text = str(value)
            if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", text):
                raise ControlPlaneError("invalid device capability")
            capabilities.append(text)
        runtime_catalog = self.validate_runtime_catalog(payload.get("runtime_catalog"))
        with self.transaction():
            state = self.state()
            entry = state.get("devices", {}).get(device_id)
            if not entry:
                raise ControlPlaneError("device is unavailable", HTTPStatus.NOT_FOUND)
            entry["capabilities"] = sorted(set(capabilities))
            entry["runtime_version"] = str(payload.get("runtime_version", ""))[:64]
            entry["runtime_catalog"] = runtime_catalog
            entry["protocol_min"] = runtime_catalog["protocol_min"]
            entry["protocol_max"] = runtime_catalog["protocol_max"]
            entry["last_seen_epoch"] = int(time.time())
            entry["last_seen_at"] = utc_now()
            self.save_state(state)
        return self.public_device(device_id, entry)

    @staticmethod
    def validate_runtime_catalog(raw: Any) -> dict[str, Any]:
        if raw is None:
            return {
                "schema_version": 1,
                "protocol_min": 1,
                "protocol_max": 1,
                "runtimes": [],
            }
        if not isinstance(raw, dict) or raw.get("schema_version") != 1:
            raise ControlPlaneError("invalid runtime catalog")
        protocol_min = raw.get("protocol_min")
        protocol_max = raw.get("protocol_max")
        if not isinstance(protocol_min, int) or not isinstance(protocol_max, int) or not 1 <= protocol_min <= protocol_max <= 100:
            raise ControlPlaneError("invalid runtime protocol range")
        runtimes_raw = raw.get("runtimes")
        if not isinstance(runtimes_raw, list) or len(runtimes_raw) > 64:
            raise ControlPlaneError("invalid runtime entries")
        runtimes = []
        for item in runtimes_raw:
            if not isinstance(item, dict):
                raise ControlPlaneError("invalid runtime entry")
            runtime_kind = str(item.get("runtime_kind", ""))
            native_hash = str(item.get("native_schema_hash", ""))
            health = str(item.get("health", ""))
            features = item.get("supported_features", [])
            valid = (
                re.fullmatch(r"[a-z][a-z0-9-]{0,63}", runtime_kind)
                and HEX_64_RE.fullmatch(native_hash)
                and health in {"compatible", "testing", "incompatible", "unavailable"}
                and isinstance(features, list)
                and len(features) <= 64
                and all(re.fullmatch(r"[a-z][a-z0-9-]{0,63}", str(value)) for value in features)
            )
            if not valid:
                raise ControlPlaneError("invalid runtime entry")
            runtimes.append({
                "runtime_kind": runtime_kind,
                "runtime_version": str(item.get("runtime_version", ""))[:128],
                "native_schema_hash": native_hash,
                "adapter_version": str(item.get("adapter_version", ""))[:64],
                "health": health,
                "supported_features": sorted(set(str(value) for value in features)),
                "diagnostic": str(item.get("diagnostic", ""))[:500] or None,
            })
        return {
            "schema_version": 1,
            "protocol_min": protocol_min,
            "protocol_max": protocol_max,
            "runtimes": runtimes,
        }

    def public_device(self, device_id: str, entry: dict[str, Any]) -> dict[str, Any]:
        last_seen_epoch = int(entry.get("last_seen_epoch", 0))
        age = max(0, int(time.time()) - last_seen_epoch) if last_seen_epoch else None
        protocol_min = int(entry.get("protocol_min", 1))
        protocol_max = int(entry.get("protocol_max", 1))
        compatible = protocol_min <= PROTOCOL_VERSION <= protocol_max
        return {
            "id": device_id,
            "name": entry.get("name"),
            "role": entry.get("role"),
            "enabled": bool(entry.get("enabled")),
            "online": bool(entry.get("enabled")) and age is not None and age <= 90,
            "last_seen_at": entry.get("last_seen_at"),
            "age_seconds": age,
            "capabilities": entry.get("capabilities", []),
            "runtime_version": entry.get("runtime_version"),
            "protocol_min": protocol_min,
            "protocol_max": protocol_max,
            "compatibility": "compatible" if compatible else "incompatible",
            "runtime_catalog": entry.get("runtime_catalog", {
                "schema_version": 1,
                "protocol_min": protocol_min,
                "protocol_max": protocol_max,
                "runtimes": [],
            }),
        }

    def devices(self) -> list[dict[str, Any]]:
        state = self.state()
        return [self.public_device(device_id, entry) for device_id, entry in sorted(state.get("devices", {}).items())]

    def check_nonce(self, device_id: str, nonce: str, timestamp: int) -> None:
        if not NONCE_RE.fullmatch(nonce):
            raise ControlPlaneError("invalid request nonce", HTTPStatus.UNAUTHORIZED)
        with self.transaction():
            state = read_json(self.nonce_state, {"schema_version": 1, "nonces": {}})
            now = int(time.time())
            entries = state.setdefault("nonces", {})
            entries = {key: value for key, value in entries.items() if int(value) >= now - NONCE_RETENTION}
            key = f"{device_id}:{nonce}"
            if key in entries:
                raise ControlPlaneError("request replay rejected", HTTPStatus.UNAUTHORIZED)
            entries[key] = timestamp
            state["nonces"] = entries
            write_json(self.nonce_state, state)

    @staticmethod
    def owner_approval_key_canonical(user_id: str, device_id: str, public_key_spki_base64: str) -> bytes:
        return "\n".join([
            OWNER_APPROVAL_KEY_SCHEME,
            user_id,
            device_id,
            public_key_spki_base64,
        ]).encode("utf-8")

    @staticmethod
    def owner_approval_canonical(
        user_id: str,
        device_id: str,
        request_id: str,
        capability_id: str,
        input_sha256: str,
        expires_at: int,
        nonce: str,
    ) -> bytes:
        return "\n".join([
            OWNER_APPROVAL_SCHEME,
            user_id,
            device_id,
            request_id,
            capability_id,
            input_sha256,
            str(expires_at),
            nonce,
        ]).encode("utf-8")

    @staticmethod
    def canonical_capability_input(value: dict[str, Any]) -> bytes:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")

    def owner_approval_key_status(self, principal: dict[str, Any]) -> dict[str, Any]:
        if principal["user"]["role"] != "owner":
            raise ControlPlaneError("owner approval is unavailable", HTTPStatus.FORBIDDEN)
        with self.transaction():
            state = read_json(self.owner_approval_state)
            entry = state.get("keys", {}).get(principal["device"]["id"])
            registered = bool(
                isinstance(entry, dict)
                and entry.get("user_id") == principal["user"]["id"]
                and entry.get("status") == "active"
            )
            return {
                "schema_version": 1,
                "registered": registered,
                "public_key_sha256": entry.get("public_key_sha256") if registered else None,
            }

    def register_owner_approval_key(
        self,
        principal: dict[str, Any],
        payload: dict[str, Any],
        verifier: Callable[[bytes, bytes, bytes], bool] | None,
    ) -> dict[str, Any]:
        if principal["user"]["role"] != "owner":
            raise ControlPlaneError("owner approval is unavailable", HTTPStatus.FORBIDDEN)
        if verifier is None:
            raise ControlPlaneError("owner approval verifier is unavailable", HTTPStatus.SERVICE_UNAVAILABLE)
        if set(payload) != {"public_key_spki_base64", "proof_signature_base64"} or not all(
            isinstance(payload.get(field), str) for field in payload
        ):
            raise ControlPlaneError("owner approval key registration is invalid")
        public_text = str(payload["public_key_spki_base64"])
        try:
            public_der = p256_public_key_der(public_text)
            signature = base64.b64decode(payload["proof_signature_base64"], validate=True)
        except (ContractError, ValueError, TypeError) as error:
            raise ControlPlaneError("owner approval key registration is invalid") from error
        if not 8 <= len(signature) <= 80:
            raise ControlPlaneError("owner approval key registration is invalid")
        user_id = principal["user"]["id"]
        device_id = principal["device"]["id"]
        canonical = self.owner_approval_key_canonical(user_id, device_id, public_text)
        if not verifier(public_der, signature, canonical):
            raise ControlPlaneError("owner approval key proof failed", HTTPStatus.UNAUTHORIZED)
        digest = hashlib.sha256(public_der).hexdigest()
        with self.transaction():
            state = read_json(self.owner_approval_state)
            keys = state.setdefault("keys", {})
            existing = keys.get(device_id)
            if existing and (
                existing.get("user_id") != user_id
                or existing.get("public_key_sha256") != digest
                or existing.get("status") != "active"
            ):
                raise ControlPlaneError(
                    "owner approval key is already registered; Mini revocation is required",
                    HTTPStatus.CONFLICT,
                )
            if not existing:
                keys[device_id] = {
                    "user_id": user_id,
                    "public_key_spki_base64": public_text,
                    "public_key_sha256": digest,
                    "status": "active",
                    "created_at": utc_now(),
                }
                write_json(self.owner_approval_state, state)
            return {
                "schema_version": 1,
                "registered": True,
                "public_key_sha256": digest,
            }

    def verify_owner_approval(
        self,
        principal: dict[str, Any],
        request_id: str,
        capability_id: str,
        capability_input: dict[str, Any],
        approval: Any,
        verifier: Callable[[bytes, bytes, bytes], bool] | None,
    ) -> None:
        if principal["user"]["role"] != "owner" or verifier is None:
            raise ControlPlaneError("owner approval is unavailable", HTTPStatus.FORBIDDEN)
        if not isinstance(approval, dict) or set(approval) != {
            "input_sha256", "expires_at", "nonce", "signature_base64"
        }:
            raise ControlPlaneError("owner approval is required", HTTPStatus.FORBIDDEN)
        input_sha256 = str(approval.get("input_sha256", ""))
        nonce = str(approval.get("nonce", ""))
        expires_at = approval.get("expires_at")
        if (
            not HEX_64_RE.fullmatch(input_sha256)
            or not NONCE_RE.fullmatch(nonce)
            or type(expires_at) is not int
        ):
            raise ControlPlaneError("owner approval is invalid", HTTPStatus.FORBIDDEN)
        actual_input_sha256 = hashlib.sha256(self.canonical_capability_input(capability_input)).hexdigest()
        now = int(time.time())
        if (
            not hmac.compare_digest(input_sha256, actual_input_sha256)
            or expires_at < now
            or expires_at > now + OWNER_APPROVAL_WINDOW
        ):
            raise ControlPlaneError("owner approval is invalid or expired", HTTPStatus.FORBIDDEN)
        try:
            signature = base64.b64decode(str(approval.get("signature_base64", "")), validate=True)
        except (ValueError, TypeError) as error:
            raise ControlPlaneError("owner approval is invalid", HTTPStatus.FORBIDDEN) from error
        if not 8 <= len(signature) <= 80:
            raise ControlPlaneError("owner approval is invalid", HTTPStatus.FORBIDDEN)

        user_id = principal["user"]["id"]
        device_id = principal["device"]["id"]
        with self.transaction():
            state = read_json(self.owner_approval_state)
            entry = state.get("keys", {}).get(device_id)
            if not isinstance(entry, dict) or entry.get("user_id") != user_id or entry.get("status") != "active":
                raise ControlPlaneError("owner approval key is not registered", HTTPStatus.FORBIDDEN)
            try:
                public_der = base64.b64decode(entry["public_key_spki_base64"], validate=True)
            except (ValueError, TypeError, KeyError) as error:
                raise ControlPlaneError("owner approval key is unavailable", HTTPStatus.SERVICE_UNAVAILABLE) from error
            canonical = self.owner_approval_canonical(
                user_id, device_id, request_id, capability_id, input_sha256, expires_at, nonce
            )
            if not verifier(public_der, signature, canonical):
                raise ControlPlaneError("owner approval signature failed", HTTPStatus.FORBIDDEN)
            nonces = {
                key: value for key, value in state.setdefault("nonces", {}).items()
                if isinstance(value, int) and value >= now
            }
            nonce_key = f"{device_id}:{nonce}"
            if nonce_key in nonces:
                raise ControlPlaneError("owner approval replay rejected", HTTPStatus.FORBIDDEN)
            nonces[nonce_key] = expires_at
            state["nonces"] = nonces
            write_json(self.owner_approval_state, state)

    def manifest(self, *, member: bool = False, user_role: str | None = None) -> dict[str, Any]:
        filename = "manifest.json"
        if member:
            filename = "owner-air-manifest.json" if user_role == "owner" else "air-manifest.json"
        value = read_json(self.components_dir / filename)
        if value.get("schema_version") != 2 or not isinstance(value.get("modules"), list):
            raise ControlPlaneError("module manifest is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
        if not HEX_64_RE.fullmatch(str(value.get("public_key_sha256", ""))) or not isinstance(value.get("signature_base64"), str):
            raise ControlPlaneError("module manifest signature metadata is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
        for item in value["modules"]:
            valid = isinstance(item, dict) and MODULE_RE.fullmatch(str(item.get("id", "")))
            if not valid or item.get("classification") not in {"portable", "remote-only"}:
                raise ControlPlaneError("module manifest contains an invalid entry", HTTPStatus.SERVICE_UNAVAILABLE)
        return value

    def capability_manifest(self, *, member: bool = False, user_role: str | None = None) -> dict[str, Any]:
        filename = "manifest.json"
        if member:
            filename = "owner-air-manifest.json" if user_role == "owner" else "air-manifest.json"
        value = read_json(self.capabilities_dir / filename)
        capabilities = value.get("capabilities")
        valid_header = (
            value.get("schema_version") == 1
            and re.fullmatch(r"[a-f0-9]{16}", str(value.get("catalog_version", "")))
            and isinstance(capabilities, list)
            and len(capabilities) <= 256
            and HEX_64_RE.fullmatch(str(value.get("public_key_sha256", "")))
            and isinstance(value.get("signature_base64"), str)
        )
        if not valid_header:
            raise ControlPlaneError("capability manifest is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
        ids: set[str] = set()
        for item in capabilities:
            valid = (
                isinstance(item, dict)
                and CAPABILITY_RE.fullmatch(str(item.get("id", "")))
                and item.get("kind") in {"artifact", "capability", "codex-task", "database-query", "mcp-tool", "memory", "model-catalog", "skill", "tool", "workflow"}
                and item.get("location") in {"air", "mac-mini", "aliyun"}
                and item.get("exposure") in {"callable", "metadata-only"}
                and item.get("invocation_policy") in {"auto", "queue", "confirm", "manual", "unavailable"}
                and item.get("side_effect") in {"read-only", "local-write", "isolated-write", "external-write", "destructive", "metadata-only"}
                and item.get("status") in {"active", "disabled"}
                and isinstance(item.get("queueable"), bool)
                and isinstance(item.get("summary"), str)
                and bool(item.get("summary"))
                and ("name" not in item or (isinstance(item.get("name"), str) and 0 < len(item["name"]) <= 160))
                and isinstance(item.get("runtime_requires", []), list)
                and ("audience" not in item or item.get("audience") in {"all-air", "owner-air", "owner-step-up"})
                and ("confirmation" not in item or item.get("confirmation") in {"none", "owner-password"})
                and ("executor" not in item or item.get("executor") in {"air-worker", "protected-adapter"})
            )
            if not valid or item["id"] in ids:
                raise ControlPlaneError("capability manifest contains an invalid entry", HTTPStatus.SERVICE_UNAVAILABLE)
            requirements = item.get("runtime_requires", [])
            if len(requirements) > 32 or any(not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", str(value)) for value in requirements):
                raise ControlPlaneError("capability manifest contains invalid runtime requirements", HTTPStatus.SERVICE_UNAVAILABLE)
            ids.add(item["id"])
        return value

    def member_capability_directory(self, user_id: str) -> dict[str, Any]:
        user = self.member_registry.air_user(user_id)
        catalog = self.capability_manifest(member=True, user_role=user["role"])
        catalog_ids = {item["id"] for item in catalog["capabilities"] if item["status"] == "active"}
        grants = self.member_registry.member_grants(user_id)
        effects: dict[str, set[str]] = {}
        scopes: dict[str, set[str]] = {}
        now = datetime.now(timezone.utc)
        for grant in grants:
            if grant["status"] != "active":
                continue
            expires_at = grant.get("expires_at")
            if expires_at and datetime.fromisoformat(expires_at.replace("Z", "+00:00")) <= now:
                continue
            capability_id = grant["capability_id"]
            effects.setdefault(capability_id, set()).add(grant["effect"])
            if grant["effect"] == "allow":
                scopes.setdefault(capability_id, set()).update(grant["scopes"])
        effective = sorted(
            capability_id for capability_id in catalog_ids
            if "allow" in effects.get(capability_id, set()) and "deny" not in effects.get(capability_id, set())
        )
        return {
            "schema_version": 2,
            "observed_at": utc_now(),
            "catalog": catalog,
            "effective_grants": [
                {"capability_id": capability_id, "scopes": sorted(scopes.get(capability_id, set()))}
                for capability_id in effective
            ],
        }

    def authorize_member_capabilities(self, user_id: str, capabilities: list[str], *, require_project: bool = False) -> None:
        directory = self.member_capability_directory(user_id)
        effective = {item["capability_id"] for item in directory["effective_grants"]}
        requested = set(capabilities)
        if not requested or (require_project and "codex:project-task" not in requested) or not requested <= effective:
            raise ControlPlaneError("member capability is unavailable or not granted", HTTPStatus.FORBIDDEN)

    def authorize_member_capability_input(
        self, user_id: str, capability_id: str, capability_input: dict[str, Any]
    ) -> None:
        directory = self.member_capability_directory(user_id)
        grant = next(
            (
                item for item in directory["effective_grants"]
                if item["capability_id"] == capability_id
            ),
            None,
        )
        if not grant:
            raise ControlPlaneError("Air capability is unavailable or not granted", HTTPStatus.FORBIDDEN)
        scopes = set(grant["scopes"])
        scoped_value = None
        if capability_id == "memory:notebook":
            scoped_value = capability_input.get("action")
        elif capability_id == "workflow:publish-site":
            scoped_value = capability_input.get("site_id")
        if scoped_value is not None and scoped_value not in scopes:
            raise ControlPlaneError("Air capability input is outside its grant scope", HTTPStatus.FORBIDDEN)

    def member_module_directory(self, user_id: str) -> dict[str, Any]:
        user = self.member_registry.air_user(user_id)
        catalog = self.manifest(member=True, user_role=user["role"])
        catalog_ids = {item["id"] for item in catalog["modules"] if item["status"] == "active"}
        effects: dict[str, set[str]] = {}
        now = datetime.now(timezone.utc)
        for grant in self.member_registry.member_grants(user_id):
            if grant["status"] != "active":
                continue
            expires_at = grant.get("expires_at")
            if expires_at and datetime.fromisoformat(expires_at.replace("Z", "+00:00")) <= now:
                continue
            module_id = grant["capability_id"]
            effects.setdefault(module_id, set()).add(grant["effect"])
        effective = sorted(
            module_id for module_id in catalog_ids
            if "allow" in effects.get(module_id, set()) and "deny" not in effects.get(module_id, set())
        )
        return {
            "schema_version": 2,
            "observed_at": utc_now(),
            "catalog": catalog,
            "effective_modules": effective,
        }

    def authorize_member_module(self, user_id: str, module_id: str) -> None:
        if module_id not in self.member_module_directory(user_id)["effective_modules"]:
            raise ControlPlaneError("member module is unavailable or not granted", HTTPStatus.FORBIDDEN)

    def capability_inventory(self) -> dict[str, Any]:
        value = read_json(self.capabilities_dir / "inventory.json")
        entries = value.get("entries")
        valid_header = (
            value.get("schema_version") == 1
            and re.fullmatch(r"[a-f0-9]{16}", str(value.get("inventory_version", "")))
            and value.get("source_device") == "mac-mini"
            and isinstance(entries, list)
            and len(entries) <= 512
            and HEX_64_RE.fullmatch(str(value.get("public_key_sha256", "")))
            and isinstance(value.get("signature_base64"), str)
        )
        if not valid_header:
            raise ControlPlaneError("capability inventory is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
        allowed_fields = {
            "id", "kind", "name", "summary", "status", "air_mode", "location",
            "version", "native_status", "category", "callable_via",
        }
        kinds = {"skill", "capability-package", "agent", "mcp-server", "runtime", "workflow", "resource"}
        air_modes = {"local", "portable", "remote-auto", "remote-queue", "confirm", "metadata-only", "unavailable"}
        locations = {"air", "mac-mini", "aliyun", "external"}
        ids: set[str] = set()
        for item in entries:
            valid = (
                isinstance(item, dict)
                and not (set(item) - allowed_fields)
                and re.fullmatch(r"(?:skill|package|agent|mcp|runtime|workflow|resource):[a-z][a-z0-9-]*", str(item.get("id", "")))
                and item.get("kind") in kinds
                and item.get("air_mode") in air_modes
                and item.get("location") in locations
                and isinstance(item.get("name"), str)
                and 0 < len(item.get("name", "")) <= 160
                and isinstance(item.get("summary"), str)
                and 0 < len(item.get("summary", "")) <= 1000
                and re.fullmatch(r"[a-z][a-z0-9-]{0,63}", str(item.get("status", "")))
            )
            if not valid or item["id"] in ids:
                raise ControlPlaneError("capability inventory contains an invalid entry", HTTPStatus.SERVICE_UNAVAILABLE)
            if "callable_via" in item and not CAPABILITY_RE.fullmatch(str(item["callable_via"])):
                raise ControlPlaneError("capability inventory contains an invalid invocation route", HTTPStatus.SERVICE_UNAVAILABLE)
            for field in ("version", "native_status", "category"):
                if field in item and (not isinstance(item[field], str) or not 0 < len(item[field]) <= 160):
                    raise ControlPlaneError("capability inventory contains invalid metadata", HTTPStatus.SERVICE_UNAVAILABLE)
            ids.add(item["id"])
        return value

    def capability_directory(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "protocol_version": PROTOCOL_VERSION,
            "observed_at": utc_now(),
            "catalog": self.capability_manifest(),
            "inventory": self.capability_inventory(),
            "modules": self.manifest(),
            "runtime": {
                "devices": self.devices(),
                "models": self.models(),
            },
        }

    def release_manifest(self, channel: str) -> dict[str, Any]:
        if channel not in {"stable", "dev"}:
            raise ControlPlaneError("release channel is unavailable", HTTPStatus.NOT_FOUND)
        value = read_json(self.releases_dir / "manifests" / f"{channel}.json")
        if value.get("channel") != channel or not RELEASE_RE.fullmatch(str(value.get("release_id", ""))):
            raise ControlPlaneError("release manifest is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
        return value

    def release_by_id(self, release_id: str) -> tuple[dict[str, Any], Path]:
        if not RELEASE_RE.fullmatch(release_id):
            raise ControlPlaneError("release id is invalid")
        manifest = read_json(self.releases_dir / "manifests" / "releases" / f"{release_id}.json")
        if manifest.get("release_id") != release_id:
            raise ControlPlaneError("release manifest is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
        archive = self.releases_dir / "archives" / f"{release_id}.tar.gz"
        if not archive.is_file():
            raise ControlPlaneError("release archive is unavailable", HTTPStatus.NOT_FOUND)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest.get("sha256"):
            raise ControlPlaneError("release archive failed server verification", HTTPStatus.SERVICE_UNAVAILABLE)
        return manifest, archive

    def module(self, module_id: str, *, member: bool = False, user_role: str | None = None) -> dict[str, Any]:
        item = next((entry for entry in self.manifest(member=member, user_role=user_role)["modules"] if entry.get("id") == module_id), None)
        if not item:
            raise ControlPlaneError("module is unavailable", HTTPStatus.NOT_FOUND)
        return item

    def module_version(self, module_id: str, version: str | None, *, member: bool = False, user_role: str | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
        item = self.module(module_id, member=member, user_role=user_role)
        selected = version or item.get("version")
        if not MODULE_VERSION_RE.fullmatch(str(selected or "")):
            raise ControlPlaneError("module version is invalid")
        versions = item.get("versions")
        if isinstance(versions, list):
            record = next((entry for entry in versions if isinstance(entry, dict) and entry.get("version") == selected), None)
        else:
            record = item if item.get("version") == selected else None
        if not record:
            raise ControlPlaneError("module version is unavailable", HTTPStatus.NOT_FOUND)
        return item, record

    def models(self) -> dict[str, Any]:
        value = read_json(self.models_state, {"schema_version": 1, "worker_id": None, "models": []})
        return {
            "schema_version": 1,
            "updated_at": value.get("updated_at"),
            "models": value.get("models", []),
        }

    def update_models(self, worker_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        raw_models = payload.get("models")
        if not isinstance(raw_models, list) or len(raw_models) > 100:
            raise ControlPlaneError("invalid model catalog")
        models = []
        for raw in raw_models:
            if not isinstance(raw, dict):
                raise ControlPlaneError("invalid model entry")
            model_id = str(raw.get("id", ""))
            if not MODEL_RE.fullmatch(model_id):
                raise ControlPlaneError("invalid model id")
            efforts = raw.get("efforts", [])
            if not isinstance(efforts, list) or len(efforts) > 20:
                raise ControlPlaneError("invalid model efforts")
            clean_efforts = []
            for effort in efforts:
                value = str(effort)
                if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", value):
                    raise ControlPlaneError("invalid reasoning effort")
                clean_efforts.append(value)
            models.append({
                "id": model_id,
                "display_name": str(raw.get("display_name", model_id))[:128],
                "default_effort": str(raw.get("default_effort", ""))[:32] or None,
                "efforts": clean_efforts,
                "is_default": bool(raw.get("is_default", False)),
            })
        record = {
            "schema_version": 1,
            "worker_id": worker_id,
            "updated_at": utc_now(),
            "models": models,
        }
        with self.transaction():
            write_json(self.models_state, record)
        return self.models()

    def job_dir(self, job_id: str) -> Path:
        if not JOB_RE.fullmatch(job_id):
            raise ControlPlaneError("invalid job id")
        return self.jobs_dir / job_id

    def artifact_dir(self, artifact_id: str) -> Path:
        if not ARTIFACT_RE.fullmatch(artifact_id):
            raise ControlPlaneError("invalid artifact id")
        return self.artifacts_dir / artifact_id

    @staticmethod
    def validate_artifact_name(value: Any) -> str:
        name = str(value or "").strip()
        if not name or name in {".", ".."} or Path(name).name != name:
            raise ControlPlaneError("invalid artifact filename")
        if len(name.encode("utf-8")) > 255 or any(ord(character) < 32 for character in name):
            raise ControlPlaneError("invalid artifact filename")
        lowered = name.lower()
        forbidden_names = {"auth.json", ".env", ".env.local"}
        forbidden_suffixes = (".key", ".pem", ".p12", ".pfx")
        if lowered in forbidden_names or lowered.endswith(forbidden_suffixes):
            raise ControlPlaneError("credential-shaped artifacts are forbidden")
        if re.fullmatch(r"(?:credentials?|secrets?|tokens?)(?:\..*)?", lowered) or re.fullmatch(r"auth.*\.json", lowered):
            raise ControlPlaneError("credential-shaped artifacts are forbidden")
        return name

    def artifact(self, artifact_id: str) -> dict[str, Any]:
        return read_json(self.artifact_dir(artifact_id) / "artifact.json")

    def artifact_by_request(self, device_id: str, request_id: str) -> dict[str, Any] | None:
        if not REQUEST_ID_RE.fullmatch(request_id):
            raise ControlPlaneError("invalid request id")
        for path in self.artifacts_dir.glob("art-*/artifact.json"):
            try:
                item = read_json(path)
            except (OSError, json.JSONDecodeError):
                continue
            if item.get("device_id") == device_id and item.get("request_id") == request_id:
                return item
        return None

    def create_artifact(self, device_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        request_id = str(payload.get("request_id", "")) or f"call-{secrets.token_hex(12)}"
        if not REQUEST_ID_RE.fullmatch(request_id):
            raise ControlPlaneError("invalid request id")
        filename = self.validate_artifact_name(payload.get("filename"))
        media_type = str(payload.get("media_type", "application/octet-stream"))
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-/]{0,126}", media_type):
            raise ControlPlaneError("invalid artifact media type")
        encoded = payload.get("content_base64")
        if not isinstance(encoded, str):
            raise ControlPlaneError("missing artifact content")
        try:
            content = base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError):
            raise ControlPlaneError("invalid artifact encoding")
        if not content:
            raise ControlPlaneError("artifact is empty")
        if len(content) > MAX_ARTIFACT:
            raise ControlPlaneError("artifact is too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        digest = hashlib.sha256(content).hexdigest()
        if not hmac.compare_digest(digest, str(payload.get("sha256", ""))):
            raise ControlPlaneError("artifact hash mismatch")
        artifact_id = f"art-{secrets.token_hex(12)}"
        item = {
            "schema_version": 1,
            "id": artifact_id,
            "request_id": request_id,
            "owner": "example-owner",
            "device_id": device_id,
            "filename": filename,
            "media_type": media_type,
            "sha256": digest,
            "size": len(content),
            "state": "active",
            "created_at": utc_now(),
            "expires_at": int(time.time()) + 14 * 24 * 60 * 60,
        }
        with self.transaction():
            existing = self.artifact_by_request(device_id, request_id)
            if existing:
                if existing.get("sha256") != digest or existing.get("filename") != filename:
                    raise ControlPlaneError("request id already belongs to a different artifact", HTTPStatus.CONFLICT)
                return existing
            directory = self.artifact_dir(artifact_id)
            directory.mkdir(parents=True, exist_ok=False, mode=0o700)
            atomic_write(directory / "content.bin", content)
            write_json(directory / "artifact.json", item)
        return item

    def create_job_output_artifact(
        self, worker_id: str, job_id: str, lease_id: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        with self.transaction():
            job = self.job(job_id)
            if job.get("worker_id") != worker_id or job.get("lease_id") != lease_id:
                raise ControlPlaneError("job is not leased to this worker", HTTPStatus.FORBIDDEN)
            if (
                job.get("kind") != "capability"
                or job.get("capability_id") != "research-library:export"
                or job.get("owner_confirmed") is not True
            ):
                raise ControlPlaneError("job cannot publish a research artifact", HTTPStatus.FORBIDDEN)
            if job.get("state") not in {"running", "uploading"}:
                raise ControlPlaneError("job is not ready to publish an artifact", HTTPStatus.CONFLICT)

            item = self.create_artifact(str(job["device_id"]), payload)
            output_ids = list(job.get("output_artifact_ids", []))
            if item["id"] not in output_ids:
                output_ids.append(item["id"])
            job["output_artifact_ids"] = output_ids
            self.save_job(job)
            self.event(job_id, "artifact.output-created", "Mac mini 已中继一份选定的资料库原件", artifact_id=item["id"])
        return item

    def list_artifacts(self, device_id: str) -> list[dict[str, Any]]:
        self.expire_artifacts()
        items = []
        for path in sorted(self.artifacts_dir.glob("art-*/artifact.json"), reverse=True):
            try:
                item = read_json(path)
            except (OSError, json.JSONDecodeError):
                continue
            if item.get("device_id") == device_id:
                items.append(public_artifact(item))
        return items

    def expire_artifacts(self) -> None:
        now = int(time.time())
        with self.transaction():
            active_refs = set()
            for path in self.jobs_dir.glob("job-*/job.json"):
                try:
                    job = read_json(path)
                except (OSError, json.JSONDecodeError):
                    continue
                if job.get("state") not in {"succeeded", "failed", "cancelled", "expired"}:
                    active_refs.update(job.get("artifact_ids", []))
                    active_refs.update(job.get("output_artifact_ids", []))
            for path in self.artifacts_dir.glob("art-*/artifact.json"):
                try:
                    item = read_json(path)
                except (OSError, json.JSONDecodeError):
                    continue
                if item.get("state") != "active" or int(item.get("expires_at", 0)) > now or item.get("id") in active_refs:
                    continue
                try:
                    (path.parent / "content.bin").unlink()
                except FileNotFoundError:
                    pass
                item["state"] = "expired"
                item["expired_at"] = utc_now()
                write_json(path, item)

    def remove_artifact(self, artifact_id: str) -> dict[str, Any]:
        with self.transaction():
            item = self.artifact(artifact_id)
            if item.get("state") == "removed":
                return item
            for path in self.jobs_dir.glob("job-*/job.json"):
                job = read_json(path)
                attached = artifact_id in job.get("artifact_ids", []) or artifact_id in job.get("output_artifact_ids", [])
                if attached and job.get("state") not in {"succeeded", "failed", "cancelled", "expired"}:
                    raise ControlPlaneError("artifact belongs to an active job", HTTPStatus.CONFLICT)
            try:
                (self.artifact_dir(artifact_id) / "content.bin").unlink()
            except FileNotFoundError:
                pass
            item["state"] = "removed"
            item["removed_at"] = utc_now()
            write_json(self.artifact_dir(artifact_id) / "artifact.json", item)
            return item

    def resolve_job_artifacts(self, device_id: str, raw_ids: Any) -> list[dict[str, Any]]:
        if raw_ids is None:
            return []
        if not isinstance(raw_ids, list) or len(raw_ids) > 10:
            raise ControlPlaneError("invalid artifact list")
        if len(set(str(value) for value in raw_ids)) != len(raw_ids):
            raise ControlPlaneError("duplicate artifact id")
        resolved = []
        total = 0
        for raw in raw_ids:
            artifact_id = str(raw)
            if not ARTIFACT_RE.fullmatch(artifact_id):
                raise ControlPlaneError("invalid artifact id")
            item = self.artifact(artifact_id)
            if item.get("device_id") != device_id or item.get("state") != "active":
                raise ControlPlaneError("artifact is not available to this device", HTTPStatus.FORBIDDEN)
            if int(item.get("expires_at", 0)) <= int(time.time()):
                raise ControlPlaneError("artifact has expired", HTTPStatus.GONE)
            total += int(item.get("size", 0))
            if total > MAX_ARTIFACT:
                raise ControlPlaneError("job artifacts are too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            resolved.append(public_artifact(item))
        return resolved

    def job(self, job_id: str) -> dict[str, Any]:
        return read_json(self.job_dir(job_id) / "job.json")

    def save_job(self, job: dict[str, Any]) -> None:
        job["updated_at"] = utc_now()
        write_json(self.job_dir(job["id"]) / "job.json", job)

    def event(self, job_id: str, event_type: str, message: str, **payload: Any) -> dict[str, Any]:
        with self.transaction():
            directory = self.job_dir(job_id)
            events_path = directory / "events.json"
            value = read_json(events_path, {"schema_version": 1, "events": []})
            events = value.setdefault("events", [])
            event = {
                "id": f"evt-{secrets.token_hex(8)}",
                "sequence": len(events) + 1,
                "type": event_type,
                "message": message[:2000],
                "created_at": utc_now(),
                **payload,
            }
            events.append(event)
            write_json(events_path, value)
            return event

    def interactions(self, job_id: str) -> list[dict[str, Any]]:
        value = read_json(self.job_dir(job_id) / "interactions.json", {"schema_version": 1, "interactions": []})
        return list(value.get("interactions", []))

    def create_interaction(self, job_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        kind = str(payload.get("kind", ""))
        if kind not in {"command-approval", "file-change-approval", "user-input", "permissions-approval"}:
            raise ControlPlaneError("unsupported interaction kind")
        prompt = payload.get("prompt", {})
        if not isinstance(prompt, dict):
            raise ControlPlaneError("invalid interaction prompt")
        encoded = json.dumps(prompt, ensure_ascii=False).encode()
        if len(encoded) > 64 * 1024:
            raise ControlPlaneError("interaction prompt is too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        interaction = {
            "id": f"ask-{secrets.token_hex(8)}",
            "kind": kind,
            "status": "pending",
            "prompt": prompt,
            "created_at": utc_now(),
        }
        with self.transaction():
            job = self.job(job_id)
            if job.get("state") != "running":
                raise ControlPlaneError("job cannot request user interaction", HTTPStatus.CONFLICT)
            path = self.job_dir(job_id) / "interactions.json"
            value = read_json(path, {"schema_version": 1, "interactions": []})
            value.setdefault("interactions", []).append(interaction)
            write_json(path, value)
            job["state"] = "waiting_user"
            self.save_job(job)
            self.event(job_id, "job.waiting_user", "Mac mini 正在等待你的选择", interaction_id=interaction["id"], interaction_kind=kind)
        return interaction

    def interaction(self, job_id: str, interaction_id: str) -> dict[str, Any]:
        if not INTERACTION_RE.fullmatch(interaction_id):
            raise ControlPlaneError("invalid interaction id")
        item = next((entry for entry in self.interactions(job_id) if entry.get("id") == interaction_id), None)
        if not item:
            raise ControlPlaneError("interaction is unavailable", HTTPStatus.NOT_FOUND)
        return item

    def expire_pending_interactions(self, job_id: str, reason: str) -> None:
        path = self.job_dir(job_id) / "interactions.json"
        value = read_json(path, {"schema_version": 1, "interactions": []})
        changed = False
        for item in value.get("interactions", []):
            if item.get("status") == "pending":
                item["status"] = "expired"
                item["expired_at"] = utc_now()
                item["expiry_reason"] = reason[:500]
                changed = True
        if changed:
            write_json(path, value)

    def retry_requires_confirmation(self, job_id: str) -> bool:
        for item in self.interactions(job_id):
            if item.get("status") != "answered":
                continue
            if item.get("kind") not in {"command-approval", "permissions-approval"}:
                continue
            if item.get("reply", {}).get("decision") in {"accept", "acceptForSession"}:
                return True
        return False

    def reply_interaction(self, job_id: str, interaction_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        decision = payload.get("decision")
        answers = payload.get("answers")
        if decision is not None and decision not in {"accept", "acceptForSession", "decline", "cancel"}:
            raise ControlPlaneError("invalid interaction decision")
        if answers is not None:
            if not isinstance(answers, dict) or len(answers) > 10:
                raise ControlPlaneError("invalid interaction answers")
            for key, value in answers.items():
                if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", str(key)) or not isinstance(value, list):
                    raise ControlPlaneError("invalid interaction answer")
                if len(value) > 10 or any(not isinstance(item, str) or len(item) > 10_000 for item in value):
                    raise ControlPlaneError("invalid interaction answer")
        if decision is None and answers is None:
            raise ControlPlaneError("interaction reply is empty")
        with self.transaction():
            job = self.job(job_id)
            path = self.job_dir(job_id) / "interactions.json"
            value = read_json(path, {"schema_version": 1, "interactions": []})
            item = next((entry for entry in value.get("interactions", []) if entry.get("id") == interaction_id), None)
            if not item:
                raise ControlPlaneError("interaction is unavailable", HTTPStatus.NOT_FOUND)
            if item.get("status") != "pending":
                raise ControlPlaneError("interaction was already answered", HTTPStatus.CONFLICT)
            item["status"] = "answered"
            item["answered_at"] = utc_now()
            item["reply"] = {"decision": decision, "answers": answers}
            write_json(path, value)
            if job.get("state") == "waiting_user":
                job["state"] = "running"
                self.save_job(job)
            self.event(job_id, "job.user_replied", "Air 已回复 Mac mini 的请求", interaction_id=interaction_id)
            return item

    def create_job(self, device_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        # 0.8 Air clients used the fixed owner alias. Accept that one legacy
        # envelope during the signed-client rollout, but never preserve it as
        # an execution instruction: all owner work is normalized to the Mini
        # owner-only selector.
        if payload.get("identity") not in {"owner-auto", "owner-primary"}:
            raise ControlPlaneError("owner jobs must use the owner automatic identity pool")
        instruction = str(payload.get("instruction", "")).strip()
        if not instruction or len(instruction) > 100_000:
            raise ControlPlaneError("invalid instruction")
        request_id = str(payload.get("request_id", "")) or f"call-{secrets.token_hex(12)}"
        if not REQUEST_ID_RE.fullmatch(request_id):
            raise ControlPlaneError("invalid request id")
        encoded = payload.get("capsule_base64")
        if not isinstance(encoded, str):
            raise ControlPlaneError("missing capsule")
        try:
            capsule = base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError):
            raise ControlPlaneError("invalid capsule encoding")
        if len(capsule) > MAX_CAPSULE:
            raise ControlPlaneError("capsule is too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        digest = hashlib.sha256(capsule).hexdigest()
        if not hmac.compare_digest(digest, str(payload.get("capsule_sha256", ""))):
            raise ControlPlaneError("capsule hash mismatch")
        input_artifacts = self.resolve_job_artifacts(device_id, payload.get("artifact_ids"))
        project_mode = str(payload.get("project_mode", "workspace-write"))
        if project_mode not in {"review", "workspace-write", "full-project"}:
            raise ControlPlaneError("invalid project mode")
        base_manifest = self.validate_project_manifest(payload.get("project_manifest", {}))
        project_lease_id = f"project-{secrets.token_hex(12)}"
        job_id = f"job-{int(time.time())}-{secrets.token_hex(5)}"
        model_value = payload.get("model")
        effort_value = payload.get("effort")
        if model_value is not None and not isinstance(model_value, str):
            raise ControlPlaneError("invalid model")
        if effort_value is not None and not isinstance(effort_value, str):
            raise ControlPlaneError("invalid reasoning effort")
        job = {
            "schema_version": 1,
            "id": job_id,
            "request_id": request_id,
            "kind": "codex",
            "owner": "example-owner",
            "device_id": device_id,
            "state": "queued",
            "instruction": instruction,
            "identity": "owner-auto",
            "model": model_value or None,
            "effort": effort_value or None,
            "project_name": str(payload.get("project_name", "project"))[:128],
            "capsule_sha256": digest,
            "capsule_size": len(capsule),
            "artifact_ids": [item["id"] for item in input_artifacts],
            "input_artifacts": input_artifacts,
            "project_lease_id": project_lease_id,
            "project_mode": project_mode,
            "project_manifest": base_manifest,
            "project_delta_sequence": 0,
            "project_lease_expires_at": int(time.time()) + 6 * 60 * 60,
            "attempt": 0,
            "max_attempts": MAX_JOB_ATTEMPTS,
            "recovery_count": 0,
            "created_at": utc_now(),
            "updated_at": utc_now(),
        }
        if job["model"] is not None and not MODEL_RE.fullmatch(job["model"]):
            raise ControlPlaneError("invalid model")
        if job["effort"] is not None and not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", job["effort"]):
            raise ControlPlaneError("invalid reasoning effort")
        catalog = self.models().get("models", [])
        if job["model"] is not None and catalog:
            model = next((item for item in catalog if item.get("id") == job["model"]), None)
            if not model:
                raise ControlPlaneError("model is not advertised by the Mac mini worker")
            if job["effort"] is not None and job["effort"] not in model.get("efforts", []):
                raise ControlPlaneError("reasoning effort is not supported by the selected model")
        with self.transaction():
            existing = self.job_by_request(device_id, request_id)
            if existing:
                return existing
            directory = self.job_dir(job_id)
            directory.mkdir(parents=True, exist_ok=False, mode=0o700)
            atomic_write(directory / "capsule.tar.gz", capsule)
            write_json(directory / "project-deltas.json", {"schema_version": 1, "deltas": []})
            self.save_job(job)
            self.event(job_id, "job.queued", "任务已进入 Mac mini 队列")
        return job

    @staticmethod
    def validate_project_manifest(raw: Any) -> dict[str, str]:
        if not isinstance(raw, dict) or len(raw) > 20_000:
            raise ControlPlaneError("invalid project manifest")
        clean: dict[str, str] = {}
        for path, digest in raw.items():
            relative = str(path)
            parts = Path(relative).parts
            if (
                not relative
                or len(relative.encode("utf-8")) > 4096
                or Path(relative).is_absolute()
                or ".." in parts
                or not HEX_64_RE.fullmatch(str(digest))
            ):
                raise ControlPlaneError("invalid project manifest entry")
            clean[relative] = str(digest)
        return dict(sorted(clean.items()))

    @staticmethod
    def validate_project_delta_entries(raw: Any) -> list[dict[str, Any]]:
        if not isinstance(raw, list) or len(raw) > MAX_PROJECT_DELTA_ENTRIES:
            raise ControlPlaneError("invalid project delta")
        entries = []
        total = 0
        for item in raw:
            if not isinstance(item, dict):
                raise ControlPlaneError("invalid project delta entry")
            relative = str(item.get("path", ""))
            parts = Path(relative).parts
            operation = str(item.get("operation", ""))
            base_digest = item.get("base_sha256")
            if (
                not relative
                or len(relative.encode("utf-8")) > 4096
                or Path(relative).is_absolute()
                or ".." in parts
                or operation not in {"upsert", "delete"}
                or (base_digest is not None and not HEX_64_RE.fullmatch(str(base_digest)))
            ):
                raise ControlPlaneError("invalid project delta entry")
            lowered = Path(relative).name.lower()
            if lowered in {".env", ".env.local", "auth.json"} or lowered.endswith((".key", ".pem", ".p12", ".pfx")):
                raise ControlPlaneError("credential-shaped project delta is forbidden")
            record = {"path": relative, "operation": operation, "base_sha256": base_digest}
            if operation == "upsert":
                encoded = item.get("content_base64")
                digest = str(item.get("sha256", ""))
                if not isinstance(encoded, str) or not HEX_64_RE.fullmatch(digest):
                    raise ControlPlaneError("invalid project delta content")
                try:
                    content = base64.b64decode(encoded, validate=True)
                except (ValueError, TypeError):
                    raise ControlPlaneError("invalid project delta encoding")
                total += len(content)
                if total > MAX_PROJECT_DELTA:
                    raise ControlPlaneError("project delta is too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                if not hmac.compare_digest(hashlib.sha256(content).hexdigest(), digest):
                    raise ControlPlaneError("project delta hash mismatch")
                record.update({"sha256": digest, "content_base64": encoded})
            entries.append(record)
        return entries

    def append_project_delta(self, job_id: str, project_lease_id: str, raw_entries: Any) -> dict[str, Any]:
        entries = self.validate_project_delta_entries(raw_entries)
        with self.transaction():
            job = self.job(job_id)
            if job.get("project_lease_id") != project_lease_id:
                raise ControlPlaneError("project lease is invalid", HTTPStatus.FORBIDDEN)
            if job.get("state") not in {"queued", "leased", "running", "waiting_user"}:
                raise ControlPlaneError("project lease is no longer active", HTTPStatus.CONFLICT)
            if int(job.get("project_lease_expires_at", 0)) < int(time.time()):
                raise ControlPlaneError("project lease has expired", HTTPStatus.GONE)
            path = self.job_dir(job_id) / "project-deltas.json"
            value = read_json(path, {"schema_version": 1, "deltas": []})
            sequence = int(job.get("project_delta_sequence", 0)) + 1
            delta = {"sequence": sequence, "created_at": utc_now(), "entries": entries}
            value.setdefault("deltas", []).append(delta)
            write_json(path, value)
            job["project_delta_sequence"] = sequence
            self.save_job(job)
            self.event(job_id, "project.delta.available", "Air 项目增量已进入任务中继", delta_sequence=sequence)
            return delta

    def project_deltas(self, job_id: str, after: int) -> list[dict[str, Any]]:
        value = read_json(self.job_dir(job_id) / "project-deltas.json", {"schema_version": 1, "deltas": []})
        return [item for item in value.get("deltas", []) if int(item.get("sequence", 0)) > after]

    def tools(self) -> dict[str, Any]:
        entries = []
        for capability in self.capability_manifest()["capabilities"]:
            if capability.get("kind") != "tool" or capability.get("status") != "active" or capability.get("exposure") != "callable":
                continue
            tool_id = capability.get("tool_id") or str(capability["id"]).split(":", 1)[1]
            if not TOOL_RE.fullmatch(str(tool_id)):
                continue
            entries.append({
                "id": tool_id,
                "name": capability.get("name", tool_id),
                "version": 1,
                "mode": capability["side_effect"],
                "execution": capability["location"],
                "summary": capability["summary"],
                "invocation_policy": capability["invocation_policy"],
                "queueable": capability["queueable"],
                "input_schema": capability.get("input_schema", {"type": "object", "additionalProperties": False}),
                "output_schema": capability.get("output_schema"),
            })
        return {
            "schema_version": 1,
            "tools": entries,
        }

    @staticmethod
    def validate_capability_input(schema: Any, value: Any) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise ControlPlaneError("capability input must be an object")
        if not isinstance(schema, dict):
            raise ControlPlaneError("capability input schema is unavailable", HTTPStatus.SERVICE_UNAVAILABLE)
        if schema.get("type", "object") != "object":
            raise ControlPlaneError("unsupported capability input schema", HTTPStatus.SERVICE_UNAVAILABLE)
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        if not isinstance(properties, dict) or not isinstance(required, list):
            raise ControlPlaneError("invalid capability input schema", HTTPStatus.SERVICE_UNAVAILABLE)
        missing = [key for key in required if key not in value]
        if missing:
            raise ControlPlaneError(f"capability input is missing: {', '.join(missing)}")
        if schema.get("additionalProperties") is False:
            unknown = sorted(set(value) - set(properties))
            if unknown:
                raise ControlPlaneError(f"capability input contains unknown fields: {', '.join(unknown)}")
        clean = {}
        type_checks = {
            "string": lambda item: isinstance(item, str),
            "boolean": lambda item: isinstance(item, bool),
            "integer": lambda item: isinstance(item, int) and not isinstance(item, bool),
            "number": lambda item: isinstance(item, (int, float)) and not isinstance(item, bool),
            "object": lambda item: isinstance(item, dict),
            "array": lambda item: isinstance(item, list),
        }
        for key, item in value.items():
            rule = properties.get(key, {})
            expected = rule.get("type") if isinstance(rule, dict) else None
            if expected and expected in type_checks and not type_checks[expected](item):
                raise ControlPlaneError(f"capability input field has wrong type: {key}")
            if isinstance(item, str) and len(item) > int(rule.get("maxLength", 100_000)):
                raise ControlPlaneError(f"capability input field is too long: {key}")
            if isinstance(item, str) and "minLength" in rule and len(item) < int(rule["minLength"]):
                raise ControlPlaneError(f"capability input field is too short: {key}")
            if isinstance(item, str) and "pattern" in rule and not re.fullmatch(str(rule["pattern"]), item):
                raise ControlPlaneError(f"capability input field has invalid format: {key}")
            if "enum" in rule and item not in rule["enum"]:
                raise ControlPlaneError(f"capability input field is outside its enum: {key}")
            if isinstance(item, (int, float)) and not isinstance(item, bool):
                if "minimum" in rule and item < rule["minimum"]:
                    raise ControlPlaneError(f"capability input field is below minimum: {key}")
                if "maximum" in rule and item > rule["maximum"]:
                    raise ControlPlaneError(f"capability input field is above maximum: {key}")
            clean[str(key)] = item
        if len(json.dumps(clean, ensure_ascii=False).encode()) > 1024 * 1024:
            raise ControlPlaneError("capability input is too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        return clean

    def create_capability_job(self, device_id: str, capability_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        if not CAPABILITY_RE.fullmatch(capability_id):
            raise ControlPlaneError("capability is unavailable", HTTPStatus.NOT_FOUND)
        capability = next((item for item in self.capability_manifest()["capabilities"] if item.get("id") == capability_id), None)
        if (
            not capability
            or capability.get("status") != "active"
            or capability.get("exposure") != "callable"
            or capability.get("location") != "mac-mini"
            or capability.get("kind") not in {"tool", "workflow", "mcp-tool", "database-query", "memory", "artifact"}
        ):
            raise ControlPlaneError("capability is unavailable", HTTPStatus.NOT_FOUND)
        invocation_policy = capability.get("invocation_policy")
        if invocation_policy in {"manual", "unavailable"}:
            raise ControlPlaneError("capability requires its dedicated manual entry point", HTTPStatus.FORBIDDEN)
        if invocation_policy == "confirm" and payload.get("owner_confirmed") is not True:
            raise ControlPlaneError("capability requires owner confirmation", HTTPStatus.FORBIDDEN)
        adapter = str(capability.get("adapter", ""))
        if not CAPABILITY_RE.fullmatch(adapter):
            raise ControlPlaneError("capability has no executable adapter", HTTPStatus.SERVICE_UNAVAILABLE)
        capability_input = self.validate_capability_input(capability.get("input_schema", {"type": "object", "additionalProperties": False}), payload.get("input", {}))
        request_id = str(payload.get("request_id", "")) or f"call-{secrets.token_hex(12)}"
        if not REQUEST_ID_RE.fullmatch(request_id):
            raise ControlPlaneError("invalid request id")
        job_id = f"job-{int(time.time())}-{secrets.token_hex(5)}"
        job = {
            "schema_version": 1,
            "id": job_id,
            "request_id": request_id,
            "kind": "capability",
            "capability_id": capability_id,
            "executor_kind": str(capability.get("executor_kind", "tool")),
            "adapter": adapter,
            "capability_version": int(capability.get("capability_version", 1)),
            "capability_input": capability_input,
            "replay_class": str(capability.get("replay_class", "safe-read")),
            "owner_confirmed": payload.get("owner_confirmed") is True,
            "runtime_requires": list(capability.get("runtime_requires", [])),
            "requested_executor": "mac-mini",
            "actual_executor": "none",
            "remote_call_succeeded": False,
            "owner": "example-owner",
            "device_id": device_id,
            "state": "queued",
            "identity": "owner-local-catalog",
            "project_name": f"capability-{capability_id.replace(':', '-')}",
            "attempt": 0,
            "max_attempts": MAX_JOB_ATTEMPTS,
            "recovery_count": 0,
            "created_at": utc_now(),
            "updated_at": utc_now(),
        }
        with self.transaction():
            existing = self.job_by_request(device_id, request_id)
            if existing:
                return existing
            directory = self.job_dir(job_id)
            directory.mkdir(parents=True, exist_ok=False, mode=0o700)
            self.save_job(job)
            self.event(job_id, "job.queued", f"能力 {capability_id} 已进入 Mac mini 队列", job_kind="capability", capability_id=capability_id)
        return job

    def create_tool_job(self, device_id: str, tool_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        if not TOOL_RE.fullmatch(tool_id):
            raise ControlPlaneError("tool is unavailable", HTTPStatus.NOT_FOUND)
        return self.create_capability_job(device_id, f"tool:{tool_id}", payload)

    def job_by_request(self, device_id: str, request_id: str) -> dict[str, Any] | None:
        if not REQUEST_ID_RE.fullmatch(request_id):
            raise ControlPlaneError("invalid request id")
        for path in self.jobs_dir.glob("job-*/job.json"):
            try:
                job = read_json(path)
            except (OSError, json.JSONDecodeError):
                continue
            if job.get("device_id") == device_id and job.get("request_id") == request_id:
                return job
        return None

    def list_jobs(self, device_id: str) -> list[dict[str, Any]]:
        jobs = []
        for path in sorted(self.jobs_dir.glob("job-*/job.json"), reverse=True):
            try:
                job = read_json(path)
                if job.get("device_id") == device_id:
                    jobs.append(public_job(job))
            except (OSError, json.JSONDecodeError):
                continue
        return jobs

    def lease(self, worker_id: str) -> dict[str, Any] | None:
        with self.transaction():
            self.expire_artifacts()
            now = int(time.time())
            for path in sorted(self.jobs_dir.glob("job-*/job.json")):
                job = read_json(path)
                if job.get("state") == "leased" and int(job.get("lease_expires_at", 0)) < now:
                    self.recover_stale_job(job, "Mac mini 领取后没有开始执行")
                elif job.get("state") in {"running", "waiting_user", "uploading"} and int(job.get("lease_expires_at", 0)) < now:
                    self.recover_stale_job(job, "Mac mini worker 心跳超时")
            for path in sorted(self.jobs_dir.glob("job-*/job.json")):
                job = read_json(path)
                if job.get("state") != "queued":
                    continue
                if not self.worker_can_execute(worker_id, job):
                    continue
                attempt = int(job.get("attempt", 0)) + 1
                maximum = int(job.get("max_attempts", MAX_JOB_ATTEMPTS))
                if attempt > maximum:
                    job["state"] = "failed"
                    job["failure"] = "automatic retry limit reached"
                    job["recovery_state"] = "manual_retry_required"
                    self.save_job(job)
                    self.event(job["id"], "job.failed", "自动恢复次数已用尽，需要你确认后重试")
                    continue
                job["state"] = "leased"
                job["worker_id"] = worker_id
                job["attempt"] = attempt
                job["lease_id"] = f"lease-{secrets.token_hex(12)}"
                job["lease_expires_at"] = int(time.time()) + 120
                job.pop("recovery_state", None)
                self.save_job(job)
                self.event(job["id"], "job.leased", "Mac mini 已领取任务", attempt=attempt, max_attempts=maximum)
                leased_job = public_job(job, include_instruction=True)
                leased_job["lease_id"] = job["lease_id"]
                response = {"job": leased_job}
                if job.get("kind", "codex") == "codex":
                    capsule = (path.parent / "capsule.tar.gz").read_bytes()
                    response["capsule_base64"] = base64.b64encode(capsule).decode()
                return response
        return None

    def worker_can_execute(self, worker_id: str, job: dict[str, Any]) -> bool:
        entry = self.state().get("devices", {}).get(worker_id, {})
        if not entry.get("enabled"):
            return False
        protocol_min = int(entry.get("protocol_min", 1))
        protocol_max = int(entry.get("protocol_max", 1))
        if not protocol_min <= PROTOCOL_VERSION <= protocol_max:
            return False
        provided = set(entry.get("capabilities", []))
        if job.get("kind", "codex") == "codex":
            required = {"codex-job", "result-package"}
        elif job.get("kind") == "capability":
            required = set(job.get("runtime_requires", [])) | {"capability-adapters", "result-package"}
        elif job.get("kind") == "tool":
            required = {str(job.get("tool_id", "")), "result-package"}
        else:
            return False
        return required.issubset(provided)

    def recover_stale_job(self, job: dict[str, Any], reason: str) -> None:
        result_path = self.job_dir(job["id"]) / "result.tar.gz"
        if result_path.is_file() and job.get("state") == "uploading":
            result = result_path.read_bytes()
            job["result_sha256"] = hashlib.sha256(result).hexdigest()
            job["result_size"] = len(result)
            job["state"] = "succeeded"
            job.pop("failure", None)
            job.pop("lease_expires_at", None)
            job.pop("lease_id", None)
            self.save_job(job)
            self.event(job["id"], "job.recovered", "已从完整结果包恢复任务")
            return

        attempt = int(job.get("attempt", 0))
        maximum = int(job.get("max_attempts", MAX_JOB_ATTEMPTS))
        privileged = (
            job.get("replay_class") == "owner-confirmation-required"
            or self.retry_requires_confirmation(job["id"])
        )
        self.expire_pending_interactions(job["id"], reason)
        job.pop("worker_id", None)
        job.pop("lease_expires_at", None)
        job.pop("lease_id", None)
        if attempt < maximum and not privileged:
            job["state"] = "queued"
            job["recovery_count"] = int(job.get("recovery_count", 0)) + 1
            job["recovery_state"] = "automatic_retry"
            self.save_job(job)
            self.event(job["id"], "job.requeued", f"{reason}，已安全重新排队", attempt=attempt, max_attempts=maximum)
            return

        job["state"] = "failed"
        job["failure"] = reason
        job["recovery_state"] = "manual_retry_required"
        self.save_job(job)
        message = "任务曾获得额外权限，自动重跑可能产生重复副作用，需要你确认" if privileged else "自动恢复次数已用尽，需要你确认后重试"
        self.event(job["id"], "job.recovery_required", message)

    def retry_job(self, job_id: str) -> dict[str, Any]:
        with self.transaction():
            job = self.job(job_id)
            if job.get("state") not in {"failed", "cancelled", "expired"}:
                raise ControlPlaneError("job is not retryable", HTTPStatus.CONFLICT)
            if (self.job_dir(job_id) / "result.tar.gz").exists():
                raise ControlPlaneError("job already has a retained result", HTTPStatus.CONFLICT)
            manual_retries = int(job.get("manual_retry_count", 0))
            if manual_retries >= 5:
                raise ControlPlaneError("manual retry limit reached", HTTPStatus.CONFLICT)
            self.expire_pending_interactions(job_id, "任务已由所有者重新排队")
            for key in ("worker_id", "lease_id", "lease_expires_at", "failure", "recovery_state"):
                job.pop(key, None)
            job["state"] = "queued"
            job["attempt"] = 0
            job["manual_retry_count"] = manual_retries + 1
            self.save_job(job)
            self.event(job_id, "job.retried", "任务已由所有者确认后重新排队", manual_retry=manual_retries + 1)
            return job

    def heartbeat(self, worker_id: str, job_id: str, lease_id: str) -> dict[str, Any]:
        with self.transaction():
            job = self.job(job_id)
            if job.get("worker_id") != worker_id or job.get("lease_id") != lease_id:
                raise ControlPlaneError("job is not leased to this worker", HTTPStatus.FORBIDDEN)
            if job.get("state") in {"leased", "running", "waiting_user", "uploading"}:
                job["lease_expires_at"] = int(time.time()) + 180
                self.save_job(job)
            return public_job(job)


def public_job(job: dict[str, Any], *, include_instruction: bool = False) -> dict[str, Any]:
    keys = [
        "id", "owner", "device_id", "worker_id", "state", "identity", "project_name",
        "capsule_sha256", "capsule_size", "result_sha256", "result_size", "created_at", "updated_at",
        "failure", "lease_expires_at", "model", "effort", "attempt", "max_attempts",
        "recovery_count", "recovery_state", "manual_retry_count", "kind", "tool_id", "tool_version", "request_id",
        "artifact_ids", "input_artifacts", "output_artifact_ids", "capability_id", "executor_kind", "adapter", "capability_version",
        "requested_executor", "actual_executor", "remote_call_succeeded", "replay_class", "owner_confirmed", "capability_input", "project_lease_id",
        "project_mode", "project_delta_sequence", "project_lease_expires_at", "runtime_requires",
    ]
    if include_instruction:
        keys.append("instruction")
    return {key: job[key] for key in keys if key in job}


def public_artifact(item: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "schema_version", "id", "request_id", "owner", "device_id", "filename", "media_type", "sha256", "size",
        "state", "created_at", "expires_at", "removed_at", "expired_at",
    ]
    return {key: item[key] for key in keys if key in item}


def public_member_job(job: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "schema_version", "id", "request_id", "user_id", "device_id", "codex_binding_id",
        "kind", "capability_id", "submission_mode", "state", "instruction", "capability_envelope", "content_lease_ids",
        "created_at", "updated_at", "failure_code",
    ]
    return {key: job[key] for key in keys if key in job}


def public_member_interaction(interaction: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "schema_version", "id", "user_id", "job_id", "kind", "state", "title", "detail",
        "action_sha256", "created_at", "expires_at", "reply", "replied_at",
    ]
    return {key: interaction[key] for key in keys if key in interaction}


MemberAuthenticator = Callable[[str, str, bytes, dict[str, str]], dict[str, str]]


class Handler(BaseHTTPRequestHandler):
    server_version = "TwoHeadWuRemote/0.2"
    protocol_version = "HTTP/1.1"

    @property
    def store(self) -> Store:
        return self.server.store  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s remote-work %s\n" % (self.log_date_time_string(), fmt % args))

    def do_GET(self) -> None:  # noqa: N802
        self.dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self.dispatch("POST")

    def dispatch(self, method: str) -> None:
        try:
            parsed = urlsplit(self.path)
            if parsed.path == MEMBER_API_PREFIX or parsed.path.startswith(MEMBER_API_PREFIX + "/"):
                body = self.read_body() if method == "POST" else b""
                route = parsed.path[len(MEMBER_API_PREFIX):] or "/"
                return self.dispatch_member(method, parsed, route, body)
            if not parsed.path.startswith(API_PREFIX + "/") and parsed.path != API_PREFIX:
                raise ControlPlaneError("not found", HTTPStatus.NOT_FOUND)
            route = parsed.path[len(API_PREFIX):] or "/"
            body = self.read_body() if method == "POST" else b""

            if method == "GET" and route == "/health":
                return self.json_response({"status": "ok", "version": VERSION, "scope": "owner-only"})
            if method == "GET" and route == "/bootstrap/release":
                token = self.enrollment_token()
                self.store.enrollment(token, consume=False)
                return self.file_response(self.store.releases_dir / "current.tar.gz", "application/gzip")
            if method == "GET" and route == "/bootstrap/manifest":
                token = self.enrollment_token()
                self.store.enrollment(token, consume=False)
                return self.file_response(self.store.releases_dir / "current.json", "application/json")
            if method == "POST" and route == "/bootstrap/consume":
                token = self.enrollment_token()
                self.store.enrollment(token, consume=True)
                return self.json_response({"result": "consumed"})
            if method == "POST" and route == "/enroll":
                token = self.enrollment_token()
                payload = parse_json(body)
                result = self.store.enroll(token, str(payload.get("device_name", "")))
                return self.json_response(result, HTTPStatus.CREATED)

            device = self.authenticate(method, parsed.path + (("?" + parsed.query) if parsed.query else ""), body)
            role = device["role"]
            if method == "GET" and route == "/me":
                return self.json_response({"device": {"id": device["id"], "name": device["name"], "role": role}})
            if method == "GET" and route == "/devices":
                self.require_role(role, "owner-air")
                return self.json_response({"devices": self.store.devices()})
            if method == "GET" and route == "/capabilities":
                self.require_role(role, "owner-air")
                return self.json_response(self.store.capability_directory())
            if method == "GET" and route == "/modules":
                self.require_role(role, "owner-air")
                return self.json_response(self.store.manifest())
            if method == "GET" and route == "/models":
                self.require_role(role, "owner-air")
                return self.json_response(self.store.models())
            if method == "GET" and route == "/tools":
                self.require_role(role, "owner-air")
                return self.json_response(self.store.tools())
            if method == "POST" and route == "/calls":
                self.require_role(role, "owner-air")
                payload = parse_json(body)
                capability_id = str(payload.get("capability_id", ""))
                job = self.store.create_capability_job(device["id"], capability_id, payload)
                return self.json_response({"job": public_job(job)}, HTTPStatus.CREATED)
            if method == "POST" and route == "/artifacts":
                self.require_role(role, "owner-air")
                item = self.store.create_artifact(device["id"], parse_json(body))
                return self.json_response({"artifact": public_artifact(item)}, HTTPStatus.CREATED)
            if method == "GET" and route == "/artifacts":
                self.require_role(role, "owner-air")
                return self.json_response({"artifacts": self.store.list_artifacts(device["id"])})
            match = re.fullmatch(r"/artifacts/by-request/(call-[a-f0-9]{24})", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                item = self.store.artifact_by_request(device["id"], match.group(1))
                if not item:
                    raise ControlPlaneError("artifact request is unavailable", HTTPStatus.NOT_FOUND)
                return self.json_response({"artifact": public_artifact(item)})
            match = re.fullmatch(r"/artifacts/(art-[a-f0-9]{24})", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                item = self.store.artifact(match.group(1))
                self.authorize_artifact(device, item)
                return self.json_response({"artifact": public_artifact(item)})
            match = re.fullmatch(r"/artifacts/(art-[a-f0-9]{24})/content", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                item = self.store.artifact(match.group(1))
                self.authorize_artifact(device, item)
                if item.get("state") != "active":
                    raise ControlPlaneError("artifact is unavailable", HTTPStatus.GONE)
                return self.file_response(self.store.artifact_dir(item["id"]) / "content.bin", item["media_type"])
            match = re.fullmatch(r"/artifacts/(art-[a-f0-9]{24})/remove", route)
            if method == "POST" and match:
                self.require_role(role, "owner-air")
                item = self.store.artifact(match.group(1))
                self.authorize_artifact(device, item)
                item = self.store.remove_artifact(item["id"])
                return self.json_response({"artifact": public_artifact(item)})
            match = re.fullmatch(r"/client/releases/channels/(stable|dev)", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                return self.json_response(self.store.release_manifest(match.group(1)))
            match = re.fullmatch(r"/client/releases/(v[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{12})/manifest", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                manifest, _archive = self.store.release_by_id(match.group(1))
                return self.json_response(manifest)
            match = re.fullmatch(r"/client/releases/(v[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{12})/archive", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                _manifest, archive = self.store.release_by_id(match.group(1))
                return self.file_response(archive, "application/gzip")
            match = re.fullmatch(r"/tools/([a-z][a-z0-9-]{0,63})/invoke", route)
            if method == "POST" and match:
                self.require_role(role, "owner-air")
                job = self.store.create_tool_job(device["id"], match.group(1), parse_json(body))
                return self.json_response({"job": public_job(job)}, HTTPStatus.CREATED)
            match = re.fullmatch(r"/modules/([^/]+)/archive", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                module_id = unquote(match.group(1))
                version = parse_qs(parsed.query).get("version", [None])[0]
                item, release = self.store.module_version(module_id, version)
                if item.get("classification") != "portable" or item.get("status") != "active":
                    raise ControlPlaneError("module is not portable", HTTPStatus.FORBIDDEN)
                archive_name = str(release.get("archive", ""))
                if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,200}\.tar\.gz", archive_name):
                    raise ControlPlaneError("module archive is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
                path = self.store.components_dir / archive_name
                if hashlib.sha256(path.read_bytes()).hexdigest() != release.get("sha256"):
                    raise ControlPlaneError("module archive failed server verification", HTTPStatus.SERVICE_UNAVAILABLE)
                return self.file_response(path, "application/gzip")

            if method == "POST" and route == "/jobs":
                self.require_role(role, "owner-air")
                job = self.store.create_job(device["id"], parse_json(body))
                return self.json_response({"job": public_job(job)}, HTTPStatus.CREATED)
            if method == "GET" and route == "/jobs":
                self.require_role(role, "owner-air")
                return self.json_response({"jobs": self.store.list_jobs(device["id"])})
            match = re.fullmatch(r"/jobs/by-request/(call-[a-f0-9]{24})", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                job = self.store.job_by_request(device["id"], match.group(1))
                if not job:
                    raise ControlPlaneError("request is unavailable", HTTPStatus.NOT_FOUND)
                return self.json_response({"job": public_job(job)})
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)", route)
            if method == "GET" and match:
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                return self.json_response({"job": public_job(job)})
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/events", route)
            if method == "GET" and match:
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                after = int(parse_qs(parsed.query).get("after", ["0"])[0])
                events = read_json(self.store.job_dir(job["id"]) / "events.json", {"events": []}).get("events", [])
                return self.json_response({"events": [event for event in events if int(event.get("sequence", 0)) > after]})
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/interactions", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                return self.json_response({"interactions": self.store.interactions(job["id"])})
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/interactions/(ask-[a-f0-9]{16})/reply", route)
            if method == "POST" and match:
                self.require_role(role, "owner-air")
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                item = self.store.reply_interaction(job["id"], match.group(2), parse_json(body))
                return self.json_response({"interaction": item})
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/project/deltas", route)
            if method == "POST" and match:
                self.require_role(role, "owner-air")
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                payload = parse_json(body)
                delta = self.store.append_project_delta(job["id"], str(payload.get("project_lease_id", "")), payload.get("entries"))
                return self.json_response({"delta": delta}, HTTPStatus.CREATED)
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/result", route)
            if method == "GET" and match:
                self.require_role(role, "owner-air")
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                return self.file_response(self.store.job_dir(job["id"]) / "result.tar.gz", "application/gzip")
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/cancel", route)
            if method == "POST" and match:
                self.require_role(role, "owner-air")
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                if job["state"] not in {"queued", "leased", "running", "waiting_user"}:
                    raise ControlPlaneError("job can no longer be cancelled", HTTPStatus.CONFLICT)
                job["state"] = "cancelled"
                self.store.save_job(job)
                self.store.event(job["id"], "job.cancelled", "任务已取消")
                return self.json_response({"job": public_job(job)})
            match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/retry", route)
            if method == "POST" and match:
                self.require_role(role, "owner-air")
                job = self.store.job(match.group(1))
                self.authorize_job(device, job)
                job = self.store.retry_job(job["id"])
                return self.json_response({"job": public_job(job)})

            if method == "GET" and route == "/worker/jobs/lease":
                self.require_role(role, "mac-mini-worker")
                value = self.store.lease(device["id"])
                return self.json_response(value or {"job": None})
            if method == "GET" and route == "/worker/air-jobs/lease":
                self.require_role(role, "mac-mini-air-worker")
                value = self.store.member_registry.lease_member_job(device["id"])
                if not value:
                    return self.json_response({"job": None})
                job = value["job"]
                try:
                    self.store.authorize_member_capabilities(
                        job["user_id"], job["capability_envelope"]["capabilities"],
                        require_project=job["kind"] == "codex",
                    )
                except ControlPlaneError:
                    self.store.member_registry.transition_member_job(
                        device["id"], job["id"], job["execution_lease_id"], "failed",
                        failure_code="authorization_required",
                    )
                    return self.json_response({"job": None})
                job["identity_alias"] = value["identity_alias"]
                job["user_role"] = value["user_role"]
                return self.json_response({"job": job})
            if method == "POST" and route == "/worker/models":
                self.require_role(role, "mac-mini-worker")
                value = self.store.update_models(device["id"], parse_json(body))
                return self.json_response(value)
            if method == "POST" and route == "/worker/presence":
                self.require_role(role, "mac-mini-worker")
                value = self.store.update_presence(device["id"], parse_json(body))
                return self.json_response({"device": value})
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/state", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-worker")
                payload = parse_json(body)
                job = self.worker_job(device, match.group(1), payload.get("lease_id"))
                new_state = str(payload.get("state", ""))
                if new_state not in TRANSITIONS.get(job["state"], set()):
                    raise ControlPlaneError("invalid job state transition", HTTPStatus.CONFLICT)
                job["state"] = new_state
                if new_state in {"running", "waiting_user", "uploading"}:
                    job["lease_expires_at"] = int(time.time()) + 180
                if payload.get("failure"):
                    job["failure"] = str(payload["failure"])[:1000]
                self.store.save_job(job)
                self.store.event(job["id"], f"job.{new_state}", str(payload.get("message", new_state))[:2000])
                return self.json_response({"job": public_job(job)})
            match = re.fullmatch(r"/worker/air-jobs/(job-[a-z0-9-]+)/state", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-air-worker")
                payload = parse_json(body)
                allowed = {"execution_lease_id", "state", "failure_code"}
                if not set(payload) <= allowed or not {"execution_lease_id", "state"} <= set(payload):
                    raise ContractError("member worker state payload is invalid")
                job = self.store.member_registry.transition_member_job(
                    device["id"],
                    match.group(1),
                    str(payload["execution_lease_id"]),
                    str(payload["state"]),
                    failure_code=str(payload["failure_code"]) if "failure_code" in payload else None,
                )
                return self.json_response({"job": public_member_job(job)})
            match = re.fullmatch(r"/worker/air-jobs/(job-[a-z0-9-]+)/heartbeat", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-air-worker")
                payload = parse_json(body)
                if set(payload) != {"execution_lease_id"}:
                    raise ContractError("member worker heartbeat payload is invalid")
                job = self.store.member_registry.heartbeat_member_job(
                    device["id"], match.group(1), str(payload["execution_lease_id"])
                )
                return self.json_response({"job": public_member_job(job)})
            match = re.fullmatch(r"/worker/air-jobs/(job-[a-z0-9-]+)/interactions", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-air-worker")
                payload = parse_json(body)
                required = {"execution_lease_id", "kind", "title", "detail", "action_sha256"}
                if set(payload) != required:
                    raise ContractError("member worker interaction payload is invalid")
                expires_at = (
                    datetime.now(timezone.utc) + timedelta(minutes=10)
                ).replace(microsecond=0).isoformat().replace("+00:00", "Z")
                try:
                    interaction = self.store.member_registry.create_member_interaction(
                        device["id"], match.group(1), str(payload["execution_lease_id"]),
                        kind=str(payload["kind"]), title=str(payload["title"]), detail=str(payload["detail"]),
                        action_sha256=str(payload["action_sha256"]), expires_at=expires_at,
                    )
                except ContractError as error:
                    if isinstance(error, TenantAccessError):
                        raise
                    raise ControlPlaneError(str(error), HTTPStatus.CONFLICT) from error
                return self.json_response(
                    {"interaction": public_member_interaction(interaction)}, HTTPStatus.CREATED
                )
            match = re.fullmatch(
                r"/worker/air-jobs/(job-[a-z0-9-]+)/interactions/(ask-[a-f0-9]{16})", route
            )
            if method == "GET" and match:
                self.require_role(role, "mac-mini-air-worker")
                lease_values = parse_qs(parsed.query).get("execution_lease_id", [])
                if len(lease_values) != 1:
                    raise ControlPlaneError("valid member execution lease is required", HTTPStatus.FORBIDDEN)
                interaction = self.store.member_registry.worker_member_interaction(
                    device["id"], match.group(1), lease_values[0], match.group(2)
                )
                return self.json_response({"interaction": public_member_interaction(interaction)})
            match = re.fullmatch(r"/worker/air-jobs/(job-[a-z0-9-]+)/content/(content-[a-z0-9-]+)(/metadata)?", route)
            if method == "GET" and match:
                self.require_role(role, "mac-mini-air-worker")
                lease_values = parse_qs(parsed.query).get("execution_lease_id", [])
                if len(lease_values) != 1:
                    raise ControlPlaneError("valid member execution lease is required", HTTPStatus.FORBIDDEN)
                job = self.store.member_registry.member_job_for_worker(
                    device["id"], match.group(1), lease_values[0]
                )
                lease = self.store.member_registry.member_content_lease(job["user_id"], match.group(2))
                if lease["job_id"] != job["id"] or lease["id"] not in job["content_lease_ids"]:
                    raise TenantAccessError("member content is not attached to this job")
                if lease["kind"] not in {"project-capsule", "input-artifact"} or lease["state"] != "available":
                    raise ControlPlaneError("member content is unavailable", HTTPStatus.GONE)
                path = self.store.member_content_path(lease)
                if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != lease["sha256"]:
                    raise ControlPlaneError("member content failed server verification", HTTPStatus.SERVICE_UNAVAILABLE)
                metadata = read_json(self.store.member_content_metadata_path(lease))
                if match.group(3):
                    return self.json_response({"content_lease": lease, "content": metadata})
                return self.file_response(path, str(metadata["media_type"]))
            match = re.fullmatch(r"/worker/air-jobs/(job-[a-z0-9-]+)/result", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-air-worker")
                payload = parse_json(body)
                if set(payload) != {"execution_lease_id", "result_sha256", "result_base64"}:
                    raise ContractError("member worker result payload is invalid")
                execution_lease_id = str(payload["execution_lease_id"])
                try:
                    result = base64.b64decode(payload["result_base64"], validate=True)
                except (ValueError, TypeError):
                    raise ControlPlaneError("invalid result encoding")
                if not result or len(result) > MAX_RESULT:
                    raise ControlPlaneError("member result is empty or too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                digest = hashlib.sha256(result).hexdigest()
                if not hmac.compare_digest(digest, str(payload["result_sha256"])):
                    raise ControlPlaneError("result hash mismatch")
                job = self.store.member_registry.transition_member_job(
                    device["id"], match.group(1), execution_lease_id, "uploading"
                )
                expires_at = (datetime.now(timezone.utc) + timedelta(days=14)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
                result_lease = self.store.member_registry.create_result_lease(
                    job["user_id"], job["id"], sha256=digest, size=len(result), expires_at=expires_at,
                    lease_id=self.store.member_result_content_id(
                        job["user_id"], job["id"], execution_lease_id
                    ),
                    state="staged",
                )
                atomic_write(self.store.member_content_path(result_lease), result)
                self.store.member_registry.mark_content_available(job["user_id"], result_lease["id"])
                job = self.store.member_registry.transition_member_job(
                    device["id"], job["id"], execution_lease_id, "succeeded"
                )
                return self.json_response({"job": public_member_job(job)})
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/heartbeat", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-worker")
                payload = parse_json(body)
                job = self.store.heartbeat(device["id"], match.group(1), str(payload.get("lease_id", "")))
                return self.json_response({"job": job})
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/events", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-worker")
                payload = parse_json(body)
                job = self.worker_job(device, match.group(1), payload.get("lease_id"))
                event = self.store.event(job["id"], str(payload.get("type", "worker.message"))[:100], str(payload.get("message", "")))
                return self.json_response({"event": event}, HTTPStatus.CREATED)
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/interactions", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-worker")
                payload = parse_json(body)
                job = self.worker_job(device, match.group(1), payload.get("lease_id"))
                interaction = self.store.create_interaction(job["id"], payload)
                return self.json_response({"interaction": interaction}, HTTPStatus.CREATED)
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/interactions/(ask-[a-f0-9]{16})/reply", route)
            if method == "GET" and match:
                self.require_role(role, "mac-mini-worker")
                lease_id = parse_qs(parsed.query).get("lease_id", [""])[0]
                job = self.worker_job(device, match.group(1), lease_id)
                interaction = self.store.interaction(job["id"], match.group(2))
                reply = interaction.get("reply") if interaction.get("status") == "answered" else None
                return self.json_response({"status": interaction.get("status"), "reply": reply, "job_state": job.get("state")})
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/artifacts/(art-[a-f0-9]{24})", route)
            if method == "GET" and match:
                self.require_role(role, "mac-mini-worker")
                lease_id = parse_qs(parsed.query).get("lease_id", [""])[0]
                job = self.worker_job(device, match.group(1), lease_id)
                artifact_id = match.group(2)
                if artifact_id not in job.get("artifact_ids", []):
                    raise ControlPlaneError("artifact is not attached to this job", HTTPStatus.FORBIDDEN)
                item = self.store.artifact(artifact_id)
                if item.get("state") != "active":
                    raise ControlPlaneError("artifact is unavailable", HTTPStatus.GONE)
                return self.file_response(self.store.artifact_dir(artifact_id) / "content.bin", item["media_type"])
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/artifacts", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-worker")
                payload = parse_json(body)
                lease_id = str(payload.pop("lease_id", ""))
                self.worker_job(device, match.group(1), lease_id)
                item = self.store.create_job_output_artifact(device["id"], match.group(1), lease_id, payload)
                return self.json_response({"artifact": public_artifact(item)}, HTTPStatus.CREATED)
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/project/deltas", route)
            if method == "GET" and match:
                self.require_role(role, "mac-mini-worker")
                lease_id = parse_qs(parsed.query).get("lease_id", [""])[0]
                after = int(parse_qs(parsed.query).get("after", ["0"])[0])
                job = self.worker_job(device, match.group(1), lease_id)
                return self.json_response({
                    "project_lease_id": job.get("project_lease_id"),
                    "deltas": self.store.project_deltas(job["id"], after),
                })
            match = re.fullmatch(r"/worker/jobs/(job-[a-z0-9-]+)/result", route)
            if method == "POST" and match:
                self.require_role(role, "mac-mini-worker")
                payload = parse_json(body)
                job = self.worker_job(device, match.group(1), payload.get("lease_id"))
                try:
                    result = base64.b64decode(payload.get("result_base64", ""), validate=True)
                except (ValueError, TypeError):
                    raise ControlPlaneError("invalid result encoding")
                if len(result) > MAX_RESULT:
                    raise ControlPlaneError("result is too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                digest = hashlib.sha256(result).hexdigest()
                if not hmac.compare_digest(digest, str(payload.get("result_sha256", ""))):
                    raise ControlPlaneError("result hash mismatch")
                if job["state"] not in {"running", "uploading"}:
                    raise ControlPlaneError("job is not ready for a result", HTTPStatus.CONFLICT)
                if job["state"] == "running":
                    job["state"] = "uploading"
                    self.store.save_job(job)
                    self.store.event(job["id"], "job.uploading", "Mac mini 正在上传结果")
                atomic_write(self.store.job_dir(job["id"]) / "result.tar.gz", result)
                job["result_sha256"] = digest
                job["result_size"] = len(result)
                job["actual_executor"] = "mac-mini"
                job["remote_call_succeeded"] = True
                job["state"] = "succeeded"
                self.store.save_job(job)
                self.store.event(job["id"], "job.succeeded", "任务结果已安全存入阿里云")
                return self.json_response({"job": public_job(job)})

            raise ControlPlaneError("not found", HTTPStatus.NOT_FOUND)
        except TenantAccessError as error:
            self.json_response({"error": str(error)}, HTTPStatus.FORBIDDEN)
        except ContractError as error:
            self.json_response({"error": str(error)}, HTTPStatus.BAD_REQUEST)
        except ControlPlaneError as error:
            self.json_response({"error": str(error)}, error.status)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self.json_response({"error": "invalid request"}, HTTPStatus.BAD_REQUEST)
        except FileNotFoundError:
            self.json_response({"error": "not found"}, HTTPStatus.NOT_FOUND)
        except Exception as error:  # defensive boundary; details stay in server logs
            self.log_error("internal error: %s", error.__class__.__name__)
            self.json_response({"error": "internal server error"}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def dispatch_member(self, method: str, parsed: Any, route: str, body: bytes) -> None:
        if method == "GET" and route == "/health":
            return self.json_response({
                "status": "ok",
                "version": VERSION,
                "scope": "air-v2",
                "authentication": "configured" if self.server.member_authenticator else "unavailable",  # type: ignore[attr-defined]
            })
        if method == "POST" and route == "/enroll":
            return self.enroll_member(body)

        principal = self.authenticate_member(
            method,
            parsed.path + (("?" + parsed.query) if parsed.query else ""),
            body,
        )
        user_id = principal["user"]["id"]
        device_id = principal["device"]["id"]

        if method == "GET" and route == "/me":
            return self.json_response({
                "user": {
                    "id": user_id,
                    "role": principal["user"]["role"],
                    "status": principal["user"]["status"],
                    "display_name": principal["user"]["display_name"],
                },
                "device": {
                    "id": device_id,
                    "role": principal["device"]["role"],
                    "platform": principal["device"]["platform"],
                    "status": principal["device"]["status"],
                },
                "codex_binding": {
                    "id": principal["codex_binding"]["id"],
                    "status": principal["codex_binding"]["status"],
                },
            })
        if method == "GET" and route == "/capabilities":
            return self.json_response(self.store.member_capability_directory(user_id))
        if method == "GET" and route == "/approval-key":
            return self.json_response(self.store.owner_approval_key_status(principal))
        if method == "POST" and route == "/approval-key":
            value = self.store.register_owner_approval_key(
                principal,
                parse_json(body),
                self.server.owner_approval_verifier,  # type: ignore[attr-defined]
            )
            return self.json_response(value, HTTPStatus.CREATED)
        if method == "GET" and route == "/modules":
            return self.json_response(self.store.member_module_directory(user_id))
        match = re.fullmatch(r"/modules/([^/]+)/archive", route)
        if method == "GET" and match:
            module_id = unquote(match.group(1))
            self.store.authorize_member_module(user_id, module_id)
            version = parse_qs(parsed.query).get("version", [None])[0]
            item, release = self.store.module_version(
                module_id, version, member=True, user_role=principal["user"]["role"]
            )
            if item.get("classification") != "portable" or item.get("status") != "active":
                raise ControlPlaneError("member module is not portable", HTTPStatus.FORBIDDEN)
            archive_name = str(release.get("archive", ""))
            if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,200}\.tar\.gz", archive_name):
                raise ControlPlaneError("member module archive is invalid", HTTPStatus.SERVICE_UNAVAILABLE)
            path = self.store.components_dir / archive_name
            if hashlib.sha256(path.read_bytes()).hexdigest() != release.get("sha256"):
                raise ControlPlaneError("member module archive failed server verification", HTTPStatus.SERVICE_UNAVAILABLE)
            return self.file_response(path, "application/gzip")
        if method == "POST" and route == "/calls":
            payload = parse_json(body)
            required = {"request_id", "capability_id", "input"}
            if not required <= set(payload) or not set(payload) <= required | {"approval"}:
                raise ContractError("Air capability call has invalid fields")
            capability_id = str(payload["capability_id"])
            self.store.authorize_member_capabilities(user_id, [capability_id])
            catalog = self.store.member_capability_directory(user_id)["catalog"]
            capability = next(
                (item for item in catalog["capabilities"] if item["id"] == capability_id and item["status"] == "active"), None
            )
            if not capability or capability_id not in {
                "research-library:search", "research-library:get", "tool:codex-status", "memory:notebook",
                "workflow:publish-site",
            }:
                raise ControlPlaneError("member capability is unavailable", HTTPStatus.FORBIDDEN)
            capability_input = self.store.validate_capability_input(capability.get("input_schema"), payload["input"])
            self.store.authorize_member_capability_input(user_id, capability_id, capability_input)
            if capability.get("confirmation", "none") == "owner-password":
                self.store.verify_owner_approval(
                    principal,
                    str(payload["request_id"]),
                    capability_id,
                    capability_input,
                    payload.get("approval"),
                    self.server.owner_approval_verifier,  # type: ignore[attr-defined]
                )
            elif "approval" in payload:
                raise ContractError("Air capability does not accept owner approval")
            job = self.store.member_registry.create_member_capability_job(
                user_id, device_id, str(payload["request_id"]), capability_id, capability_input
            )
            return self.json_response({"job": public_member_job(job)}, HTTPStatus.CREATED)
        if method == "POST" and route in {"/jobs", "/jobs/draft"}:
            payload = parse_json(body)
            allowed = {"request_id", "instruction", "capabilities"}
            if set(payload) != allowed:
                raise ContractError("member job requires exactly request_id, instruction, and capabilities")
            capabilities = payload["capabilities"]
            if not isinstance(capabilities, list):
                raise ContractError("member job capabilities must be a list")
            self.store.authorize_member_capabilities(user_id, capabilities, require_project=True)
            creator = (
                self.store.member_registry.create_member_job_draft
                if route == "/jobs/draft" else self.store.member_registry.create_member_job
            )
            job = creator(
                user_id, device_id, str(payload["request_id"]), str(payload["instruction"]), capabilities
            )
            return self.json_response({"job": public_member_job(job)}, HTTPStatus.CREATED)
        if method == "GET" and route == "/jobs":
            jobs = self.store.member_registry.list_jobs(user_id)
            return self.json_response({"jobs": [public_member_job(job) for job in jobs]})
        match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)", route)
        if method == "GET" and match:
            job = self.store.member_registry.member_job(user_id, match.group(1))
            return self.json_response({"job": public_member_job(job)})
        match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/interactions", route)
        if method == "GET" and match:
            interactions = self.store.member_registry.list_member_interactions(user_id, match.group(1))
            return self.json_response({
                "interactions": [public_member_interaction(item) for item in interactions]
            })
        match = re.fullmatch(
            r"/jobs/(job-[a-z0-9-]+)/interactions/(ask-[a-f0-9]{16})/reply", route
        )
        if method == "POST" and match:
            payload = parse_json(body)
            if set(payload) not in ({"decision"}, {"decision", "answer"}):
                raise ContractError("member interaction reply payload is invalid")
            try:
                interaction = self.store.member_registry.reply_member_interaction(
                    user_id, match.group(1), match.group(2), decision=str(payload["decision"]),
                    answer=payload.get("answer"),
                )
            except ContractError as error:
                if isinstance(error, TenantAccessError):
                    raise
                raise ControlPlaneError(str(error), HTTPStatus.CONFLICT) from error
            return self.json_response({"interaction": public_member_interaction(interaction)})
        match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/submit", route)
        if method == "POST" and match:
            if parse_json(body):
                raise ContractError("member job draft submit body must be empty")
            try:
                job = self.store.member_registry.activate_member_job(user_id, match.group(1))
            except ContractError as error:
                if isinstance(error, TenantAccessError):
                    raise
                raise ControlPlaneError(str(error), HTTPStatus.CONFLICT) from error
            return self.json_response({"job": public_member_job(job)})
        match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/result", route)
        if method == "GET" and match:
            job = self.store.member_registry.member_job(user_id, match.group(1))
            if job["state"] != "succeeded":
                raise ControlPlaneError("member result is unavailable", HTTPStatus.CONFLICT)
            leases = [
                self.store.member_registry.member_content_lease(user_id, lease_id)
                for lease_id in job["content_lease_ids"]
            ]
            result_lease = next(
                (item for item in leases if item["kind"] == "result-package" and item["state"] == "available"), None
            )
            if not result_lease:
                raise ControlPlaneError("member result is unavailable", HTTPStatus.NOT_FOUND)
            path = self.store.member_content_path(result_lease)
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != result_lease["sha256"]:
                raise ControlPlaneError("member result failed server verification", HTTPStatus.SERVICE_UNAVAILABLE)
            return self.file_response(path, "application/gzip")
        match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/content", route)
        if method == "POST" and match:
            lease, metadata = self.store.create_member_content(user_id, match.group(1), parse_json(body))
            return self.json_response({"content_lease": lease, "content": metadata}, HTTPStatus.CREATED)
        match = re.fullmatch(r"/jobs/(job-[a-z0-9-]+)/(cancel|retry)", route)
        if method == "POST" and match:
            try:
                if match.group(2) == "cancel":
                    job = self.store.member_registry.cancel_member_job(user_id, match.group(1))
                else:
                    job = self.store.member_registry.retry_member_job(user_id, match.group(1))
            except ContractError as error:
                if isinstance(error, TenantAccessError):
                    raise
                raise ControlPlaneError(str(error), HTTPStatus.CONFLICT) from error
            return self.json_response({"job": public_member_job(job)})
        match = re.fullmatch(r"/content/(content-[a-z0-9-]+)", route)
        if method == "GET" and match:
            lease = self.store.member_registry.member_content_lease(user_id, match.group(1))
            return self.json_response({"content_lease": lease})
        match = re.fullmatch(r"/content/(content-[a-z0-9-]+)/download", route)
        if method == "GET" and match:
            lease = self.store.member_registry.member_content_lease(user_id, match.group(1))
            if lease["kind"] not in {"project-capsule", "input-artifact"} or lease["state"] != "available":
                raise ControlPlaneError("member content is unavailable", HTTPStatus.GONE)
            path = self.store.member_content_path(lease)
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != lease["sha256"]:
                raise ControlPlaneError("member content failed server verification", HTTPStatus.SERVICE_UNAVAILABLE)
            metadata = read_json(self.store.member_content_metadata_path(lease))
            return self.file_response(path, str(metadata["media_type"]))
        match = re.fullmatch(r"/content/(content-[a-z0-9-]+)/purge", route)
        if method == "POST" and match:
            payload = parse_json(body)
            if payload:
                raise ContractError("member content purge body must be empty")
            try:
                lease = self.store.purge_member_content(user_id, match.group(1))
            except ContractError as error:
                if isinstance(error, TenantAccessError):
                    raise
                raise ControlPlaneError(str(error), HTTPStatus.CONFLICT) from error
            return self.json_response({"content_lease": lease})
        match = re.fullmatch(r"/content/(content-[a-z0-9-]+)/receipt", route)
        if method == "POST" and match:
            payload = parse_json(body)
            if set(payload) != {"sha256"}:
                raise ContractError("content receipt requires exactly sha256")
            lease = self.store.confirm_member_content_receipt(user_id, match.group(1), str(payload["sha256"]))
            return self.json_response({"content_lease": lease})
        raise ControlPlaneError("not found", HTTPStatus.NOT_FOUND)

    def enroll_member(self, body: bytes) -> None:
        authenticator = self.server.member_authenticator  # type: ignore[attr-defined]
        if authenticator is None or not hasattr(authenticator, "verify_enrollment"):
            raise ControlPlaneError("member device authentication is unavailable", HTTPStatus.SERVICE_UNAVAILABLE)
        if len(body) > 16 * 1024 or len(self.headers.get_all("Authorization", [])) != 1:
            raise ControlPlaneError("member pairing failed", HTTPStatus.UNAUTHORIZED)
        authorization = self.headers.get("Authorization", "")
        if not authorization.startswith("MemberEnrollment "):
            raise ControlPlaneError("member pairing failed", HTTPStatus.UNAUTHORIZED)
        token = authorization[len("MemberEnrollment "):]
        payload = parse_json(body)
        allowed = {
            "platform", "key_provider", "public_key_spki_base64", "timestamp", "nonce", "signature_base64",
        }
        if set(payload) != allowed:
            raise ControlPlaneError("member pairing failed", HTTPStatus.UNAUTHORIZED)
        if any(not isinstance(payload[field], str) for field in allowed):
            raise ControlPlaneError("member pairing failed", HTTPStatus.UNAUTHORIZED)
        try:
            enrollment = self.store.member_enrollments.inspect(token)
            platform = str(payload["platform"])
            key_provider = str(payload["key_provider"])
            public_key = str(payload["public_key_spki_base64"])
            if platform != enrollment["platform"] or key_provider != enrollment["key_provider"]:
                raise MemberAuthenticationError("member pairing proof failed")
            authenticator.verify_enrollment(
                token_hash=self.store.member_enrollments.token_hash(token),
                platform=platform,
                key_provider=key_provider,
                public_key_spki_base64=public_key,
                timestamp=str(payload["timestamp"]),
                nonce=str(payload["nonce"]),
                signature_base64=str(payload["signature_base64"]),
            )
            device = self.store.member_enrollments.consume(
                token,
                public_key_spki_base64=public_key,
            )
        except (ContractError, MemberAuthenticationError) as error:
            raise ControlPlaneError("member pairing failed", HTTPStatus.UNAUTHORIZED) from error
        return self.json_response({
            "device": {
                "id": device["id"],
                "user_id": device["user_id"],
                "role": device["role"],
                "platform": device["platform"],
                "status": device["status"],
            },
        }, HTTPStatus.CREATED)

    def authenticate_member(self, method: str, path: str, body: bytes) -> dict[str, Any]:
        authenticator = self.server.member_authenticator  # type: ignore[attr-defined]
        if authenticator is None:
            raise ControlPlaneError("member device authentication is unavailable", HTTPStatus.SERVICE_UNAVAILABLE)
        required_headers = getattr(authenticator, "required_header_names", ())
        if any(len(self.headers.get_all(name, [])) != 1 for name in required_headers):
            raise ControlPlaneError("member device authentication failed", HTTPStatus.UNAUTHORIZED)
        headers = {str(key): str(value) for key, value in self.headers.items()}
        try:
            claimed = authenticator(method, path, body, headers)
        except MemberAuthenticationError as error:
            raise ControlPlaneError("member device authentication failed", HTTPStatus.UNAUTHORIZED) from error
        if not isinstance(claimed, dict) or set(claimed) != {"user_id", "device_id"}:
            raise ControlPlaneError("member device authentication failed", HTTPStatus.UNAUTHORIZED)
        try:
            return self.store.member_registry.principal(claimed["user_id"], claimed["device_id"])
        except TenantAccessError:
            raise
        except ContractError as error:
            raise ControlPlaneError("member device authentication failed", HTTPStatus.UNAUTHORIZED) from error

    def read_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ControlPlaneError("invalid content length")
        if length < 0 or length > MAX_BODY:
            raise ControlPlaneError("request is too large", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        return self.rfile.read(length)

    def enrollment_token(self) -> str:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Enrollment "):
            raise ControlPlaneError("enrollment authorization required", HTTPStatus.UNAUTHORIZED)
        token = header[len("Enrollment "):]
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
            raise ControlPlaneError("invalid enrollment", HTTPStatus.UNAUTHORIZED)
        return token

    def authenticate(self, method: str, path: str, body: bytes) -> dict[str, Any]:
        device_id = self.headers.get("X-Wu-Device", "")
        timestamp_text = self.headers.get("X-Wu-Time", "")
        nonce = self.headers.get("X-Wu-Nonce", "")
        signature = self.headers.get("X-Wu-Signature", "")
        try:
            timestamp = int(timestamp_text)
        except ValueError:
            raise ControlPlaneError("invalid request time", HTTPStatus.UNAUTHORIZED)
        if abs(int(time.time()) - timestamp) > REQUEST_WINDOW:
            raise ControlPlaneError("request time is outside the allowed window", HTTPStatus.UNAUTHORIZED)
        if not HEX_64_RE.fullmatch(signature):
            raise ControlPlaneError("invalid request signature", HTTPStatus.UNAUTHORIZED)
        device = self.store.device(device_id)
        canonical = "\n".join([method.upper(), path, timestamp_text, nonce, hashlib.sha256(body).hexdigest()])
        expected = hmac.new(device["secret"].encode(), canonical.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            raise ControlPlaneError("request signature rejected", HTTPStatus.UNAUTHORIZED)
        self.store.check_nonce(device_id, nonce, timestamp)
        self.store.touch_device(device_id)
        return device

    @staticmethod
    def require_role(actual: str, expected: str) -> None:
        if actual != expected:
            raise ControlPlaneError("device role is not allowed", HTTPStatus.FORBIDDEN)

    @staticmethod
    def authorize_job(device: dict[str, Any], job: dict[str, Any]) -> None:
        if device["role"] == "owner-air" and job.get("device_id") == device["id"]:
            return
        if device["role"] == "mac-mini-worker" and job.get("worker_id") == device["id"]:
            return
        raise ControlPlaneError("job is not visible to this device", HTTPStatus.FORBIDDEN)

    @staticmethod
    def authorize_artifact(device: dict[str, Any], item: dict[str, Any]) -> None:
        if device["role"] == "owner-air" and item.get("device_id") == device["id"]:
            return
        raise ControlPlaneError("artifact is not visible to this device", HTTPStatus.FORBIDDEN)

    def worker_job(self, device: dict[str, Any], job_id: str, lease_id: Any) -> dict[str, Any]:
        job = self.store.job(job_id)
        lease_value = str(lease_id or "")
        if not LEASE_RE.fullmatch(lease_value):
            raise ControlPlaneError("valid job lease is required", HTTPStatus.FORBIDDEN)
        if job.get("worker_id") != device["id"] or job.get("lease_id") != lease_value:
            raise ControlPlaneError("job is not leased to this worker", HTTPStatus.FORBIDDEN)
        return job

    def json_response(self, value: Any, status: int = HTTPStatus.OK) -> None:
        data = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def file_response(self, path: Path, content_type: str) -> None:
        if not path.is_file():
            raise ControlPlaneError("artifact is unavailable", HTTPStatus.NOT_FOUND)
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def parse_json(data: bytes) -> dict[str, Any]:
    value = json.loads(data.decode("utf-8"))
    if not isinstance(value, dict):
        raise ControlPlaneError("JSON body must be an object")
    return value


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        store: Store,
        member_authenticator: MemberAuthenticator | None = None,
        owner_approval_verifier: Callable[[bytes, bytes, bytes], bool] | None = None,
    ) -> None:
        super().__init__(address, Handler)
        self.store = store
        self.member_authenticator = member_authenticator
        self.owner_approval_verifier = owner_approval_verifier


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="two-head-wu-control-plane")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init")
    serve = sub.add_parser("serve")
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=18765)
    issue = sub.add_parser("issue-enrollment")
    issue.add_argument("--device", required=True)
    issue.add_argument(
        "--role", choices=["owner-air", "mac-mini-worker", "mac-mini-air-worker"], required=True
    )
    issue.add_argument("--ttl", type=int, default=3600)
    create_air_user = sub.add_parser("create-air-user", aliases=["create-member"])
    create_air_user.add_argument("--display-name", required=True)
    create_air_user.add_argument("--identity-alias", required=True)
    create_air_user.add_argument("--role", choices=["owner", "member"], default="member")
    ensure_air_user = sub.add_parser("ensure-air-user")
    ensure_air_user.add_argument("--identity-alias", required=True)
    ensure_air_user.add_argument("--role", choices=["owner", "member"], default="member")
    grant_air_user = sub.add_parser("grant-air-user", aliases=["grant-member"])
    grant_air_user.add_argument("--user", required=True)
    grant_air_user.add_argument("--capability", required=True)
    grant_air_user.add_argument("--scope", action="append", default=[])
    ensure_air_grant = sub.add_parser("ensure-air-grant")
    ensure_air_grant.add_argument("--user", required=True)
    ensure_air_grant.add_argument("--capability", required=True)
    ensure_air_grant.add_argument("--scope", action="append", default=[])
    pair_air = sub.add_parser("issue-air-pairing", aliases=["issue-member-pairing"])
    pair_air.add_argument("--user", required=True)
    pair_air.add_argument("--platform", choices=["macos", "windows"], required=True)
    pair_air.add_argument("--ttl", type=int, default=3600)
    revoke_air = sub.add_parser("revoke-air-device", aliases=["revoke-member-device"])
    revoke_air.add_argument("--user", required=True)
    revoke_air.add_argument("--device", required=True)
    sub.add_parser("cleanup-air-content", aliases=["cleanup-member-content"])
    sub.add_parser("doctor")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    store = Store(args.root)
    store.initialize()
    if args.command == "init":
        print(json.dumps({"result": "initialized", "version": VERSION}))
        return 0
    if args.command == "issue-enrollment":
        if args.ttl < 60 or args.ttl > 86_400:
            raise ControlPlaneError("enrollment ttl must be between 60 and 86400 seconds")
        token = store.issue_enrollment(args.device, args.role, args.ttl)
        print(token)
        return 0
    if args.command in {"create-air-user", "create-member"}:
        result = store.member_registry.provision_air_user(args.display_name, args.identity_alias, role=args.role)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if args.command == "ensure-air-user":
        result = store.member_registry.ensure_air_user(args.identity_alias, role=args.role)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if args.command in {"grant-air-user", "grant-member"}:
        result = store.member_registry.put_grant(args.user, args.capability, args.scope)
        print(json.dumps({"grant": result}, ensure_ascii=False))
        return 0
    if args.command == "ensure-air-grant":
        result = store.member_registry.ensure_grant(args.user, args.capability, args.scope)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if args.command in {"issue-air-pairing", "issue-member-pairing"}:
        token = store.member_enrollments.issue(args.user, args.platform, args.ttl)
        print(token)
        return 0
    if args.command in {"revoke-air-device", "revoke-member-device"}:
        result = store.member_registry.revoke_device(args.user, args.device)
        print(json.dumps({"device": result}, ensure_ascii=False))
        return 0
    if args.command in {"cleanup-air-content", "cleanup-member-content"}:
        result = store.cleanup_member_content()
        print(json.dumps(result, ensure_ascii=False))
        return 1 if result["failures"] else 0
    if args.command == "doctor":
        state = store.state()
        member_state = store.member_registry.read()
        pairing_state = store.member_enrollments.read()
        cleanup_state = read_json(store.member_cleanup_state)
        now_epoch = int(time.time())
        print(json.dumps({
            "result": "ok",
            "version": VERSION,
            "devices": len(state.get("devices", {})),
            "unused_enrollments": sum(1 for item in state.get("enrollments", {}).values() if not item.get("used")),
            "jobs": len(list(store.jobs_dir.glob("job-*/job.json"))),
            "artifacts": len(list(store.artifacts_dir.glob("art-*/artifact.json"))),
            "modules": len(store.manifest().get("modules", [])),
            "capabilities": len(store.capability_manifest().get("capabilities", [])),
            "inventory_entries": len(store.capability_inventory().get("entries", [])),
            "models": len(store.models().get("models", [])),
            "member_users": len(member_state["users"]),
            "active_member_devices": sum(1 for item in member_state["devices"] if item["status"] == "active"),
            "open_member_pairings": sum(
                1 for item in pairing_state["enrollments"].values()
                if item["used_at"] is None and item["expires_at_epoch"] >= now_epoch
            ),
            "member_signature_verifier": "available" if shutil.which("openssl") else "unavailable",
            "member_cleanup_result": cleanup_state["result"],
            "member_cleanup_last_run_at": cleanup_state["last_run_at"],
            "member_cleanup_failure_count": cleanup_state["failure_count"],
        }))
        return 0
    if args.command == "serve":
        if args.bind not in {"127.0.0.1", "::1", "localhost"} and os.environ.get("WU_REMOTE_ALLOW_PUBLIC_BIND") != "1":
            raise ControlPlaneError("public bind is forbidden")
        openssl = shutil.which("openssl")
        member_authenticator = None
        if openssl:
            member_authenticator = MemberSignatureAuthenticator(
                store.member_registry,
                store.check_nonce,
                Path(openssl),
            )
        approval_verifier = member_authenticator.verify if member_authenticator else None
        server = Server((args.bind, args.port), store, member_authenticator, approval_verifier)
        print(json.dumps({"result": "serving", "bind": args.bind, "port": args.port, "version": VERSION}), flush=True)
        server.serve_forever()
        return 0
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ControlPlaneError as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(2)
