# Member request authentication v2

Every authenticated `/two-head-wu/v2` request uses an ECDSA P-256 hardware-backed device key. The server stores only
the DER SubjectPublicKeyInfo public key. A request carries these headers:

- `X-Wu-User`: opaque member user ID;
- `X-Wu-Device`: the member's single active Air device ID;
- `X-Wu-Time`: Unix seconds, accepted within 300 seconds of server time;
- `X-Wu-Nonce`: 32 lowercase hexadecimal characters, accepted once per device;
- `X-Wu-Body-SHA256`: lowercase SHA-256 of the exact HTTP body, including the empty body;
- `X-Wu-Signature`: Base64 of the ASN.1 DER ECDSA/SHA-256 signature.

The signed bytes are UTF-8 lines with no final newline:

```text
TWO-HEAD-WU-MEMBER-V2
<UPPERCASE METHOD>
<EXACT PATH INCLUDING QUERY>
<USER ID>
<DEVICE ID>
<UNIX SECONDS>
<NONCE>
<BODY SHA-256>
```

The server first verifies the body digest, active user/device/binding and signature, then atomically consumes the nonce.
Missing, stale, malformed, replayed, revoked, wrong-path, wrong-body and wrong-key requests fail with HTTP 401. Business
handlers independently repeat tenant ownership checks; a valid signature never grants access to another user's object.

## One-time device pairing

An administrator first creates the opaque member and fixed Codex binding, grants explicit capabilities, then issues a
short-lived `pair-*` token for exactly one platform. Aliyun persists only `SHA-256(token)`. The Air generates its key
locally and sends `POST /two-head-wu/v2/enroll` with `Authorization: MemberEnrollment <token>` and the exact fields
`platform`, `key_provider`, `public_key_spki_base64`, `timestamp`, `nonce`, and `signature_base64`.

The new key signs these UTF-8 lines with no final newline:

```text
TWO-HEAD-WU-MEMBER-ENROLL-V2
<PAIRING TOKEN SHA-256>
<PLATFORM>
<KEY PROVIDER>
<PUBLIC KEY SPKI BASE64>
<UNIX SECONDS>
<NONCE>
```

The server checks token expiry, the administrator-selected platform/provider, P-256 format, proof of private-key
possession, the single-active-device invariant, and one-time token consumption before returning the new device ID.
Re-pairing requires administrator revocation of the old device first.
