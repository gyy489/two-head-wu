#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('create', 'public', 'sign', 'delete')]
    [string]$Command,

    [Parameter()]
    [string]$InputBase64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Retained across the public Air naming migration so an enrolled machine keeps
# the exact TPM identity already registered by Mini.
$KeyName = 'TwoHeadWu.MemberAir.v2'
$Provider = [System.Security.Cryptography.CngProvider]::new('Microsoft Platform Crypto Provider')
$OpenOptions = [System.Security.Cryptography.CngKeyOpenOptions]::UserKey
$SpkiPrefix = [byte[]](0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00)

function Write-Result([hashtable]$Value) {
    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Compress))
}

function Open-MemberKey {
    if (-not [System.Security.Cryptography.CngKey]::Exists($KeyName, $Provider, $OpenOptions)) {
        throw 'member TPM key is unavailable'
    }
    $Key = [System.Security.Cryptography.CngKey]::Open($KeyName, $Provider, $OpenOptions)
    if ($Key.Provider.Provider -ne $Provider.Provider -or $Key.Algorithm.Algorithm -ne 'ECDSA_P256') {
        $Key.Dispose()
        throw 'member key provider or algorithm is invalid'
    }
    return $Key
}

function New-MemberKey {
    if ([System.Security.Cryptography.CngKey]::Exists($KeyName, $Provider, $OpenOptions)) {
        return Open-MemberKey
    }
    $Parameters = [System.Security.Cryptography.CngKeyCreationParameters]::new()
    $Parameters.Provider = $Provider
    $Parameters.KeyUsage = [System.Security.Cryptography.CngKeyUsages]::Signing
    $Parameters.ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::None
    $Parameters.KeyCreationOptions = [System.Security.Cryptography.CngKeyCreationOptions]::None
    return [System.Security.Cryptography.CngKey]::Create(
        [System.Security.Cryptography.CngAlgorithm]::ECDsaP256,
        $KeyName,
        $Parameters
    )
}

function Get-PublicKeySpkiBase64([System.Security.Cryptography.CngKey]$Key) {
    $Blob = $Key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
    if ($Blob.Length -ne 72 -or [BitConverter]::ToUInt32($Blob, 0) -ne 0x31534345 -or [BitConverter]::ToUInt32($Blob, 4) -ne 32) {
        throw 'member public key is not P-256'
    }
    $Spki = [byte[]]::new(91)
    [Array]::Copy($SpkiPrefix, 0, $Spki, 0, $SpkiPrefix.Length)
    $Spki[$SpkiPrefix.Length] = 0x04
    [Array]::Copy($Blob, 8, $Spki, $SpkiPrefix.Length + 1, 64)
    return [Convert]::ToBase64String($Spki)
}

function Convert-P1363ToDer([byte[]]$Signature) {
    if ($Signature.Length -ne 64) { throw 'member signature is not P-256 P1363' }
    $Parts = @()
    foreach ($Offset in @(0, 32)) {
        $Part = [byte[]]$Signature[$Offset..($Offset + 31)]
        $First = 0
        while ($First -lt 31 -and $Part[$First] -eq 0) { $First++ }
        $Value = [byte[]]$Part[$First..31]
        if (($Value[0] -band 0x80) -ne 0) { $Value = [byte[]](0) + $Value }
        $Parts += ,([byte[]](0x02, [byte]$Value.Length) + $Value)
    }
    $Length = $Parts[0].Length + $Parts[1].Length
    return [byte[]](0x30, [byte]$Length) + $Parts[0] + $Parts[1]
}

function Get-SigningInput([string]$Encoded) {
    if ([string]::IsNullOrWhiteSpace($Encoded)) { throw 'sign requires -InputBase64' }
    try { $Data = [Convert]::FromBase64String($Encoded) } catch { throw 'signing input is not Base64' }
    if ($Data.Length -gt 65536) { throw 'signing input is too large' }
    $Text = [Text.Encoding]::UTF8.GetString($Data)
    if (-not ($Text.StartsWith("TWO-HEAD-WU-MEMBER-V2`n") -or $Text.StartsWith("TWO-HEAD-WU-MEMBER-ENROLL-V2`n"))) {
        throw 'signing input is not a member protocol message'
    }
    return $Data
}

try {
    switch ($Command) {
        'create' {
            $Key = New-MemberKey
            try { Write-Result @{ provider = 'tpm-cng'; public_key_spki_base64 = Get-PublicKeySpkiBase64 $Key } }
            finally { $Key.Dispose() }
        }
        'public' {
            $Key = Open-MemberKey
            try { Write-Result @{ provider = 'tpm-cng'; public_key_spki_base64 = Get-PublicKeySpkiBase64 $Key } }
            finally { $Key.Dispose() }
        }
        'sign' {
            $Input = Get-SigningInput $InputBase64
            $Key = Open-MemberKey
            try {
                $Signer = [System.Security.Cryptography.ECDsaCng]::new($Key)
                try {
                    $Raw = $Signer.SignData($Input, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
                    $Der = Convert-P1363ToDer $Raw
                    Write-Result @{ algorithm = 'ecdsa-p256-sha256-der'; signature_base64 = [Convert]::ToBase64String($Der) }
                }
                finally { $Signer.Dispose() }
            }
            finally { $Key.Dispose() }
        }
        'delete' {
            if ([System.Security.Cryptography.CngKey]::Exists($KeyName, $Provider, $OpenOptions)) {
                $Key = Open-MemberKey
                try { $Key.Delete() } finally { $Key.Dispose() }
            }
            Write-Result @{ deleted = $true }
        }
    }
}
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 2
}
