#!/usr/bin/env python3
"""The Agent Chat watcher. Runs as ada-watch; linux/watcher-control.sh turns it on and off.

Holds one room stream open and posts a pointer-only wake into a Muse side chat through `musegadget send-user-msg`. A wake
says which room, which ids, from whom and how many; it never carries message text, because a gadget message arrives
user-role. Member names are filtered to a safe alphabet for the same reason.

Two cursors: `seen` (the stream's position) and `delivered` (the last message a send confirmed). A restart resumes from
`delivered`, so a message that arrived but wasn't handed off is replayed. The SDK never queues, so this retries failed
sends, folding newer messages into the same wake. It logs ids, names and times, never text, and never posts to the room.

  watcher.py          run
  watcher.py --prime  write the cursors at the room's current position, if there are none, and exit
"""
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

DIR = "/home/ada-watch/.agent-chat"
CONFIG, HEADER, STATE = f"{DIR}/watcher.json", f"{DIR}/invite.header", f"{DIR}/state.json"
GRACE = 0.5          # after the first new message, so a burst becomes one wake
READ_TIMEOUT = 45    # the server pings every 15 s, so this means a dead stream
CHECK_OPEN, CHECK_DOWN = 30, 5   # REST check interval with the stream up, and the fallback with it down
RETRY_FIRST, RETRY_MAX = 5, 60
SAFE_NAME = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
USER_AGENT = "agent-chat-muse-gadget/1"

lock = threading.Lock()
check_now = threading.Event()
state, pending, pending_await = {}, [], []
first_at = None
stream_open = False


def log(**fields):
    print(json.dumps({"t_ms": int(time.time() * 1000), **fields}), flush=True)


def save():
    tmp = STATE + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def signatures(room_state):
    out = []
    for t in (room_state or {}).get("awaiting_you") or []:
        if isinstance(t, dict):
            out.append("%s:%s:%s" % (t.get("type"), t.get("id"), t.get("turn", t.get("tick", t.get("round")))))
    return sorted(out)


def note_awaiting(room_state):
    """Under lock: anything newly awaiting this member joins the next wake. Game frames are live-only; this is their net."""
    global first_at
    sig = signatures(room_state)
    new = [s for s in sig if s not in state.get("awaiting", [])]
    state["awaiting"] = sig
    if new:
        pending_await.extend(new)
        first_at = first_at or time.monotonic()


def on_message(d):
    """Under lock: the cursor moves past it; another member's message joins the next wake."""
    global first_at
    try:
        mid = int(d.get("id") or 0)
    except (TypeError, ValueError):
        return
    if mid <= state["seen"]:
        return
    state["seen"] = mid
    sender = str(d.get("from") or "")
    if sender != state.get("self"):
        pending.append({"id": mid, "from": sender, "ts": d.get("ts") or d.get("created_at") or d.get("at")})
        first_at = first_at or time.monotonic()
    elif not pending:
        state["delivered"] = mid   # only this member's own messages since the last delivery
    if isinstance(d.get("room_state"), dict):
        note_awaiting(d["room_state"])


class Room:
    def __init__(self, cfg):
        self.base = f"{cfg['origin']}/api/rooms/{cfg['room']}"
        with open(HEADER, encoding="ascii") as f:
            self.token = f.read().split(":", 1)[1].strip()

    def open(self, path, timeout):
        req = urllib.request.Request(f"{self.base}/{path}", headers={
            "X-Invite-Token": self.token, "User-Agent": USER_AGENT, "Accept": "application/json, text/event-stream"})
        return urllib.request.urlopen(req, timeout=timeout)  # nosec B310: https, from the root-owned install's config

    def get(self, path):
        with self.open(path, 30) as r:
            return json.loads(r.read().decode("utf-8"))


def prime(room):
    if os.path.exists(STATE):
        with open(STATE, encoding="utf-8") as f:
            state.update(json.load(f))
        state["seen"] = state["delivered"]   # replay anything that arrived but wasn't delivered
        log(event="resumed", delivered=state["delivered"], member=state.get("self"))
        return
    r = room.get("messages?limit=1")
    last = int(r.get("last_id") or 0)
    state.update({"self": r.get("you") or "", "seen": last, "delivered": last, "awaiting": signatures(r.get("room_state"))})
    save()
    log(event="primed", delivered=last, member=state["self"])


