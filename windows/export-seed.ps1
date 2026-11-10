# windows/export-seed.ps1 -- step A5, run by the OWNER in operator's session (unelevated): puts the gadget's identity
# and SDK token on a USB stick for the live-USB pairing (docs/pairing-runbook.md).
#   powershell -ExecutionPolicy Bypass -File C:\Users\operator\muse-gadget\windows\export-seed.ps1 -Drive E:
# Writes <Drive>\muse-gadget\seed.tar (identity.json, sdk_token). The files are never shown; the handover file in
# C:\ProgramData\muse-gadget\token-drop is deleted. windows/import-state.ps1 wipes the stick's copy afterwards.
param([Parameter(Mandatory)][ValidatePattern('^[D-Zd-z]:$')][string]$Drive)
$ErrorActionPreference = 'Stop'
$run = Join-Path $PSScriptRoot 'run-as-gadget.ps1'
$drop = 'C:\ProgramData\muse-gadget\token-drop'
$vol = Get-Volume -DriveLetter $Drive.Substring(0, 1) -ErrorAction Stop
if ($vol.DriveType -ne 'Removable') { throw "$Drive isn't a removable drive (it's $($vol.DriveType))." }
$outDir = "$Drive\muse-gadget"; $tar = "$outDir\seed.tar"
$b64 = Join-Path $drop "$([guid]::NewGuid().ToString('N')).b64"
try {
  $r = & $run -TimeoutSeconds 120 -Command @"
wsl.exe -d muse-gadget -u root -- sh -c 'tar -C /var/lib/musegadget -cf - identity.json sdk_token | base64 -w0' | Set-Content -Encoding ascii '$b64'
"@
  if ($r.ExitCode -ne 0 -or -not (Test-Path $b64)) { throw "Couldn't read the state from the distro (rc $($r.ExitCode))." }
  New-Item -ItemType Directory -Force $outDir | Out-Null
  [IO.File]::WriteAllBytes($tar, [Convert]::FromBase64String((Get-Content $b64 -Raw).Trim()))
} finally { Remove-Item $b64 -Force -ErrorAction SilentlyContinue }
Write-Host "RESULT PASS: $tar ($((Get-Item $tar).Length) bytes). Eject the stick safely before you restart." -ForegroundColor Green
