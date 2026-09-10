#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$PackageRoot = $PSScriptRoot,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Endpoint,

    [Parameter()]
    [string]$ReviewRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'TwoHeadWu\Review'),

    [Parameter()]
    [Security.SecureString]$PairingToken,

    [Parameter()]
    [switch]$UpdateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Thumbprint([string]$Value) {
    return (($Value -replace '[^A-Fa-f0-9]', '').ToUpperInvariant())
}

function Get-ValidPublisher([string]$Path) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $Signature.SignerCertificate) {
        throw "Authenticode validation failed: $([IO.Path]::GetFileName($Path))"
    }
    $Thumbprint = Normalize-Thumbprint $Signature.SignerCertificate.Thumbprint
    if ($Thumbprint -notmatch '^[A-F0-9]{40,128}$') {
        throw 'Authenticode publisher thumbprint is invalid'
    }
    return $Thumbprint
}

function Assert-RegularTree([string]$Root) {
    $RootItem = Get-Item -LiteralPath $Root -Force
    if (-not $RootItem.PSIsContainer -or ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'member Air package root must be a regular directory'
    }
    foreach ($Item in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'member Air package cannot contain reparse points'
        }
    }
}

function Assert-ExactNames([string]$Root, [string[]]$Expected) {
    $Actual = @(Get-ChildItem -LiteralPath $Root -Force | ForEach-Object { $_.Name } | Sort-Object)
    $Wanted = @($Expected | Sort-Object)
    if (($Actual -join "`n") -ne ($Wanted -join "`n")) {
        throw 'member Air package contains missing or unexpected files'
    }
}

$ResolvedPackage = (Resolve-Path -LiteralPath $PackageRoot).Path
Assert-RegularTree $ResolvedPackage
Assert-ExactNames $ResolvedPackage @('Install-MemberAir.ps1', 'Air.cat', 'payload')
$Payload = Join-Path $ResolvedPackage 'payload'
Assert-ExactNames $Payload @('Invoke-MemberAirHealth.ps1', 'MemberKey.ps1', 'Test-MemberAirInstallation.ps1', 'Update-MemberAir.ps1', 'Uninstall-MemberAir.ps1', 'two-head-wu-air.exe', 'release.json')

$Publisher = Get-ValidPublisher $PSCommandPath
$Catalog = Join-Path $ResolvedPackage 'Air.cat'
if ((Get-ValidPublisher $Catalog) -ne $Publisher) {
    throw 'member Air catalog publisher does not match the installer'
}
$CatalogStatus = (Test-FileCatalog -Path $Payload -CatalogFilePath $Catalog -Detailed).Status
if ($CatalogStatus.ToString() -ne 'Valid') {
    throw 'member Air payload does not match its signed Windows catalog'
}
foreach ($Name in @('Invoke-MemberAirHealth.ps1', 'MemberKey.ps1', 'Test-MemberAirInstallation.ps1', 'Update-MemberAir.ps1', 'Uninstall-MemberAir.ps1', 'two-head-wu-air.exe')) {
    if ((Get-ValidPublisher (Join-Path $Payload $Name)) -ne $Publisher) {
        throw "member Air payload publisher mismatch: $Name"
    }
}

$Release = Get-Content -LiteralPath (Join-Path $Payload 'release.json') -Raw | ConvertFrom-Json
if ($Release.schema_version -ne 1 -or $Release.platform -ne 'windows' -or $Release.architecture -ne 'amd64') {
    throw 'member Air release metadata is invalid'
}
try { $CandidateVersion = [version]([string]$Release.version) } catch { throw 'member Air release version is invalid' }

