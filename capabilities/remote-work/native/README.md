# Unified Two-Headed-Wu Air client

`member-air/` is the shared Go source for the one macOS/Windows Air client, published as `two-head-wu-air`.
The source directory and a few internal key labels retain `member` only to preserve v2 device bindings created
during construction; they do not define a second product, worker, permission tier, or administrator role.

Every Air has the same public surface:

- one opaque user and one hardware-bound `air` device;
- one fixed Codex account binding;
- signed capability and module discovery;
- portable Skill installation;
- exact registered Mini capability calls;
- explicit project submission, task interaction, and review-only result receipt.

Mini is the only administrative machine. User role (`owner` or `member`) and device identity are grant inputs, not
different clients. The registered owner Air may see exact extra capabilities such as `memory:notebook`, but it does
not gain Mini settings, source modification, arbitrary filesystem access, SSH, or a remote shell.

## Device binding

`enroll` reads a short-lived token from an explicitly named environment variable, removes it before network access,
creates a non-exportable P-256 device key, signs the token hash, and stores only endpoint plus opaque user/device IDs.
It requires HTTPS, refuses redirects and refuses to replace an existing binding. Re-pairing requires Mini-side
revocation.

- macOS uses a permanent `ThisDeviceOnly` Secure Enclave key.
- Windows uses `Microsoft Platform Crypto Provider`, ECDSA P-256, and `CngExportPolicies.None`.

The retained key identifiers `com.twoheadwu.member-air.v2` and `TwoHeadWu.MemberAir.v2` are compatibility IDs.
Renaming them would silently break the one-device guarantee, so the public product name changes without re-keying.

`diagnose` makes a signed `/me` request and checks the user, device, OS and Codex binding. Copying `air.json` to a
different computer cannot pass without the hardware key. The old `member.json` is accepted only for a verified
one-time migration to `air.json`, then removed; the client never maintains two configurations.

## Signed modules and calls

`modules` verifies the directory against the public key embedded at build time. `module-pull` verifies module grant,
classification, size, SHA-256 and archive paths, then atomically installs only a managed `skill:*` target under
`~/.agents/skills`. It rejects traversal, links, special files, credentials and replacement of unmanaged Skills.

`invoke` verifies the signed capability directory before it accepts an exact capability ID and JSON input. Ordinary
calls need no password. A capability marked `owner-password` asks in the local terminal for the Two-Headed-Wu approval
password, decrypts a local P-256 approval key, and signs the exact action digest, expiry and nonce. The password and
private approval key never leave Air. Notebook operations use `confirmation: none`; step-up is reserved for explicit
high-risk external writes.

## Projects and results

`submit` packages only a selected project and optional explicit regular files. It skips symlinks, credentials, key
material, VCS data, dependencies and caches; scans secret and private-path patterns; and limits content to 50 MiB and
10,000 entries. Draft, upload and final submit are separate, digest-bound, idempotent steps, so Mini cannot lease a
partial project after a network break.

`fetch` checks the result ContentLease size and SHA-256, fsyncs and atomically stores the archive in the Air review
directory, and only then sends a receipt. It does not unpack or apply files. `interactions`, `reply`, and `answer`
operate only on the authenticated user's task; displayed prompt text is never executed and answer text passes local
secret DLP.

## Windows release status

The Windows source includes Authenticode signing, a signed Windows Catalog, publisher pinning, explicit upgrade,
scheduled outbound diagnosis, and revocation-gated destructive uninstall. Source tests and Go cross-compilation can
run on Mini. A real code-signing certificate and Windows TPM machine are still required for the release gate described
in [windows/README.md](windows/README.md).

## macOS release status

The macOS source includes architecture-specific arm64/amd64 `.pkg` builds that require Developer ID Application and Installer
identities and notarization. It installs only `two-head-wu-air` and `member-key` and creates no background service or
listener. The package must be built on the matching architecture. Source and build-plan tests can run on Mini;
signing, notarization, Secure Enclave copy/revocation, and
owner step-up acceptance remain the real-device gate described in [macos/README.md](macos/README.md).
