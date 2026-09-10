#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [switch]$RemoveDeviceBinding,

    [Parameter()]
    [switch]$AdministratorRevoked
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'TwoHeadWu\Air'
$Configuration = Join-Path (Join-Path $env:LOCALAPPDATA 'TwoHeadWu') 'air.json'
$ApprovalKey = Join-Path (Join-Path $env:LOCALAPPDATA 'TwoHeadWu') 'approval-key.json'
$TaskName = 'TwoHeadWu Air Health'

if ($RemoveDeviceBinding -and -not $AdministratorRevoked) {
    throw 'remove-device-binding requires confirmation that the administrator revoked the active device first'
}

if ($RemoveDeviceBinding -and $PSCmdlet.ShouldProcess('the local TPM member key and binding', 'Remove')) {
    $KeyHelper = Join-Path $PSScriptRoot 'MemberKey.ps1'
    if (-not (Test-Path -LiteralPath $KeyHelper -PathType Leaf)) {
        throw 'member TPM key helper is unavailable; program files were not removed'
    }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File $KeyHelper delete | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'member TPM key removal failed; program files were not removed'
    }
    if (Test-Path -LiteralPath $Configuration -PathType Leaf) {
        Remove-Item -LiteralPath $Configuration -Force
    }
    if (Test-Path -LiteralPath $ApprovalKey -PathType Leaf) {
        Remove-Item -LiteralPath $ApprovalKey -Force
    }
}

if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

if ((Test-Path -LiteralPath $InstallRoot) -and $PSCmdlet.ShouldProcess($InstallRoot, 'Remove member Air program files')) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}

[PSCustomObject]@{
    removed_program = -not (Test-Path -LiteralPath $InstallRoot)
    retained_device_binding = -not $RemoveDeviceBinding
} | ConvertTo-Json -Compress
