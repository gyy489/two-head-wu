#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$MemberAirExe,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:\.\d+)?$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9 ]{40,128}$')]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidatePattern('^https://')]
    [string]$TimestampServer = 'https://timestamp.digicert.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Thumbprint([string]$Value) {
    return (($Value -replace '[^A-Fa-f0-9]', '').ToUpperInvariant())
}

function Assert-Signature([string]$Path, [string]$Publisher) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    $Actual = if ($null -eq $Signature.SignerCertificate) { '' } else {
        Normalize-Thumbprint $Signature.SignerCertificate.Thumbprint
    }
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $Actual -ne $Publisher) {
        throw "signed member Air file did not verify: $([IO.Path]::GetFileName($Path))"
    }
}

$Publisher = Normalize-Thumbprint $CertificateThumbprint
$Certificate = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My | Where-Object {
    (Normalize-Thumbprint $_.Thumbprint) -eq $Publisher
} | Select-Object -First 1
if ($null -eq $Certificate -or -not $Certificate.HasPrivateKey) {
    throw 'the selected Authenticode certificate with a private key is unavailable'
}
if ($Certificate.NotBefore -gt (Get-Date) -or $Certificate.NotAfter -le (Get-Date)) {
    throw 'the selected Authenticode certificate is outside its validity period'
}
if (-not ($Certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) {
    throw 'the selected certificate is not valid for code signing'
}

$SourceRoot = Split-Path -Parent $PSCommandPath
$ResolvedExe = (Resolve-Path -LiteralPath $MemberAirExe).Path
$OutputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$WorkRoot = Join-Path $env:TEMP ('two-head-wu-member-air-' + [Guid]::NewGuid().ToString('N'))
$PackageRoot = Join-Path $WorkRoot 'package'
$Payload = Join-Path $PackageRoot 'payload'
New-Item -ItemType Directory -Path $Payload -Force | Out-Null

try {
    Copy-Item -LiteralPath $ResolvedExe -Destination (Join-Path $Payload 'two-head-wu-air.exe')
    foreach ($Name in @('MemberKey.ps1', 'Invoke-MemberAirHealth.ps1', 'Test-MemberAirInstallation.ps1', 'Update-MemberAir.ps1', 'Uninstall-MemberAir.ps1')) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $Name) -Destination (Join-Path $Payload $Name)
    }
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'Install-MemberAir.ps1') -Destination (Join-Path $PackageRoot 'Install-MemberAir.ps1')
    [PSCustomObject]@{
        schema_version = 1
        version = $Version
        platform = 'windows'
        architecture = 'amd64'
        created_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Payload 'release.json') -Encoding UTF8

    foreach ($Path in @(
        (Join-Path $Payload 'two-head-wu-air.exe'),
        (Join-Path $Payload 'MemberKey.ps1'),
        (Join-Path $Payload 'Invoke-MemberAirHealth.ps1'),
        (Join-Path $Payload 'Test-MemberAirInstallation.ps1'),
        (Join-Path $Payload 'Update-MemberAir.ps1'),
        (Join-Path $Payload 'Uninstall-MemberAir.ps1')
    )) {
        $Result = Set-AuthenticodeSignature -LiteralPath $Path -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer -IncludeChain All
        if ($Result.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "could not sign member Air payload: $([IO.Path]::GetFileName($Path))"
        }
        Assert-Signature $Path $Publisher
    }

    $Catalog = Join-Path $PackageRoot 'Air.cat'
    New-FileCatalog -Path $Payload -CatalogFilePath $Catalog -CatalogVersion '2.0' | Out-Null
    foreach ($Path in @($Catalog, (Join-Path $PackageRoot 'Install-MemberAir.ps1'))) {
        $Result = Set-AuthenticodeSignature -LiteralPath $Path -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer -IncludeChain All
        if ($Result.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "could not sign member Air package: $([IO.Path]::GetFileName($Path))"
        }
        Assert-Signature $Path $Publisher
    }
    $CatalogStatus = (Test-FileCatalog -Path $Payload -CatalogFilePath $Catalog -Detailed).Status
    if ($CatalogStatus.ToString() -ne 'Valid') {
        throw 'member Air package catalog verification failed after signing'
    }

    $Archive = Join-Path $OutputRoot ("two-head-wu-air-windows-amd64-$Version.zip")
    if (Test-Path -LiteralPath $Archive) {
        throw 'member Air output archive already exists'
    }
    Compress-Archive -Path (Join-Path $PackageRoot '*') -DestinationPath $Archive -CompressionLevel Optimal
    [PSCustomObject]@{
        archive = $Archive
        sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
        publisher_thumbprint = $Publisher
        version = $Version
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $WorkRoot) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force
    }
}
