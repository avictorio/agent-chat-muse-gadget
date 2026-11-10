# windows/run-as-gadget.ps1 -- run a PowerShell command as muse-gadget through its runner (windows/setup-account.ps1),
# from `operator`, unelevated, with no prompt:
#   $r = & windows\run-as-gadget.ps1 -Command 'wsl.exe -l -v'
#   $r.ExitCode; $r.Output; $r.TimedOut
# -Test tells a caller whether the runner is up. The runner does one job at a time.
# Never pass a secret in -Command: the job file sits in the queue until it has run.
param([string]$Command, [int]$TimeoutSeconds = 300, [switch]$Test)
$ErrorActionPreference = 'Stop'
$q = 'C:\ProgramData\muse-gadget\runner\queue'
$beat = Join-Path $q 'heartbeat'
# The runner rewrites the heartbeat every few seconds: a read in the middle of that finds it empty or locked.
$up = $false
for ($i = 0; $i -lt 5 -and -not $up; $i++) {
  try { $up = ((Get-Date) - [datetime](Get-Content $beat -Raw -ErrorAction Stop).Trim()).TotalSeconds -lt 15 } catch { Start-Sleep -Milliseconds 200 }
}
if ($Test) { return $up }
if (-not $up) { throw "The muse-gadget runner isn't running (no fresh $beat). Install it: windows/setup-account.ps1 (elevated)." }
if (-not $Command) { throw '-Command is required.' }

$id = [guid]::NewGuid().ToString('N')
$out = Join-Path $q "$id.out"; $rc = Join-Path $q "$id.rc"
$job = @"
`$ErrorActionPreference = 'Continue'
try {
  & { $Command } *>&1 | ForEach-Object { "`$_" -replace "`0", '' } | Out-File -Encoding utf8 '$out'
  `$c = if (`$LASTEXITCODE -ne `$null) { `$LASTEXITCODE } elseif (`$?) { 0 } else { 1 }
} catch { "`$_" | Out-File -Append -Encoding utf8 '$out'; `$c = 1 }
"`$c" | Out-File -Encoding ascii '$rc'
"@
$errs = $null
[void][Management.Automation.Language.Parser]::ParseInput($job, [ref]$null, [ref]$errs)
if ($errs) { throw ("the command doesn't parse: " + (($errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')) }
# Write under a temp name, then rename, so the loop never picks up a half-written job.
$tmp = Join-Path $q "$id.tmp"
Set-Content -Path $tmp -Value $job -Encoding UTF8
Rename-Item $tmp "${id}_$TimeoutSeconds.ps1"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds + 30)
while (-not (Test-Path $rc) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
Start-Sleep -Milliseconds 200
$done = Test-Path $rc
[pscustomobject]@{
  ExitCode = if ($done) { [int](Get-Content $rc | Select-Object -First 1) } else { $null }
  # A Muse SDK token never reaches the caller.
  Output   = if (Test-Path $out) { @(Get-Content $out -Encoding UTF8 | ForEach-Object { $_ -creplace 'mgst_[A-Za-z0-9_-]{20,}', '<redacted>' }) } else { @() }
  TimedOut = -not $done -or ((Test-Path $rc) -and (Get-Content $rc -Raw).Trim() -eq '124')
}
Remove-Item $out, $rc -Force -ErrorAction SilentlyContinue
