# Windows Two-Headed-Wu Air release gate

This directory is source, not a pretrusted installer. A production package must be built on a controlled Windows
signing machine with an Authenticode code-signing certificate whose private key never enters Git, Aliyun, Mini task
state, or an Air package.

The public installation is `%LOCALAPPDATA%\TwoHeadWu\Air`, the executable is `two-head-wu-air.exe`, and the scheduled
task is `TwoHeadWu Air Health`. PowerShell source filenames and the TPM key name retain `MemberAir` only for source and
hardware-binding compatibility; they do not create a separate member client or permission class.

## Build and sign

Cross-compile the Go source in `native/member-air` as `two-head-wu-air.exe`, transfer only the binary and this source
directory to the signing machine, then run Windows PowerShell 5.1 as the certificate owner:

```powershell
.\New-MemberAirPackage.ps1 `
  -MemberAirExe C:\Build\two-head-wu-air.exe `
  -Version 0.12.0 `
  -CertificateThumbprint '<AUTHENTICODE LEAF THUMBPRINT>' `
  -OutputDirectory C:\Build\out
```

The builder requires a code-signing EKU, SHA-256, and HTTPS timestamping. It signs each executable file, creates and
signs a Windows Catalog over the exact payload, verifies all signatures, then emits a ZIP and delivery hash. The hash
detects transfer damage; Windows trust plus the pinned publisher certificate authorizes installation and updates.

## Install and update

The Air user should inspect the installer signature in Windows Properties before first use, then run:

```powershell
$Pairing = Read-Host 'One-time Air pairing token' -AsSecureString
.\Install-MemberAir.ps1 `
  -Endpoint 'https://<registered-relay>/two-head-wu/v2' `
  -PairingToken $Pairing
```

The installer rejects an invalid trust chain, mixed publishers, unexpected files, reparse points, catalog drift, and
downgrades. It pins the leaf publisher thumbprint. Updates are explicit:

```powershell
& "$env:LOCALAPPDATA\TwoHeadWu\Air\releases\<CURRENT>\Update-MemberAir.ps1" `
  -PackageRoot C:\Users\<AIR-USER>\Downloads\next-package
```

Certificate rotation is a new trusted installation ceremony, not an ordinary update.

## Real-device acceptance

```powershell
& "$env:LOCALAPPDATA\TwoHeadWu\Air\releases\<CURRENT>\Test-MemberAirInstallation.ps1"
& "$env:LOCALAPPDATA\TwoHeadWu\Air\releases\<CURRENT>\Test-MemberAirInstallation.ps1" -Online
```

Before the Windows gate closes, retain redacted evidence that:

1. the key provider is `Microsoft Platform Crypto Provider`, P-256, non-exportable, and PKCS#8 export fails;
2. the enrolled desktop user's daily task invokes only signed `diagnose`, times out within five minutes, survives a
   reboot, and opens no listening socket;
3. a signed higher version updates while downgrade, modified same-version, extra file, reparse point, unsigned file,
   different signer, and untrusted signer all fail before execution;
4. copying `%LOCALAPPDATA%\TwoHeadWu` to another machine fails diagnosis because the registered hardware key is absent;
5. a second machine cannot enroll for the same user until Mini revokes the first, after which the old Air fails and
   only the replacement can pair;
6. owner step-up accepts exactly the fixed four-space local mistake-prevention code, never transmits it, and rejects
   three/five spaces, replay, or changed action parameters;
7. default uninstall preserves binding and TPM key; deletion requires both `-RemoveDeviceBinding` and
   `-AdministratorRevoked` after Mini-side revocation.

Evidence may contain only versions, signature status, certificate thumbprint, opaque user/device IDs, result, and
timestamps. Do not capture tokens, Codex auth, local usernames, personal paths, or private-key material.
