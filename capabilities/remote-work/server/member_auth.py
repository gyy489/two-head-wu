#!/usr/bin/env python3
"""P-256 request authentication for the member v2 control-plane routes."""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
import subprocess
import tempfile
import textwrap
import time
from pathlib import Path
from typing import Any, Callable

from multi_user_contracts import ContractError, MemberRegistry, TenantAccessError, p256_public_key_der


AUTH_SCHEME = "TWO-HEAD-WU-MEMBER-V2"
REQUEST_WINDOW = 300
NONCE_RE = re.compile(r"^[a-f0-9]{32}$")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
REQUIRED_HEADER_NAMES = (
    "X-Wu-User",
    "X-Wu-Device",
    "X-Wu-Time",
    "X-Wu-Nonce",
    "X-Wu-Body-SHA256",
    "X-Wu-Signature",
)
REQUIRED_HEADERS = {name.lower() for name in REQUIRED_HEADER_NAMES}


class MemberAuthenticationError(ValueError):
    pass


def canonical_request(
    method: str,
    path: str,
    user_id: str,
    device_id: str,
    timestamp: str,
    nonce: str,
    body_sha256: str,
) -> bytes:
    return "\n".join([
        AUTH_SCHEME,
        method.upper(),
        path,
        user_id,
        device_id,
        timestamp,
        nonce,
        body_sha256,
    ]).encode("utf-8")


def canonical_enrollment(
    token_hash: str,
    platform: str,
    key_provider: str,
    public_key_spki_base64: str,
    timestamp: str,
    nonce: str,
) -> bytes:
    return "\n".join([
        "TWO-HEAD-WU-MEMBER-ENROLL-V2",
        token_hash,
        platform,
        key_provider,
        public_key_spki_base64,
        timestamp,
        nonce,
    ]).encode("utf-8")


class MemberSignatureAuthenticator:
    """Verify an ECDSA P-256/SHA-256 signature and then consume its nonce."""

    required_header_names = REQUIRED_HEADER_NAMES

    def __init__(
        self,
        registry: MemberRegistry,
        check_nonce: Callable[[str, str, int], None],
        openssl_path: Path,
        *,
        now: Callable[[], float] = time.time,
    ) -> None:
        self.registry = registry
        self.check_nonce = check_nonce
        self.openssl_path = openssl_path.resolve()
        self.now = now
        if not self.openssl_path.is_file() or not os.access(self.openssl_path, os.X_OK):
            raise MemberAuthenticationError("member signature verifier is unavailable")

    def __call__(self, method: str, path: str, body: bytes, raw_headers: dict[str, str]) -> dict[str, str]:
        headers = {key.lower(): value for key, value in raw_headers.items()}
        if not REQUIRED_HEADERS.issubset(headers):
            raise MemberAuthenticationError("member request authentication failed")
        user_id = headers["x-wu-user"]
        device_id = headers["x-wu-device"]
        timestamp_text = headers["x-wu-time"]
        nonce = headers["x-wu-nonce"]
        body_sha256 = headers["x-wu-body-sha256"]
        try:
            timestamp = int(timestamp_text)
        except ValueError as error:
            raise MemberAuthenticationError("member request authentication failed") from error
        if abs(int(self.now()) - timestamp) > REQUEST_WINDOW or not NONCE_RE.fullmatch(nonce):
            raise MemberAuthenticationError("member request authentication failed")
        actual_body_sha256 = hashlib.sha256(body).hexdigest()
        if not SHA256_RE.fullmatch(body_sha256) or not hmac.compare_digest(body_sha256, actual_body_sha256):
            raise MemberAuthenticationError("member request authentication failed")
        try:
            signature = base64.b64decode(headers["x-wu-signature"], validate=True)
        except (ValueError, TypeError) as error:
            raise MemberAuthenticationError("member request authentication failed") from error
        if not 8 <= len(signature) <= 80:
            raise MemberAuthenticationError("member request authentication failed")

        try:
            principal = self.registry.principal(user_id, device_id)
            public_key_der = base64.b64decode(
                principal["device"]["public_key_spki_base64"],
                validate=True,
            )
        except (ContractError, TenantAccessError, ValueError, TypeError) as error:
            raise MemberAuthenticationError("member request authentication failed") from error
        canonical = canonical_request(
            method,
            path,
            user_id,
            device_id,
            timestamp_text,
            nonce,
            body_sha256,
        )
        if not self.verify(public_key_der, signature, canonical):
            raise MemberAuthenticationError("member request authentication failed")
        self.check_nonce(device_id, nonce, timestamp)
        return {"user_id": user_id, "device_id": device_id}

    def verify(self, public_key_der: bytes, signature: bytes, canonical: bytes) -> bool:
        encoded_key = base64.b64encode(public_key_der).decode("ascii")
        public_key_pem = "-----BEGIN PUBLIC KEY-----\n"
        public_key_pem += "\n".join(textwrap.wrap(encoded_key, 64))
        public_key_pem += "\n-----END PUBLIC KEY-----\n"
        with tempfile.TemporaryDirectory(prefix="two-head-wu-member-auth-") as temporary:
            directory = Path(temporary)
            public_key_path = directory / "public.pem"
            signature_path = directory / "signature.der"
            public_key_path.write_text(public_key_pem, encoding="ascii")
            signature_path.write_bytes(signature)
            os.chmod(public_key_path, 0o600)
            os.chmod(signature_path, 0o600)
            try:
                result = subprocess.run(
                    [
                        str(self.openssl_path),
                        "dgst",
                        "-sha256",
                        "-verify",
                        str(public_key_path),
                        "-signature",
                        str(signature_path),
                    ],
                    input=canonical,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                    env={"LC_ALL": "C"},
                )
            except (OSError, subprocess.TimeoutExpired):
                return False
        return result.returncode == 0

    def verify_enrollment(
        self,
        *,
        token_hash: str,
        platform: str,
        key_provider: str,
        public_key_spki_base64: str,
        timestamp: str,
        nonce: str,
        signature_base64: str,
    ) -> None:
        try:
            timestamp_epoch = int(timestamp)
        except ValueError as error:
            raise MemberAuthenticationError("member pairing proof failed") from error
        if abs(int(self.now()) - timestamp_epoch) > REQUEST_WINDOW or not NONCE_RE.fullmatch(nonce):
            raise MemberAuthenticationError("member pairing proof failed")
        try:
            public_key_der = p256_public_key_der(public_key_spki_base64)
            signature = base64.b64decode(signature_base64, validate=True)
        except (ContractError, ValueError, TypeError) as error:
            raise MemberAuthenticationError("member pairing proof failed") from error
        if not 8 <= len(signature) <= 80:
            raise MemberAuthenticationError("member pairing proof failed")
        canonical = canonical_enrollment(
            token_hash,
            platform,
            key_provider,
            public_key_spki_base64,
            timestamp,
            nonce,
        )
        if not self.verify(public_key_der, signature, canonical):
            raise MemberAuthenticationError("member pairing proof failed")
