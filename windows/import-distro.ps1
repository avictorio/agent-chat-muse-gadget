# windows/import-distro.ps1 -- step A1: the muse-gadget WSL distro, owned by the muse-gadget account.
# Run from `operator`, ELEVATED (it writes C:\ProgramData\muse-gadget\image), with the runner up (setup-account.ps1).
#   1. Downloads Ubuntu 24.04's WSL root filesystem from cloud-images.ubuntu.com and checks it against SHA256SUMS.
#   2. As muse-gadget, `wsl --import muse-gadget C:\Users\muse-gadget\wsl\muse-gadget <image> --version 2`.
# Refuses if the distro already exists. Never touches other accounts' distros, and never runs `wsl --shutdown`.
param([string]$LogPath)
$ErrorActionPreference = 'Stop'
if ($LogPath) { Start-Transcript -Path $LogPath -Force | Out-Null }
$distro = 'muse-gadget'
$base = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
$name = 'ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
$imgDir = 'C:\ProgramData\muse-gadget\image'; $img = Join-Path $imgDir $name
$target = "C:\Users\$distro\wsl\$distro"
try {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this elevated.' }
  $run = Join-Path $PSScriptRoot 'run-as-gadget.ps1'

  $r = & $run -TimeoutSeconds 60 -Command 'wsl.exe -l -q'
  if (@($r.Output | Where-Object { $_.Trim() -eq $distro }).Count) { throw "The $distro distro already exists." }

  Write-Host "Image $name"
  $sums = [Text.Encoding]::ASCII.GetString((Invoke-WebRequest -UseBasicParsing "$base/SHA256SUMS").Content)
  $want = @($sums -split "`n" | Where-Object { $_ -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($name))$" } | ForEach-Object { $Matches[1] })[0]
  if (-not $want) { throw "$name isn't in SHA256SUMS." }
  New-Item -ItemType Directory -Force $imgDir | Out-Null
  $ErrorActionPreference = 'Continue'
  icacls $imgDir /grant "${distro}:(OI)(CI)RX" | Out-Null
  $ErrorActionPreference = 'Stop'
  if (-not (Test-Path $img) -or (Get-FileHash $img -Algorithm SHA256).Hash -ne $want.ToUpper()) {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing "$base/$name" -OutFile $img
  }
  $got = (Get-FileHash $img -Algorithm SHA256).Hash
  if ($got -ne $want.ToUpper()) { Remove-Item $img -Force; throw "Checksum mismatch: $got, expected $want." }
  Write-Host "  sha256 $got matches SHA256SUMS"

  Write-Host "Import as muse-gadget into $target"
  $r = & $run -TimeoutSeconds 600 -Command @"
New-Item -ItemType Directory -Force '$target' | Out-Null
wsl.exe --import $distro '$target' '$img' --version 2
"@
  $r.Output | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "  $_" }
  if ($r.ExitCode -ne 0) { throw "wsl --import failed (rc $($r.ExitCode))." }
  $r = & $run -TimeoutSeconds 120 -Command "wsl.exe -l -v; wsl.exe -d $distro --exec cat /etc/os-release"
  $r.Output | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "  $_" }
  if (@($r.Output | Where-Object { $_ -match "^\*?\s*$distro\s+\S+\s+2\s*$" }).Count -and @($r.Output -match 'VERSION_ID="24.04"').Count) {
    Write-Host 'RESULT PASS'
  } else { Write-Host 'RESULT FAIL' }
} catch {
  Write-Host "ERROR: $($_.Exception.Message)"
} finally {
  if ($LogPath) { Stop-Transcript | Out-Null }
}
