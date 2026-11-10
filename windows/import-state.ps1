# windows/import-state.ps1 -- step A7, run by the OWNER in operator's session (unelevated), back in Windows after the
# live-USB pairing: moves identity.json, pairing.json and sdk_token from the stick into the distro, then wipes the stick.
#   powershell -ExecutionPolicy Bypass -File C:\Users\operator\muse-gadget\windows\import-state.ps1 -Drive E:
# linux/import-state.sh does the inside half (it refuses another device's state); files land 0600 root:root in
# /var/lib/musegadget and the service restarts. The stick's files are overwritten with zeros, then deleted.
# The state travels as script + base64 in one file in C:\ProgramData\muse-gadget\token-drop, deleted straight after.
param([Parameter(Mandatory)][ValidatePattern('^[D-Zd-z]:$')][string]$Drive)
$ErrorActionPreference = 'Stop'
$run = Join-Path $PSScriptRoot 'run-as-gadget.ps1'
$drop = 'C:\ProgramData\muse-gadget\token-drop'
$dir = "$Drive\muse-gadget"; $tar = "$dir\paired.tar"
if (-not (Test-Path $tar)) { throw "No $tar on the stick." }
$job = Join-Path $drop "$([guid]::NewGuid().ToString('N')).sh"
try {
  $script = ([IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'linux\import-state.sh')) -replace "`r`n", "`n").TrimEnd()
  $body = $script + "`n__STATE__`n" + [Convert]::ToBase64String([IO.File]::ReadAllBytes($tar)) + "`n"
  [IO.File]::WriteAllText($job, $body, (New-Object Text.ASCIIEncoding))
  $r = & $run -TimeoutSeconds 180 -Command "Get-Content '$job' -Raw | wsl.exe -d muse-gadget -u root -- bash -s"
} finally { Remove-Item $job -Force -ErrorAction SilentlyContinue }
$r.Output | Where-Object { $_ -match '^(REFUSED|imported)' } | ForEach-Object { Write-Host "  $_" }
if ($r.ExitCode -ne 0) { Write-Host "RESULT FAIL (rc $($r.ExitCode)); the stick was left as it is." -ForegroundColor Red; return }

foreach ($f in Get-ChildItem $dir -File) {
  $len = $f.Length; $s = [IO.File]::OpenWrite($f.FullName)
  try { $s.Write((New-Object byte[] $len), 0, $len); $s.Flush() } finally { $s.Close() }
  Remove-Item $f.FullName -Force
}
Remove-Item $dir -Force -Recurse
Write-Host '  the stick is wiped; waiting 20 s for the service to register'
Start-Sleep 20
& (Join-Path $PSScriptRoot 'in-distro.ps1') -Script check-registered.sh | Out-Null
