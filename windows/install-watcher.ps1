# windows/install-watcher.ps1 -- step C2: installs linux/watcher.py in the distro and primes its cursors. Doesn't start it.
#   & windows\install-watcher.ps1 -Origin https://<site> -Room <room> [-Chat <side-chat-id>]
# Run from `operator`, unelevated. The origin, room and chat id are parameters so they stay out of the repo.
param(
  [Parameter(Mandatory)][ValidatePattern('^https://[A-Za-z0-9.-]+$')][string]$Origin,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]{1,100}$')][string]$Room,
  [ValidatePattern('^[A-Za-z0-9-]{1,64}$')][string]$Chat = ''   # none: wakes go to the main chat
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$job = Join-Path 'C:\ProgramData\muse-gadget\stage' 'install-watcher.job'
$script = ([IO.File]::ReadAllText((Join-Path $root 'linux\install-watcher.sh')) -replace "`r`n", "`n").TrimEnd()
$py = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'linux\watcher.py')))
[IO.File]::WriteAllText($job, $script + "`n__FILE__`n" + $py + "`n", (New-Object Text.ASCIIEncoding))
try {
  $r = & (Join-Path $PSScriptRoot 'run-as-gadget.ps1') -TimeoutSeconds 120 -Command "Get-Content '$job' -Raw | wsl.exe -d muse-gadget -u root -- bash -s -- '$Origin' '$Room' '$Chat'"
} finally { Remove-Item $job -Force -ErrorAction SilentlyContinue }
$r.Output | ForEach-Object { Write-Host $_ }
if ($r.ExitCode -eq 0) { Write-Host 'RESULT PASS: installed and primed' -ForegroundColor Green }
else { Write-Host "RESULT FAIL (rc $($r.ExitCode))" -ForegroundColor Red }
