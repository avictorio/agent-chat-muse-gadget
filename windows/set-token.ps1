# windows/set-token.ps1 -- step A4: the owner types the Muse SDK token (from gadgets.muse.ai) into the distro.
# Run by the OWNER in a PowerShell window in `operator`'s desktop session (unelevated; the muse-gadget runner must be up):
#   powershell -ExecutionPolicy Bypass -File C:\Users\operator\muse-gadget\windows\set-token.ps1
# The token is read with hidden input, checked against the installer's own pattern, and handed over in a file that only
# operator and muse-gadget can open; the runner pipes it into `install -m 0600 /dev/stdin /var/lib/musegadget/sdk_token`
# as root inside the distro and deletes the file. It is never on a command line, in a job file, on screen or in a log.
$ErrorActionPreference = 'Stop'
$drop = 'C:\ProgramData\muse-gadget\token-drop'
$run = Join-Path $PSScriptRoot 'run-as-gadget.ps1'
if (-not (& $run -Test)) { throw "The muse-gadget runner isn't running." }

Write-Host 'Paste the Muse SDK token (mgst_...; hidden; right-click to paste), then Enter:' -ForegroundColor Yellow
$sec = Read-Host -AsSecureString 'SDK token'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$file = $null
try {
  $t = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
  if ($t -cnotmatch '^mgst_[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$') { throw "That isn't an SDK token (it should start with mgst_); copy it again from gadgets.muse.ai." }
  if (-not (Test-Path $drop)) { New-Item -ItemType Directory $drop | Out-Null }
  $ErrorActionPreference = 'Continue'
  icacls $drop /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'operator:(OI)(CI)M' 'muse-gadget:(OI)(CI)M' | Out-Null
  $ErrorActionPreference = 'Stop'
  $file = Join-Path $drop "$([guid]::NewGuid().ToString('N')).tok"
  [IO.File]::WriteAllText($file, "$t`n", (New-Object Text.ASCIIEncoding)); $t = $null
} finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

try {
  $r = & $run -TimeoutSeconds 120 -Command @"
try {
  Get-Content '$file' -Raw | wsl.exe -d muse-gadget -u root -- sh -c 'install -d -m 0700 /var/lib/musegadget && tr -d "\r" | head -n 1 | install -m 0600 /dev/stdin /var/lib/musegadget/sdk_token && systemctl restart musegadget'
} finally { Remove-Item '$file' -Force -ErrorAction SilentlyContinue }
wsl.exe -d muse-gadget -u root -- musegadget info
"@
} finally { if ($file) { Remove-Item $file -Force -ErrorAction SilentlyContinue } }
$r.Output | Where-Object { $_ -match '^(node id|SDK token|paired):' } | ForEach-Object { Write-Host "  $_" }
if ($r.ExitCode -eq 0 -and @($r.Output -match '^SDK token:\s+(?!none)').Count) { Write-Host 'RESULT PASS: the token is saved' -ForegroundColor Green }
else { Write-Host "RESULT FAIL (rc $($r.ExitCode))" -ForegroundColor Red }
