# agent-chat-muse-gadget

A fast wake path for the owner's Muse agent: a Muse Gadget SDK host on the Legion that watches an Agent Chat room and
posts a pointer-only wake message into a Muse side chat. Phase 1 research memo: kept by the owner (Nov 10, 2026). The
agent's own hook stays the guarantee; this path is best-effort (dark while the laptop sleeps).

## Layout

- `windows/`: run from the Legion's `operator` account.
  - `setup-account.ps1` (elevated): the `muse-gadget` Windows account, its runner, and with `-KeepAlive` the
    keep-alive task.
  - `import-distro.ps1` (elevated): the `muse-gadget` WSL distro from Ubuntu 24.04's checksummed WSL image.
  - `run-as-gadget.ps1`: run a command as `muse-gadget` through its runner.
  - `in-distro.ps1`: pipe one of `linux/*.sh` into the distro as a chosen Linux user.
  - `set-token.ps1`: the owner types the SDK token (hidden input).
  - `export-seed.ps1`, `import-state.ps1`: the owner moves the state over a USB stick for pairing (A5, A7).
  - `set-invite.ps1`: the owner types the test room's invite (hidden input; C1).
  - `install-watcher.ps1`: installs the watcher and primes its cursors, without starting it (C2).
- `linux/`: run inside the distro through `windows/in-distro.ps1`.
  - `harden.sh`, `check-hardening.sh`: `wsl.conf`, the accounts, and the check.
  - `fetch-sdk.sh`, `install-sdk.sh`: the SDK at a pinned commit, installed with `--run-as ada-gadget --no-pair`.
  - `import-state.sh`, `check-registered.sh`: A7's inside half and its check.
  - `side-chat-send.sh`: B2's timed test messages, as `ada-watch`.
  - `set-invite.sh`, `check-invite.sh`: C1's inside half and its check.
  - `watcher.py`, `install-watcher.sh`, `watcher-control.sh`: the watcher, its install, and on/off.
  - `watcher-selftest.sh`, `watch-diag.sh`, `room-shape.sh`: the watcher's self-test, a journal summary, and the room
    API's payload shapes. `games-probe.sh`: the games list, one line per game, with the fields the wake signature reads.
- `docs/pairing-runbook.md`: A5-A7, step by step, for the owner.

## Steps

| Step | Status | Done when (observed) |
| --- | --- | --- |
| A0 `muse-gadget` account + runner | done 2026-11-10 | runner reports `user=muse-gadget elevated=False` |
| A1 distro `muse-gadget` | done 2026-11-10 | sha256 matches SHA256SUMS; `wsl -l -v` lists it, version 2, Ubuntu 24.04 |
| A2 hardening | done 2026-11-10 | `check-hardening.sh` RESULT PASS 10/10 after `wsl --terminate` |
| A3 SDK at `55cbf48`, no pairing | done 2026-11-10 | `musegadget info`: node id, `paired: no`; service active |
| A4 SDK token (owner) | done 2026-11-10 | `set-token.ps1` RESULT PASS |
| A5-A7 pair from a live USB, copy state back (owner; docs/pairing-runbook.md) | done 2026-11-10 | `check-registered.sh` RESULT PASS 4/4 |
| A8 keep-alive | done 2026-11-10 (came up by itself after a reboot) | after 5 min with nothing else attached: distro up since the task started, `sleep infinity` as ada-watch, service active |
| B1 side chat agreed (owner) | done 2026-11-10 | an id is agreed, kept out of this repo; the main chat is never used for tests |
| B2 five timed messages from `ada-watch` | done 2026-11-10 | the agent quoted all five exactly and gave a turn-start time for each |
| B3 latency and labelling | done 2026-11-10, except whether tool activity shows live (watch in C3) | send-to-ack median 372 ms, max 725 ms. Turn-start tags have 1 s precision and read 0.6-1.4 s before `t0` (separate clocks), so send-to-turn is about a second or less, not measured more finely. Labelling: the owner can't tell a wake from their own typing in the app; the agent reports it can at turn start, from the envelope's device id, but not when re-reading the stored transcript (the agent's report, not observed directly) |
| C1 test room and invite (owner) | done 2026-11-10 | `check-invite.sh` RESULT PASS: the room's API names the invite's member; the token is 0600 under `ada-watch`, unreadable by `ada-gadget` |
| C2 watcher installed, cursors primed | done 2026-11-10 | `watcher.py --prime` wrote the cursors |
| C3 end-to-end latency | done 2026-11-10 | 11 timed wakes, no loss or duplicate, at a 2 s grace: room post to the agent's first command median 2.7 s, max 9.4 s (first wake; 3.6 s for the rest); send-to-ack median 233 ms. Tool activity shows live in the side chat (owner). Spaced 30 s apart: bursts and a busy main chat not tested |
| C4 kill and replay | done 2026-11-10 | SIGKILL: systemd restarted it and it resumed at the delivered cursor. A message posted while it was stopped arrived exactly once after the restart |
| C5 window closed | done 2026-11-10 | the service was stopped; grace is now 0.5 s (about 0.6 s from stream open to send on the replayed wake) |
| Always on | on since 2026-11-10, one room, wakes to the main chat (owner); start at boot not yet seen. Since 2026-11-11 a wake carries the full items, fenced, without room_state (owner) | `watcher-control.sh on`: active and enabled. `off` keeps it off across reboots, for a manual switch to the agent's hook |

## Security

The memo assumed the distro would run under the owner's Windows account. It runs under a dedicated standard account
instead (`muse-gadget`: Users only, no interactive or RDP sign-in, hidden from the sign-in screen, a random password only
Task Scheduler holds), so even Linux root reaches only what that account can. Checked on 2026-11-10:

- **Interop.** With `[interop] enabled=false`, WSL still registers its binfmt hook, but a Windows program fails to start
  (`UtilAcceptVsock: accept4 failed 110`), tested by root mounting C: and running `whoami.exe` as `ada-watch`.
  `wsl-interop-off.service` also unregisters the hook at boot.
- **Drives.** Automount is off, but root can still `mount -t drvfs C:`. As `muse-gadget` that reaches no SHA data:
  `C:\agent`, the other accounts' profiles, `C:\ProgramData\hermes-panel` and `hermes-status` are all denied.
- **VM and network.** The distro runs in its own WSL VM (a different boot id from the `hermes` account's Docker
  Desktop VM), in NAT mode. From inside it, of the laptop's listening TCP ports below 49152 only 3389 (RDP) and 7680
  (Delivery Optimization) answer on the host address; none of the `127.0.0.1`/`127.0.0.2` services do (Ollama, Chrome's
  DevTools, the gateways, Hindsight, the panel). The internet and the home network are reachable.
- **Linux accounts.** No admin account: maintenance is `wsl -d muse-gadget -u root`, which only the `muse-gadget`
  Windows account can start (operator drives it through the runner). `ada-gadget` and `ada-watch` have no password and
  no sudo; `ada-watch`'s home is 0700.
- **Residual risk** (memo section 4): anything that can steer the Muse agent can run commands as `ada-gadget`, reach the
  internet and home network, and post device-attributed messages through the musegadget socket.
- `install.sh` fetches uv 0.9.9 from astral.sh without a hash check; everything else is pinned (`55cbf48`) or
  hash-locked.

## Never commit

Tokens (`mgst_...`, Agent Chat invites), `identity.json`, `pairing.json`, logs, or the room's name.
