#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h:h:h}
mac_source="$project_root/capabilities/remote-work/native/macos/MemberKey.swift"
mac_builder="$project_root/capabilities/remote-work/native/macos/Build-AirPackage"
mac_readme="$project_root/capabilities/remote-work/native/macos/README.md"
windows_source="$project_root/capabilities/remote-work/native/windows/MemberKey.ps1"
windows_root="$project_root/capabilities/remote-work/native/windows"

[[ -f "$mac_source" && -x "$mac_builder" && -f "$mac_readme" && -f "$windows_source" ]]

rg -q 'kSecAttrTokenIDSecureEnclave' "$mac_source"
rg -q 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' "$mac_source"
rg -q 'SecKeyCopyExternalRepresentation\(key' "$mac_source"
rg -q 'refusing an exportable private key' "$mac_source"
zsh -n "$mac_builder"
rg -q 'codesign --verify --strict' "$mac_builder"
rg -q 'productbuild.*--sign' "$mac_builder"
rg -q 'notarytool submit' "$mac_builder"
rg -q 'spctl --assess --type install' "$mac_builder"
rg -q 'background_service: false' "$mac_builder"
rg -q 'installs no LaunchAgent, daemon, listener' "$mac_readme"
if rg -qi 'http://|launchctl|LaunchAgent|LaunchDaemon|TCPListener|HttpListener' "$mac_builder"; then
  print -u2 -- 'macOS Air package introduced insecure transport, a listener, or a background service'
  exit 1
fi
mac_plan=$("$mac_builder" plan --version 0.12.0 --architecture arm64)
print -r -- "$mac_plan" | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "macOS Air build plan drift" unless result["result"] == "planned" &&
    result["architecture"] == "arm64" && result["package"] == "signed-and-notarized-pkg" &&
    result["listener"] == false && result["background_service"] == false && result["signing_required"] == true
'

rg -q 'Microsoft Platform Crypto Provider' "$windows_source"
rg -q 'CngExportPolicies\]::None' "$windows_source"
rg -q 'CngAlgorithm\]::ECDsaP256' "$windows_source"
rg -q 'Convert-P1363ToDer' "$windows_source"
if rg -q 'EccPrivateBlob|Pkcs8PrivateBlob|GenericPrivateBlob' "$windows_source"; then
  print -u2 -- 'Windows member adapter contains a private-key export format'
  exit 1
fi

for name in Install-MemberAir.ps1 Update-MemberAir.ps1 Uninstall-MemberAir.ps1 Invoke-MemberAirHealth.ps1 Test-MemberAirInstallation.ps1 New-MemberAirPackage.ps1; do
  [[ -f "$windows_root/$name" ]]
done
rg -q 'Get-AuthenticodeSignature' "$windows_root/Install-MemberAir.ps1"
rg -q 'Test-FileCatalog' "$windows_root/Install-MemberAir.ps1"
rg -q 'publisher_thumbprint' "$windows_root/Install-MemberAir.ps1"
rg -q 'publisher pin' "$windows_root/Update-MemberAir.ps1"
rg -q 'New-ScheduledTaskTrigger -Daily' "$windows_root/Install-MemberAir.ps1"
rg -q "opens no listener" "$windows_root/Install-MemberAir.ps1"
rg -q 'AdministratorRevoked' "$windows_root/Uninstall-MemberAir.ps1"
rg -q 'Pkcs8PrivateBlob' "$windows_root/Test-MemberAirInstallation.ps1"
rg -q 'Get-ScheduledTask' "$windows_root/Test-MemberAirInstallation.ps1"
rg -q 'Set-AuthenticodeSignature' "$windows_root/New-MemberAirPackage.ps1"
rg -q 'New-FileCatalog' "$windows_root/New-MemberAirPackage.ps1"
if rg -qi 'http://|New-NetFirewallRule|TCPListener|HttpListener' \
  "$windows_root/MemberKey.ps1" \
  "$windows_root/Install-MemberAir.ps1" \
  "$windows_root/Update-MemberAir.ps1" \
  "$windows_root/Uninstall-MemberAir.ps1" \
  "$windows_root/Invoke-MemberAirHealth.ps1"; then
  print -u2 -- 'Windows member package introduced insecure transport or a listener'
  exit 1
fi

for source in "$mac_source" "$windows_source"; do
  rg -q 'TWO-HEAD-WU-MEMBER-V2' "$source"
  rg -q 'TWO-HEAD-WU-MEMBER-ENROLL-V2' "$source"
done

if [[ "$(uname -s)" == "Darwin" ]] && command -v swiftc >/dev/null 2>&1; then
  swiftc -typecheck "$mac_source"
fi

if command -v pwsh >/dev/null 2>&1; then
  for source in "$windows_root"/*.ps1; do
    pwsh -NoLogo -NoProfile -NonInteractive -Command \
      '$errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$null,[ref]$errors); if($errors.Count){$errors|ForEach-Object{[Console]::Error.WriteLine($_)};exit 1}' \
      "$source"
  done
fi

print -- 'native member key adapter tests ok'