def wake_text(cfg, batch, awaiting):
    names, senders = [], [m["from"] for m in batch]
    for s in senders:
        s = s if SAFE_NAME.match(s) else "unknown"
        if s not in names:
            names.append(s)
    top = max([m["id"] for m in batch], default=state["seen"])
    return (f"[Agent Chat wake via Legion gadget] room={cfg['room']} new={len(batch)} from={','.join(names[:10]) or 'none'} "
            f"max_id={top} awaiting_you={len(awaiting) or 'none'}\n"
            "Read the room yourself before acting; this message carries no room text.")


def send(cfg, text):
    """(confirmed, what the CLI said). A timeout or a dropped session may still have reached the Muse: it retries, and
    max_id makes a repeat recognisable."""
    try:
        p = subprocess.run(["musegadget", "send-user-msg", "--session-id", cfg["chat"], text], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=45, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, type(e).__name__
    out = (p.stdout + p.stderr).strip()[:200]
    return p.returncode == 0 and "Sent to your Muse" in out, out


def sender(cfg):
    global first_at
    next_try, backoff = 0.0, RETRY_FIRST
    while True:
        time.sleep(0.1)
        now = time.monotonic()
        with lock:
            if not first_at or now < next_try or now - first_at < GRACE:
                continue
            batch, awaiting = list(pending), list(pending_await)
            text = wake_text(cfg, batch, awaiting)
        t0 = time.time()
        ok, said = send(cfg, text)
        ack_ms = int((time.time() - t0) * 1000)
        if not ok:
            log(event="not-delivered", ids=[m["id"] for m in batch], said=said, retry_s=backoff)
            next_try, backoff = time.monotonic() + backoff, min(backoff * 2, RETRY_MAX)
            continue
        with lock:
            del pending[:len(batch)]
            del pending_await[:len(awaiting)]
            if batch:
                state["delivered"] = max(state["delivered"], batch[-1]["id"])
            save()
            first_at = time.monotonic() if pending or pending_await else None
        next_try, backoff = 0.0, RETRY_FIRST
        log(event="wake", ids=[m["id"] for m in batch], server_ts=[m["ts"] for m in batch], awaiting=len(awaiting),
            t_send_ms=int(t0 * 1000), ack_ms=ack_ms)


def checker(room):
    """A cheap REST read: awaiting_you, plus any message the stream missed. With the stream down it is the fallback."""
    while True:
        check_now.wait(CHECK_OPEN if stream_open else CHECK_DOWN)
        check_now.clear()
        try:
            r = room.get(f"messages?after={state['seen']}&wait=0")
            with lock:
                for d in sorted(r.get("messages") or [], key=lambda x: int(x.get("id") or 0)):
                    on_message(dict(d))
                if isinstance(r.get("room_state"), dict):
                    note_awaiting(r["room_state"])
                save()
        except (OSError, ValueError) as e:
            log(event="check-failed", error=type(e).__name__)


def stream(room):
    global stream_open
    with room.open(f"stream?after={state['seen']}&events=all", READ_TIMEOUT) as r:
        stream_open = True
        log(event="stream-open", after=state["seen"])
        kind, data = "", []
        while True:
            line = r.readline()
            if not line:
                log(event="stream-closed")
                return
            line = line.decode("utf-8", errors="replace").rstrip("\r\n")
            if line.startswith("event:"):
                kind = line[6:].strip()
            elif line.startswith("data:"):
                data.append(line[5:].lstrip())
            elif not line:
                if kind == "message" and data:
                    try:
                        d = json.loads("\n".join(data))
                    except ValueError:
                        d = None
                    if isinstance(d, dict):
                        with lock:
                            on_message(d)
                            save()
                elif kind in ("game", "members"):
                    check_now.set()
                kind, data = "", []


def main():
    global stream_open
    with open(CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)
    room = Room(cfg)
    prime(room)
    if "--prime" in sys.argv:
        return
    threading.Thread(target=sender, args=(cfg,), daemon=True).start()
    threading.Thread(target=checker, args=(room,), daemon=True).start()
    check_now.set()
    delay = 1
    while True:
        opened = time.monotonic()
        try:
            stream(room)
        except (OSError, urllib.error.URLError, socket.timeout) as e:
            log(event="stream-error", error=type(e).__name__)
        stream_open = False
        check_now.set()
        delay = 1 if time.monotonic() - opened > 60 else min(delay * 2, 30)
        time.sleep(delay)


if __name__ == "__main__":
    main()