$InstallRoot = Join-Path $env:LOCALAPPDATA 'TwoHeadWu\Air'
$ReleasesRoot = Join-Path $InstallRoot 'releases'
$InstallState = Join-Path $InstallRoot 'install.json'
$Existing = $null
if (Test-Path -LiteralPath $InstallState -PathType Leaf) {
    $Existing = Get-Content -LiteralPath $InstallState -Raw | ConvertFrom-Json
    if ((Normalize-Thumbprint ([string]$Existing.publisher_thumbprint)) -ne $Publisher) {
        throw 'member Air package does not match the installed publisher pin'
    }
    try { $ExistingVersion = [version]([string]$Existing.version) } catch { throw 'installed member Air version is invalid' }
    if ($CandidateVersion -lt $ExistingVersion) {
        throw 'member Air downgrade is not allowed'
    }
} elseif ($UpdateOnly) {
    throw 'member Air cannot update before initial installation'
}

$VersionRoot = Join-Path $ReleasesRoot ([string]$Release.version)
$StagingRoot = Join-Path $ReleasesRoot ('.staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
try {
    Copy-Item -Path (Join-Path $Payload '*') -Destination $StagingRoot -Recurse -Force
    $CopiedCatalogStatus = (Test-FileCatalog -Path $StagingRoot -CatalogFilePath $Catalog -Detailed).Status
    if ($CopiedCatalogStatus.ToString() -ne 'Valid') {
        throw 'copied member Air payload failed catalog verification'
    }
    if (Test-Path -LiteralPath $VersionRoot) {
        $ExistingCatalogStatus = (Test-FileCatalog -Path $VersionRoot -CatalogFilePath $Catalog -Detailed).Status
        if ($ExistingCatalogStatus.ToString() -ne 'Valid') {
            throw 'member Air refuses different payload bytes under an existing version'
        }
        Remove-Item -LiteralPath $StagingRoot -Recurse -Force
    } else {
        Move-Item -LiteralPath $StagingRoot -Destination $VersionRoot
    }
} finally {
    if (Test-Path -LiteralPath $StagingRoot) {
        Remove-Item -LiteralPath $StagingRoot -Recurse -Force
    }
}

$Client = Join-Path $VersionRoot 'two-head-wu-air.exe'
if (-not $UpdateOnly -and $null -eq $Existing) {
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        throw 'initial member Air installation requires -Endpoint'
    }
    if ($null -eq $PairingToken) {
        $PairingToken = Read-Host 'Two-Headed-Wu Air one-time pairing token' -AsSecureString
    }
    New-Item -ItemType Directory -Path $ReviewRoot -Force | Out-Null
    $Credential = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PairingToken)
    try {
        $env:TWO_HEAD_WU_MEMBER_PAIRING = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Credential)
        & $Client enroll --endpoint $Endpoint --token-env TWO_HEAD_WU_MEMBER_PAIRING --review-root $ReviewRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'member Air enrollment failed' }
    } finally {
        Remove-Item Env:TWO_HEAD_WU_MEMBER_PAIRING -ErrorAction SilentlyContinue
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Credential)
    }
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$StateTemporary = Join-Path $InstallRoot ('.install-' + [Guid]::NewGuid().ToString('N') + '.json')
[PSCustomObject]@{
    schema_version = 1
    version = [string]$Release.version
    publisher_thumbprint = $Publisher
    release_root = $VersionRoot
} | ConvertTo-Json | Set-Content -LiteralPath $StateTemporary -Encoding UTF8
Move-Item -LiteralPath $StateTemporary -Destination $InstallState -Force

$HealthScript = Join-Path $VersionRoot 'Invoke-MemberAirHealth.ps1'
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "{0}"' -f $HealthScript)
$Trigger = New-ScheduledTaskTrigger -Daily -At 12:00
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'TwoHeadWu Air Health' -Action $Action -Trigger $Trigger -Settings $Settings -Description 'Outbound-only hardware binding diagnosis; opens no listener.' -Force | Out-Null

[PSCustomObject]@{
    installed = $true
    version = [string]$Release.version
    publisher_thumbprint = $Publisher
    client = $Client
    review_root = $ReviewRoot
} | ConvertTo-Json -Compress
