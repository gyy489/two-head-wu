#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Thumbprint([string]$Value) {
    return (($Value -replace '[^A-Fa-f0-9]', '').ToUpperInvariant())
}

$InstallRoot = Join-Path $env:LOCALAPPDATA 'TwoHeadWu\Air'
$InstallState = Join-Path $InstallRoot 'install.json'
if (-not (Test-Path -LiteralPath $InstallState -PathType Leaf)) {
    throw 'member Air installation state is unavailable'
}

$State = Get-Content -LiteralPath $InstallState -Raw | ConvertFrom-Json
$PinnedPublisher = Normalize-Thumbprint ([string]$State.publisher_thumbprint)
if ($PinnedPublisher -notmatch '^[A-F0-9]{40,128}$') {
    throw 'member Air publisher pin is invalid'
}

$ResolvedPackage = (Resolve-Path -LiteralPath $PackageRoot).Path
$PackageItem = Get-Item -LiteralPath $ResolvedPackage -Force
if (-not $PackageItem.PSIsContainer -or ($PackageItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'member Air update package must be a regular directory'
}

$Installer = Join-Path $ResolvedPackage 'Install-MemberAir.ps1'
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw 'member Air update installer is unavailable'
}
$Signature = Get-AuthenticodeSignature -LiteralPath $Installer
$CandidatePublisher = if ($null -eq $Signature.SignerCertificate) { '' } else {
    Normalize-Thumbprint $Signature.SignerCertificate.Thumbprint
}
if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $CandidatePublisher -ne $PinnedPublisher) {
    throw 'member Air update publisher does not match the installed trust pin'
}

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File $Installer -PackageRoot $ResolvedPackage -UpdateOnly
if ($LASTEXITCODE -ne 0) {
    throw 'member Air update failed'
}
