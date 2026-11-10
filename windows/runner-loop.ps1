# windows/runner-loop.ps1 -- the muse-gadget runner's loop (windows/setup-account.ps1 installs it; copied from SHA's runner).
# Runs as muse-gadget and polls its queue folder. Each job is <id>_<seconds>.ps1, written by windows/run-as-gadget.ps1;
# the job writes <id>.out and <id>.rc itself. The loop runs jobs one at a time, kills a job at its timeout and writes
# rc 124, then deletes the script.
param([Parameter(Mandatory)][string]$Queue)
$ErrorActionPreference = 'Continue'
$beat = Join-Path $Queue 'heartbeat'
while ($true) {
  [IO.File]::WriteAllText($beat, (Get-Date).ToString('o'))
  $job = Get-ChildItem $Queue -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -First 1
  if (-not $job) { Start-Sleep -Milliseconds 700; continue }
  $id = $job.BaseName -replace '_\d+$', ''
  $sec = if ($job.BaseName -match '_(\d+)$') { [int]$Matches[1] } else { 300 }
  $pr = Start-Process powershell.exe -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($job.FullName)`"" `
    -WorkingDirectory $Queue -WindowStyle Hidden -PassThru
  $deadline = (Get-Date).AddSeconds($sec)
  while (-not $pr.HasExited -and (Get-Date) -lt $deadline) {
    [IO.File]::WriteAllText($beat, (Get-Date).ToString('o')); Start-Sleep -Milliseconds 500
  }
  if (-not $pr.HasExited) {
    taskkill /PID $pr.Id /T /F 2>&1 | Out-Null
    "TIMEOUT after ${sec}s" | Out-File -Append -Encoding utf8 (Join-Path $Queue "$id.out")
    '124' | Out-File -Encoding ascii (Join-Path $Queue "$id.rc")
  } elseif (-not (Test-Path (Join-Path $Queue "$id.rc"))) {
    "$($pr.ExitCode)" | Out-File -Encoding ascii (Join-Path $Queue "$id.rc")
  }
  Remove-Item $job.FullName -Force -ErrorAction SilentlyContinue
}
