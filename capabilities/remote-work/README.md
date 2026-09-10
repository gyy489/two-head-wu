# Remote Work

`remote-work` is the Two-Headed-Wu Air/Mini bridge. The target is deliberately small:

- one native Air client for macOS and Windows;
- one hardware-bound Air device per user;
- one low-privilege Mini Air Worker for every v2 user;
- one outbound connection from Air and one outbound polling connection from Mini through Aliyun;
- no listener on Mini and no remote Mini administrator or arbitrary shell.

Mini is the only administrative machine. The owner's Air and classmates' Air machines use the same client, device
role, request signing, task protocol, result flow, and worker. `owner` and `member` are user attributes used only when
Mini evaluates exact grants. The registered owner Air can therefore receive `memory:notebook` without receiving Mini
system, identity, source-code, SSH, or filesystem control.

## Current status

Version 0.12.0 is the unified Air source release. It includes:

- opaque users, one active device per user, device revocation, fixed Codex identity binding, and exact grants;
- Secure Enclave/TPM request signing and one-time migration from `member.json` to `air.json`;
- RSA-verified capability and module directories plus checked portable Skill installation;
- safe project capsules, recoverable staging, tenant-bound interactions, review-only results, receipts, and TTL state;
- a single `mac-mini-air-worker` queue and isolated Mini runtime skeleton;
- read-only research-library `search/get` for granted users;
- an owner-device-only notebook adapter with no general file or OpenClaw control surface;
- a separate local confirmation-key flow for exact high-risk external writes.
- signed native package sources: notarized per-architecture macOS `.pkg` files and an Authenticode/Catalog Windows ZIP.

Production still uses the legacy personal v1 route. The v2 source has not been deployed, no classmate has been
registered, the Air Worker service remains disabled, and both platforms still need real signing and hardware acceptance.
Source tests are not a production deployment claim.

## Trust and permission model

```text
Air (macOS/Windows) -- outbound HTTPS --> Aliyun relay <-- outbound poll -- Mini Air Worker
       |                                      |                         |
 hardware device key                  expiring task content       low-privilege UID
 signed directories                   state + hashes              per-task temporary root
 local review results                 no Mini secrets             exact adapters only
```

- Air signs every request over method, route, body hash, time, and nonce. Copying `air.json` cannot reproduce the
  non-exportable device key. A second computer must wait for Mini to revoke the first device.
- Aliyun may hold ordinary project/task content for the documented recovery period. Mini-local passwords, identity
  documents, bank details, Keychain data, Codex auth, SSH/cloud/database keys, MCP credentials, and unrelated private
  files are outside every request, adapter, log, and result.
- Capability discovery is not authorization. Air verifies the RSA signature; the relay and Mini then recheck the
  user, device, grant, schema, executor, runtime, tenant, and approval rule for each call.
- Project, paper, webpage, MCP, Skill, and model text is untrusted. It cannot change the frozen capability envelope,
  reach an arbitrary command/path/network target, obtain another user's content, or weaken a confirmation rule.
- Results are copied to the initiating Air's review directory and never applied automatically. A verified receipt or
  bounded TTL removes transient Mini/Aliyun content; only redacted audit state and hashes remain.

## Capability classes

| Audience | Meaning | Confirmation |
|---|---|---|
| `all-air` | ordinary functional Skills, project work, and granted research queries | none unless the entry says otherwise |
| `owner-air` | exact personal reads such as the small notebook on the registered owner device | none |
| `owner-step-up` | exact high-risk external writes, for example a future registered site publication | fixed local four-space confirmation code |

The confirmation code is exactly four spaces, as an intentional owner-selected mistake-prevention prompt rather than
an authentication secret. It never reaches Mini or Aliyun. It unlocks a software approval key stored only on Air and signs
the exact user, device, request, capability, canonical input hash, expiry, and nonce. Replay, target substitution, and
parameter substitution fail. The actual security boundaries remain the registered owner hardware key, owner grant, and
exact one-use signature. The code is not an account password and is not requested for the notebook or ordinary work.

Mini administration, Two-Headed-Wu development, arbitrary file access, arbitrary MCP endpoints, arbitrary database
queries, and arbitrary shell commands are not Air capabilities. The owner performs administration locally or through
a separate SSH session.

## Native Air commands

```text
two-head-wu-air diagnose
two-head-wu-air modules
two-head-wu-air module-pull <module-id>
two-head-wu-air invoke --capability <id> --input-json '<json>'
two-head-wu-air submit --project <path> [--artifact <file> ...] -- <instruction>
two-head-wu-air interactions <job-id>
two-head-wu-air reply <job-id> <ask-id> accept|decline|cancel
two-head-wu-air answer <job-id> <ask-id> -- <answer>
two-head-wu-air fetch <job-id>
```

Only the registered owner Air needs these optional step-up setup commands:

```text
two-head-wu-air approval-init
two-head-wu-air approval-register
two-head-wu-air approval-status
```

