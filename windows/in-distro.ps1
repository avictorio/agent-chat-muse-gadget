# windows/in-distro.ps1 -- run one of linux/*.sh inside the muse-gadget distro, from `operator`, unelevated.
#   & windows\in-distro.ps1 -Script harden.sh [-User root] [-ScriptArgs 'a','b'] [-TimeoutSeconds 600]
# Copies the script to C:\ProgramData\muse-gadget\stage (muse-gadget reads it there), then has the muse-gadget runner pipe
# it into `wsl.exe -d muse-gadget -u <user> -- bash -s`, so it works with automount off. Prints the output, returns rc.
# Never give it a secret: arguments land in the runner's job file.
param([Parameter(Mandatory)][string]$Script, [string]$User = 'root', [string[]]$ScriptArgs = @(), [int]$TimeoutSeconds = 600)
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path $PSScriptRoot) "linux\$Script"
if (-not (Test-Path $src)) { throw "No such script: $src" }
if ($User -notmatch '^[a-z][a-z0-9-]*$') { throw "Bad user name: $User" }
foreach ($a in $ScriptArgs) { if ($a -notmatch '^[A-Za-z0-9._:/=@+-]*$') { throw "Unsafe argument: $a" } }
$stage = 'C:\ProgramData\muse-gadget\stage'
$dst = Join-Path $stage $Script
# LF only: bash reads the script from stdin. PowerShell ends piped input with CRLF, so the script exits before that.
$body = ((Get-Content $src -Raw) -replace "`r`n", "`n").TrimEnd() + "`nexit `$?`n"
[IO.File]::WriteAllText($dst, $body, (New-Object Text.UTF8Encoding($false)))
$argText = ($ScriptArgs | ForEach-Object { "'$_'" }) -join ' '
$r = & (Join-Path $PSScriptRoot 'run-as-gadget.ps1') -TimeoutSeconds $TimeoutSeconds -Command @"
Get-Content '$dst' -Raw | wsl.exe -d muse-gadget -u $User -- bash -s -- $argText
"@
$r.Output | ForEach-Object { Write-Host $_ }
if ($r.TimedOut) { Write-Host "TIMED OUT after ${TimeoutSeconds}s" }
return $r.ExitCode
