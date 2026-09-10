#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Online
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Thumbprint([string]$Value) {
    return (($Value -replace '[^A-Fa-f0-9]', '').ToUpperInvariant())
}

$InstallRoot = Join-Path $env:LOCALAPPDATA 'TwoHeadWu\Air'
$StatePath = Join-Path $InstallRoot 'install.json'
if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw 'member Air installation state is unavailable'
}
$State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$Publisher = Normalize-Thumbprint ([string]$State.publisher_thumbprint)
$ReleaseRoot = [IO.Path]::GetFullPath([string]$State.release_root)
$ExpectedPrefix = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'releases')) + [IO.Path]::DirectorySeparatorChar
if (-not $ReleaseRoot.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'member Air release root escaped the installation directory'
}

$Files = @(
    'two-head-wu-air.exe', 'MemberKey.ps1', 'Invoke-MemberAirHealth.ps1',
    'Update-MemberAir.ps1', 'Uninstall-MemberAir.ps1', 'Test-MemberAirInstallation.ps1'
)
foreach ($Name in $Files) {
    $Path = Join-Path $ReleaseRoot $Name
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    $Actual = if ($null -eq $Signature.SignerCertificate) { '' } else {
        Normalize-Thumbprint $Signature.SignerCertificate.Thumbprint
    }
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $Actual -ne $Publisher) {
        throw "installed member Air signature or publisher pin failed: $Name"
    }
}

$Provider = [Security.Cryptography.CngProvider]::new('Microsoft Platform Crypto Provider')
$Options = [Security.Cryptography.CngKeyOpenOptions]::UserKey
if (-not [Security.Cryptography.CngKey]::Exists('TwoHeadWu.MemberAir.v2', $Provider, $Options)) {
    throw 'member Air TPM key is unavailable'
}
$Key = [Security.Cryptography.CngKey]::Open('TwoHeadWu.MemberAir.v2', $Provider, $Options)
try {
    if ($Key.Provider.Provider -ne $Provider.Provider -or $Key.Algorithm.Algorithm -ne 'ECDSA_P256') {
        throw 'member Air key is not TPM-backed ECDSA P-256'
    }
    if ($Key.ExportPolicy -ne [Security.Cryptography.CngExportPolicies]::None) {
        throw 'member Air TPM key has an export policy'
    }
    try {
        [void]$Key.Export([Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
        throw 'member Air TPM private key was exportable'
    } catch [Security.Cryptography.CryptographicException] {
        # Expected: the device key is non-exportable.
    }
} finally {
    $Key.Dispose()
}

$Task = Get-ScheduledTask -TaskName 'TwoHeadWu Air Health' -ErrorAction Stop
$Action = @($Task.Actions)
if ($Action.Count -ne 1 -or $Action[0].Execute -notmatch '(?i)powershell(?:\.exe)?$' -or
    $Action[0].Arguments -notmatch '(?i)-ExecutionPolicy\s+AllSigned' -or
    $Action[0].Arguments -notmatch [regex]::Escape((Join-Path $ReleaseRoot 'Invoke-MemberAirHealth.ps1'))) {
    throw 'member Air health task action is invalid'
}
if ($Action[0].Arguments -match '(?i)(listen|server|http://)') {
    throw 'member Air health task contains an inbound or insecure transport argument'
}

$Identity = $null
if ($Online) {
    $Raw = & (Join-Path $ReleaseRoot 'two-head-wu-air.exe') diagnose
    if ($LASTEXITCODE -ne 0) { throw 'member Air online diagnosis failed' }
    $Identity = $Raw | ConvertFrom-Json
    if ($Identity.result -ne 'ok' -or $Identity.platform -ne 'windows') {
        throw 'member Air online diagnosis returned invalid identity data'
    }
}

[PSCustomObject]@{
    result = 'ok'
    version = [string]$State.version
    publisher_thumbprint = $Publisher
    tpm_key = 'non-exportable-ecdsa-p256'
    scheduled_health = 'daily-outbound-only'
    online = [bool]$Online
    user_id = if ($null -eq $Identity) { $null } else { [string]$Identity.user_id }
    device_id = if ($null -eq $Identity) { $null } else { [string]$Identity.device_id }
} | ConvertTo-Json -Compress
