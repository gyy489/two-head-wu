#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import http.client
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT / "server"
sys.path.insert(0, str(SERVER_DIR))
import member_auth as AUTH  # noqa: E402
import multi_user_contracts as CONTRACTS  # noqa: E402

CONTROL_SPEC = importlib.util.spec_from_file_location("pairing_control_plane", SERVER_DIR / "control_plane.py")
assert CONTROL_SPEC and CONTROL_SPEC.loader
CONTROL = importlib.util.module_from_spec(CONTROL_SPEC)
CONTROL_SPEC.loader.exec_module(CONTROL)


class MemberSignatureAuthenticatorTest(unittest.TestCase):
    def setUp(self) -> None:
        openssl = shutil.which("openssl")
        if not openssl:
            self.skipTest("openssl is unavailable")
        self.openssl = Path(openssl)
        self.temporary = tempfile.TemporaryDirectory(prefix="two-head-wu-member-signature-")
        self.directory = Path(self.temporary.name)
        self.private_key = self.directory / "private.pem"
        subprocess.run(
            [str(self.openssl), "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(self.private_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        public_key = subprocess.run(
            [str(self.openssl), "pkey", "-in", str(self.private_key), "-pubout", "-outform", "DER"],
            check=True,
            capture_output=True,
        ).stdout
        self.public_key_base64 = base64.b64encode(public_key).decode()
        self.registry = CONTRACTS.MemberRegistry(self.directory / "members-v2.json")
        self.registry.initialize()
        self.user_id = "usr-signature-a001"
        self.device_id = "dev-signature-a001"
        self.registry.create_user("signature member", user_id=self.user_id)
        self.registry.enroll_device(
            self.user_id,
            platform="macos",
            key_provider="secure-enclave",
            public_key_spki_base64=self.public_key_base64,
            device_id=self.device_id,
        )
        self.registry.bind_codex(self.user_id, "signature-member", binding_id="cdx-signature-a001")
        self.seen: set[str] = set()

        def check_nonce(device_id: str, nonce: str, _timestamp: int) -> None:
            key = f"{device_id}:{nonce}"
            if key in self.seen:
                raise ValueError("replay")
            self.seen.add(key)

        self.authenticator = AUTH.MemberSignatureAuthenticator(
            self.registry,
            check_nonce,
            self.openssl,
            now=lambda: 1_788_300_000,
        )

    def tearDown(self) -> None:
        if hasattr(self, "temporary"):
            self.temporary.cleanup()

    def headers(self, method: str, path: str, body: bytes, *, timestamp: str = "1788300000", nonce: str = "a" * 32) -> dict[str, str]:
        digest = hashlib.sha256(body).hexdigest()
        canonical = AUTH.canonical_request(
            method,
            path,
            self.user_id,
            self.device_id,
            timestamp,
            nonce,
            digest,
        )
        signature = subprocess.run(
            [str(self.openssl), "dgst", "-sha256", "-sign", str(self.private_key)],
            input=canonical,
            check=True,
            capture_output=True,
        ).stdout
        return {
            "X-Wu-User": self.user_id,
            "X-Wu-Device": self.device_id,
            "X-Wu-Time": timestamp,
            "X-Wu-Nonce": nonce,
            "X-Wu-Body-SHA256": digest,
            "X-Wu-Signature": base64.b64encode(signature).decode(),
        }

    def test_valid_signature_is_accepted_once(self) -> None:
        body = b'{"request_id":"call-aaaaaaaaaaaaaaaaaaaaaaaa"}'
        path = "/two-head-wu/v2/jobs"
        headers = self.headers("POST", path, body)
        principal = self.authenticator("POST", path, body, headers)
        self.assertEqual(principal, {"user_id": self.user_id, "device_id": self.device_id})
        with self.assertRaisesRegex(ValueError, "replay"):
            self.authenticator("POST", path, body, headers)

    def test_body_path_time_and_signature_tampering_fail(self) -> None:
        body = b"{}"
        path = "/two-head-wu/v2/jobs"
        valid = self.headers("POST", path, body)
        attempts = (
            ("POST", path, b'{"changed":true}', valid),
            ("POST", path + "/other", body, valid),
            ("POST", path, body, self.headers("POST", path, body, timestamp="1788299000", nonce="b" * 32)),
            ("POST", path, body, {**valid, "X-Wu-Signature": base64.b64encode(b"not-a-signature").decode()}),
        )
        for method, request_path, request_body, headers in attempts:
            with self.subTest(path=request_path, body=request_body):
                with self.assertRaises(AUTH.MemberAuthenticationError):
                    self.authenticator(method, request_path, request_body, headers)

    def test_revoked_device_and_non_p256_enrollment_fail(self) -> None:
        body = b"{}"
        path = "/two-head-wu/v2/me"
        headers = self.headers("GET", path, body)
        self.registry.revoke_device(self.user_id, self.device_id)
        with self.assertRaises(AUTH.MemberAuthenticationError):
            self.authenticator("GET", path, body, headers)

        other_private = self.directory / "p384.pem"
        subprocess.run(
            [str(self.openssl), "ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", str(other_private)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        other_public = subprocess.run(
            [str(self.openssl), "pkey", "-in", str(other_private), "-pubout", "-outform", "DER"],
            check=True,
            capture_output=True,
        ).stdout
        with self.assertRaisesRegex(CONTRACTS.ContractError, "P-256"):
            self.registry.enroll_device(
                self.user_id,
                platform="macos",
                key_provider="secure-enclave",
                public_key_spki_base64=base64.b64encode(other_public).decode(),
                device_id="dev-signature-p384",
            )

    def test_http_pairing_proves_key_possession_and_consumes_token(self) -> None:
        store = CONTROL.Store(self.directory / "control-plane")
        store.initialize()
        provisioned = store.member_registry.provision_member("paired member", "paired-member")
        user_id = provisioned["user"]["id"]
        token = store.member_enrollments.issue(user_id, "macos", 600)
        timestamp = str(int(time.time()))
        nonce = "c" * 32
        canonical = AUTH.canonical_enrollment(
            store.member_enrollments.token_hash(token),
            "macos",
            "secure-enclave",
            self.public_key_base64,
            timestamp,
            nonce,
        )
        signature = subprocess.run(
            [str(self.openssl), "dgst", "-sha256", "-sign", str(self.private_key)],
            input=canonical,
            check=True,
            capture_output=True,
        ).stdout
        payload = {
            "platform": "macos",
            "key_provider": "secure-enclave",
            "public_key_spki_base64": self.public_key_base64,
            "timestamp": timestamp,
            "nonce": nonce,
            "signature_base64": base64.b64encode(signature).decode(),
        }
        authenticator = AUTH.MemberSignatureAuthenticator(
            store.member_registry,
            store.check_nonce,
            self.openssl,
        )
        server = CONTROL.Server(("127.0.0.1", 0), store, authenticator)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            statuses = []
            for _ in range(2):
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
                connection.request(
                    "POST",
                    "/two-head-wu/v2/enroll",
                    body=json.dumps(payload).encode(),
                    headers={"Authorization": f"MemberEnrollment {token}", "Content-Type": "application/json"},
                )
                response = connection.getresponse()
                response.read()
                statuses.append(response.status)
                connection.close()
            self.assertEqual(statuses, [201, 401])
            devices = store.member_registry.read()["devices"]
            self.assertEqual(len(devices), 1)
            self.assertEqual(devices[0]["user_id"], user_id)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
