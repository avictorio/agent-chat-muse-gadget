# windows/setup-account.ps1 -- the muse-gadget Windows account and its runner (step A0).
# Run from `operator`, ELEVATED. Rerunnable; -Remove takes the tasks and the runner folder away (not the account or
# its distro: windows/remove.ps1 does that).
#   1. A local standard account `muse-gadget` (Users only, no interactive or RDP sign-in, hidden from the sign-in
#      screen), with a fresh random password on every run that only Task Scheduler keeps. It owns the WSL distro, so
#      a Linux process that re-enables interop or mounts C: reaches only what this account can (README, Security).
#   2. The runner: task `muse-gadget-runner`, at startup, as muse-gadget, polling C:\ProgramData\muse-gadget\runner\queue
#      (windows/run-as-gadget.ps1 queues a job and reads the result). Only operator, Administrators and SYSTEM can
#      change the loop; muse-gadget can write the queue (its job results). C:\ProgramData\muse-gadget\stage is where
#      operator puts the Linux scripts that windows/in-distro.ps1 pipes into the distro (muse-gadget reads only).
#   3. With -KeepAlive (once the distro exists): task `muse-gadget-keepalive`, at startup, as muse-gadget, holding
#      `wsl.exe -d muse-gadget --exec /bin/sleep infinity` so WSL doesn't stop the idle distro (step A8).
param([switch]$KeepAlive, [switch]$Remove, [string]$LogPath)
$ErrorActionPreference = 'Stop'
if ($LogPath) { Start-Transcript -Path $LogPath -Force | Out-Null }
$acct = 'muse-gadget'; $distro = 'muse-gadget'
$root = 'C:\ProgramData\muse-gadget'; $bin = "$root\bin"; $queue = "$root\runner\queue"; $stage = "$root\stage"
$runTask = 'muse-gadget-runner'; $keepTask = 'muse-gadget-keepalive'

function Get-RightLine([string]$right) {   # secedit exports resolvable accounts by name, others as *SID
  $inf = Join-Path $env:TEMP "secpol-$([guid]::NewGuid()).inf"
  secedit /export /cfg $inf /areas USER_RIGHTS | Out-Null
  $line = @(Get-Content $inf | Where-Object { $_ -match "^$right\s*=" }) | Select-Object -First 1
  Remove-Item $inf -Force -ErrorAction SilentlyContinue
  return [string]$line
}
function Test-Right([string]$right, [string]$sid) {
  $members = ((Get-RightLine $right) -replace '^[^=]*=', '') -split ',' | ForEach-Object { $_.Trim() }
  return [bool]($members -contains "*$sid" -or $members -contains $acct)
}
function Grant-Right([string]$right, [string]$sid) {
  if (Test-Right $right $sid) { return }
  $cur = Get-RightLine $right
  $newLine = if ($cur) { "$cur,*$sid" } else { "$right = *$sid" }
  $inf = Join-Path $env:TEMP "secpol-$([guid]::NewGuid()).inf"; $db = Join-Path $env:TEMP "secpol-$([guid]::NewGuid()).sdb"
  Set-Content -Path $inf -Value @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]', $newLine) -Encoding Unicode
  $ErrorActionPreference = 'Continue'
  secedit /configure /db $db /cfg $inf /areas USER_RIGHTS /quiet
  $rc = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  Remove-Item $inf, $db, "$db.jfm" -Force -ErrorAction SilentlyContinue
  if ($rc -ne 0 -or -not (Test-Right $right $sid)) { throw "Couldn't grant $right to $acct (secedit $rc)." }
  Write-Host "  granted $right"
}

