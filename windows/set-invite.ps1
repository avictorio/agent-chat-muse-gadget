# windows/set-invite.ps1 -- step C1: the owner types the test room's agent invite token (hidden) for the watcher.
# Run by the OWNER in a PowerShell window in `operator`'s desktop session (unelevated; the muse-gadget runner must be up):
#   powershell -ExecutionPolicy Bypass -File C:\Users\operator\muse-gadget\windows\set-invite.ps1 -Origin https://<site> -Room <room>
# The token is handed over in one file in C:\ProgramData\muse-gadget\token-drop (only operator and muse-gadget can open it),
# deleted straight after; linux/set-invite.sh stores it. It is never on a command line, on screen or in a log.
param(
  [Parameter(Mandatory)][ValidatePattern('^https://[A-Za-z0-9.-]+$')][string]$Origin,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]{1,100}$')][string]$Room
)
$ErrorActionPreference = 'Stop'
$drop = 'C:\ProgramData\muse-gadget\token-drop'
$run = Join-Path $PSScriptRoot 'run-as-gadget.ps1'
if (-not (& $run -Test)) { throw "The muse-gadget runner isn't running." }
if (-not (Test-Path $drop)) { throw "$drop is missing: rerun windows/setup-account.ps1 (elevated)." }

Write-Host "Paste the agent invite for room $Room (hidden; right-click to paste), then Enter:" -ForegroundColor Yellow
$sec = Read-Host -AsSecureString 'Invite'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$job = Join-Path $drop "$([guid]::NewGuid().ToString('N')).sh"
try {
  $t = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
  if ($t -match '[?&]invite=([^&\s#]+)') { $t = $Matches[1] }   # a whole invite link: keep only the token
  if ($t -cnotmatch '^[A-Za-z0-9._~+=-]{8,512}$') { throw "That doesn't look like an invite token. Copy it again; nothing was saved." }
  $script = ([IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'linux\set-invite.sh')) -replace "`r`n", "`n").TrimEnd()
  [IO.File]::WriteAllText($job, $script + "`n__TOKEN__`n$t`n", (New-Object Text.ASCIIEncoding)); $t = $null
  $r = & $run -TimeoutSeconds 60 -Command "Get-Content '$job' -Raw | wsl.exe -d muse-gadget -u ada-watch -- bash -s"
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  Remove-Item $job -Force -ErrorAction SilentlyContinue
}
$r.Output | Where-Object { $_ -match '^(saved|REFUSED)' } | ForEach-Object { Write-Host "  $_" }
if ($r.ExitCode -ne 0) { Write-Host "RESULT FAIL (rc $($r.ExitCode))" -ForegroundColor Red; return }
& (Join-Path $PSScriptRoot 'in-distro.ps1') -Script check-invite.sh -User ada-watch -ScriptArgs $Origin, $Room | Out-Null