The Go source remains in `native/member-air` and the hardware key labels retain `member-air.v2` to preserve existing
device bindings. These are internal compatibility names, not a separate client. Public configuration is `air.json`;
an old `member.json` is verified, moved once, and removed. Windows public files install below
`%LOCALAPPDATA%\TwoHeadWu\Air`.

## Mini operator flow

The control plane provides canonical v2 commands and temporary aliases for migration:

```text
two-head-wu-control-plane create-air-user --display-name <name> --identity-alias <alias> [--role owner|member]
two-head-wu-control-plane ensure-air-user --identity-alias <alias> --role owner|member
two-head-wu-control-plane grant-air-user --user <opaque-id> --capability <id> [--scope <scope> ...]
two-head-wu-control-plane ensure-air-grant --user <opaque-id> --capability <id> [--scope <scope> ...]
two-head-wu-control-plane issue-air-pairing --user <opaque-id> --platform macos|windows
two-head-wu-control-plane revoke-air-device --user <opaque-id> --device <opaque-id>
two-head-wu-control-plane cleanup-air-content
two-head-wu-control-plane doctor
```

Real names, emails, tokens, and Codex login material are not committed. Each Codex identity is logged in separately on
Mini; credentials are never copied between accounts or sent through the relay.

The distributable program package is common to every account. Per-account generation is deliberately small: Mini
creates/reuses one opaque Air user, installs the exact default grant profile, and writes a one-hour, platform-bound
pairing kit below ignored `var/remote-work/air-pairing-kits/<alias>/`. It never embeds a Codex credential or device
private key in an installer. Run this only when handing the kit to its intended user:

```text
capabilities/remote-work/adapters/remote-work-deploy issue-air-pairing-kit \
  --project two-head-wu --approve --identity <alias> --role owner|member --platform macos|windows
```

The generated directory contains `pairing.token`, non-secret metadata, and platform instructions. The user installs
the separately signed common macOS/Windows package, and the Air creates its non-exportable hardware key during pairing.
An expired kit is reissued; account provisioning and default grants are idempotent.

The low-privilege runtime is still located at `/Library/TwoHeadedWu/member-worker` for installation compatibility.
Its public role and queue are unified Air. Installation is root-owned and idempotent; activation remains disabled
until enrollment and isolation health pass. Every install first records a persistent launchd disable override and
boots out any older loaded worker before replacing runtime files. `enable` is the only command that removes that
override, and only after enrollment plus `air-health` succeed:

```text
./capabilities/remote-work/installer/install-member-worker-runtime plan
sudo ./capabilities/remote-work/installer/install-member-worker-runtime install --approve
sudo ./capabilities/remote-work/installer/install-member-worker-runtime verify
sudo ./capabilities/remote-work/installer/install-member-worker-runtime register-air-identity --approve --identity <alias>
sudo ./capabilities/remote-work/installer/install-member-worker-runtime login-air-identity --approve --identity <alias>
capabilities/remote-work/adapters/remote-work-deploy issue-air-worker-enrollment --project two-head-wu --approve --device mac-mini-air-worker
sudo ./capabilities/remote-work/installer/install-member-worker-runtime enroll --approve --token-file <absolute-token-file>
sudo ./capabilities/remote-work/installer/install-member-worker-runtime enable --approve
```

Install also places a root-owned notebook adapter and a single exact passwordless sudo rule for that adapter. The
low-privilege Worker cannot read its config or invoke another root command. The adapter accepts only bounded
`recall`, `remember`, `correct`, and `forget` input and projects a path-free result. On an APFS volume mounted with
ownership disabled, installation adds an inherited deny ACL for the dedicated Worker account and performs a live
drop-privilege traversal probe; Unix owner metadata alone is not accepted as evidence of isolation.

Each Air user's alias is registered once inside the dedicated Worker identity registry and then logged in through
the official native `codex login --device-auth`. This includes owner aliases such as `owner-primary` and `owner-secondary`; they are not
copied from the owner's normal registry. Mini may register multiple owner-held Codex accounts, but each remains one
fixed Air user with one active device and no Mini administration power. The Worker accepts those reserved aliases only
for a relay-authenticated owner user, while a member job using the same alias fails with `identity_required`.

## Source verification and release gates

The public repository can run the portable contract and isolation checks without production bindings:

```text
ruby capabilities/remote-work/tests/test_protected_owner_notebook.rb
python3 capabilities/remote-work/tests/test_control_plane.py
python3 capabilities/remote-work/tests/test_multi_user_contracts.py
python3 capabilities/remote-work/tests/test_member_control_plane.py
python3 capabilities/remote-work/tests/test_member_auth.py
capabilities/remote-work/tests/test_native_member_keys.sh
(cd capabilities/remote-work/native/member-air && go test ./...)
```

`test_remote_work.rb`, `test_remote_work.sh`, release builds, real-device enrollment, and deployment gates require
the private Skill Release set, protected target binding, or production devices. Their source remains available for
review, but the public repository does not claim that those production gates can pass without operator-supplied state.

The public package includes its [macOS gate](native/macos/README.md),
[Windows gate](native/windows/README.md), contracts, control-plane source, and portable tests.
Private construction records, production bindings, signing identity, and deployment evidence are intentionally omitted.
