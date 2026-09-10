#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Client = Join-Path $PSScriptRoot 'two-head-wu-air.exe'
if (-not (Test-Path -LiteralPath $Client -PathType Leaf)) {
    throw 'member Air client is unavailable'
}

& $Client diagnose | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'member Air device diagnosis failed'
}
