#!/bin/bash
# linux/fetch-sdk.sh -- step A3, part 1, as root: the Muse Gadget SDK at a pinned commit in /opt/muse-gadget-sdk.
#   windows/in-distro.ps1 -Script fetch-sdk.sh -ScriptArgs <commit>
# Read linux/install.sh there before installing (linux/install-sdk.sh).
set -euo pipefail
commit="${1:?commit}"
dir=/opt/muse-gadget-sdk
command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null; }
if [ ! -d "$dir/.git" ]; then git clone -q https://github.com/facebookincubator/muse-gadget-sdk.git "$dir"; fi
git -C "$dir" fetch -q origin
git -C "$dir" -c advice.detachedHead=false checkout -q "$commit"
echo "SDK at $(git -C "$dir" rev-parse HEAD) ($(git -C "$dir" log -1 --format=%cs))"
