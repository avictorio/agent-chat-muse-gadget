#!/bin/bash
# linux/check-hardening.sh -- step A2's Done when, run inside the distro after a restart
# (windows/in-distro.ps1 -Script check-hardening.sh -User ada-watch). Prints PASS/FAIL lines and RESULT.
pass=0; total=0
point() { total=$((total + 1)); if [ "$1" = 0 ]; then pass=$((pass + 1)); echo "PASS $2"; else echo "FAIL $2"; fi; }

[ "$(id -un)" = ada-watch ]; point $? "runs as ada-watch (got $(id -un))"
[ "$(ps -p 1 -o comm=)" = systemd ]; point $? "PID 1 is systemd (got $(ps -p 1 -o comm=))"
# WSL's own read-only GPU driver share (/usr/lib/wsl/drivers) is 9p too; any other 9p, drvfs or virtiofs is a drive.
! grep -E '\s(9p|drvfs|virtiofs)\s' /proc/mounts | grep -qv ' /usr/lib/wsl/drivers '
point $? "no Windows drive is mounted"
[ -z "$(ls -A /mnt | grep -vxE 'wsl|wslg')" ]; point $? "/mnt holds only wsl and wslg ($(ls -A /mnt | tr '\n' ' '))"
! command -v cmd.exe >/dev/null 2>&1 && ! command -v powershell.exe >/dev/null 2>&1
point $? "cmd.exe and powershell.exe aren't on PATH"
[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]; point $? "WSL's binfmt hook for Windows programs is gone"
! sudo -n true 2>/dev/null; point $? "ada-watch has no sudo"
id -nG ada-gadget | tr ' ' '\n' | grep -qxE 'sudo|admin|adm'; [ $? != 0 ]; point $? "ada-gadget is in no admin group"
id -nG ada-watch | tr ' ' '\n' | grep -qx ada-gadget; point $? "ada-watch is in group ada-gadget"
[ "$(stat -c %a /home/ada-watch)" = 700 ]; point $? "ada-watch's home is 0700"

echo "RESULT $([ $pass = $total ] && echo PASS || echo FAIL): $pass/$total"
[ $pass = $total ]
