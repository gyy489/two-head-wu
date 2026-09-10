# macOS Two-Headed-Wu Air release gate

The macOS Air is delivered as a signed and notarized architecture-specific `.pkg`. Apple-silicon (`arm64`) and Intel
(`amd64`) packages contain the same Air client and protocol but are built on matching controlled Macs. Each installs only the command-line client
and its Secure Enclave helper. It installs no LaunchAgent, daemon, listener, updater, browser component, or Mini
administration tool.

## Build and sign

The build machine needs Apple Developer ID Application and Developer ID Installer identities plus a `notarytool`
Keychain profile. Their private keys and passwords must never enter Git, Aliyun, task state, or the package.

First inspect the non-mutating build plan:

```text
capabilities/remote-work/native/macos/Build-AirPackage plan --version 0.12.0 --architecture arm64
```

Then build on a controlled macOS signing machine:

```text
capabilities/remote-work/native/macos/Build-AirPackage build \
  --version 0.12.0 \
  --architecture arm64 \
  --application-identity 'Developer ID Application: ...' \
  --installer-identity 'Developer ID Installer: ...' \
  --notary-profile 'two-head-wu-air-notary' \
  --output-directory '/absolute/private/output'
```

Run the same procedure on an Intel signing Mac with `--architecture amd64` only if Intel support is needed. The
builder rejects cross-architecture packaging, applies the hardened runtime, signs both executables, builds a signed
Installer package, submits it for notarization, staples the ticket, and verifies the package with `pkgutil` and
Gatekeeper. It outputs the delivery SHA-256. Existing output is never overwritten.

## Install and pair

The Air user verifies that Finder reports the expected Developer ID publisher, then installs the package. macOS may
ask for the computer's administrator password because the two commands are placed under `/usr/local`; that password
is consumed by Apple's Installer and is not a Two-Headed-Wu credential.

Pairing is a separate user action. The one-time token must not be placed in shell history or passed in argv:

```zsh
read -r -s 'TWO_HEAD_WU_AIR_PAIRING?One-time Air pairing token: '
print
export TWO_HEAD_WU_AIR_PAIRING
two-head-wu-air enroll \
  --endpoint 'https://<registered-relay>/two-head-wu/v2' \
  --token-env TWO_HEAD_WU_AIR_PAIRING \
  --review-root "$HOME/Documents/TwoHeadWu/Review"
unset TWO_HEAD_WU_AIR_PAIRING
two-head-wu-air diagnose
```

The client removes the token from its own environment before network access. Its configuration is stored privately
at `~/Library/Application Support/TwoHeadWu/air.json`; the device private key is non-exportable and this-device-only
in Secure Enclave. Copying the configuration or installed commands to another Mac cannot clone the binding.

## Real-device acceptance

Before release, retain redacted evidence that:

1. both installed executables match the package architecture, carry the expected Developer ID signature, and the package passes
   notarization and Gatekeeper verification;
2. enrollment and signed `diagnose` work on an Apple-silicon Mac, and on an Intel/T2 Mac if Intel support is needed;
3. copying config and program files to another Mac fails because the Secure Enclave key is absent;
4. a second machine cannot enroll until Mini revokes the first, after which the old Air fails and the replacement
   succeeds;
5. the installation adds no launchd job and `two-head-wu-air` opens no listening socket;
6. ordinary notebook calls require no confirmation, while an exact `owner-step-up` test asks for the fixed local
   four-space mistake-prevention code and rejects three/five spaces, replay, or changed parameters.

Evidence may include only versions, signing status, Team ID, opaque user/device IDs, result, and timestamps. Never
capture pairing tokens, typed confirmations, Codex auth, usernames, personal paths, or private-key material.