try {
  if ($env:USERNAME -ne 'operator') { throw "Not running as 'operator' (got '$env:USERNAME')." }
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this elevated.' }

  foreach ($t in $runTask, $keepTask) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
      Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $t -Confirm:$false
      Write-Host "removed task $t"
    }
  }
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$bin\runner-loop.ps1*" } |
    ForEach-Object { $ErrorActionPreference = 'Continue'; taskkill /PID $_.ProcessId /T /F 2>&1 | Out-Null; $ErrorActionPreference = 'Stop' }
  if ($Remove) {
    if (Test-Path "$root\runner") { Remove-Item "$root\runner" -Recurse -Force }
    Write-Host 'RESULT PASS: tasks removed'; return
  }

  Write-Host "The $acct account"
  $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $plain = [Convert]::ToBase64String($bytes) + 'a1!'; $bytes = $null
  $secPw = ConvertTo-SecureString $plain -AsPlainText -Force
  if (-not (Get-LocalUser $acct -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $acct -Password $secPw -FullName 'Muse gadget host' -Description 'Owns the muse-gadget WSL distro' -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Write-Host '  created'
  } else { Set-LocalUser -Name $acct -Password $secPw }
  if (-not (Get-LocalGroupMember -SID 'S-1-5-32-545' | Where-Object Name -like "*\$acct")) { Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $acct }
  if (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object Name -like "*\$acct") { throw "$acct is in Administrators; it must be a standard account." }
  $sid = (Get-LocalUser $acct).SID.Value
  Grant-Right 'SeBatchLogonRight' $sid
  Grant-Right 'SeDenyInteractiveLogonRight' $sid
  Grant-Right 'SeDenyRemoteInteractiveLogonRight' $sid
  $ul = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
  New-Item $ul -Force | Out-Null; Set-ItemProperty $ul -Name $acct -Value 0 -Type DWord

  Write-Host 'The runner'
  New-Item -ItemType Directory -Force $bin, $queue, $stage | Out-Null
  $ErrorActionPreference = 'Continue'
  icacls $root /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' "operator:(OI)(CI)RX" "${acct}:(RX)" | Out-Null
  icacls $bin /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'operator:(OI)(CI)RX' "${acct}:(OI)(CI)RX" | Out-Null
  icacls "$root\runner" /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'operator:(OI)(CI)RX' "${acct}:(RX)" | Out-Null
  icacls $queue /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'operator:(OI)(CI)M' "${acct}:(OI)(CI)M" | Out-Null
  icacls $stage /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'operator:(OI)(CI)M' "${acct}:(OI)(CI)RX" | Out-Null
  $ErrorActionPreference = 'Stop'
  Copy-Item (Join-Path $PSScriptRoot 'runner-loop.ps1') $bin -Force
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $queue `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bin\runner-loop.ps1`" -Queue `"$queue`""
  Register-ScheduledTask -TaskName $runTask -Action $action -Trigger $trigger -Settings $settings -User "$env:COMPUTERNAME\$acct" -Password $plain -RunLevel Limited -Force | Out-Null
  Start-ScheduledTask -TaskName $runTask
  Write-Host "  registered and started $runTask"

  if ($KeepAlive) {
    $kAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wsl.exe" -Argument "-d $distro --exec /bin/sleep infinity"
    Register-ScheduledTask -TaskName $keepTask -Action $kAction -Trigger $trigger -Settings $settings -User "$env:COMPUTERNAME\$acct" -Password $plain -RunLevel Limited -Force | Out-Null
    Start-ScheduledTask -TaskName $keepTask
    Write-Host "  registered and started $keepTask"
  }
  $plain = $null; $secPw = $null

  $until = (Get-Date).AddSeconds(30)
  while (-not (& (Join-Path $PSScriptRoot 'run-as-gadget.ps1') -Test) -and (Get-Date) -lt $until) { Start-Sleep 1 }
  $r = & (Join-Path $PSScriptRoot 'run-as-gadget.ps1') -TimeoutSeconds 60 -Command @'
"user=$env:USERNAME elevated=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
'@
  Write-Host "runner: rc=$($r.ExitCode) $($r.Output -join ' ')"
  if ($r.ExitCode -eq 0 -and ($r.Output -join ' ') -match "user=$acct elevated=False") { Write-Host 'RESULT PASS' } else { Write-Host 'RESULT FAIL' }
} catch {
  Write-Host "ERROR: $($_.Exception.Message)"
} finally {
  if ($LogPath) { Stop-Transcript | Out-Null }
}
