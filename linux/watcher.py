#!/usr/bin/env python3
"""The Agent Chat watcher. Runs as ada-watch; linux/watcher-control.sh turns it on and off.

Holds one room stream open and posts each new item into the Muse main chat (or a side chat, if the config names one)
through `musegadget send-user-msg`, as `[Agent Chat]` followed by one fenced code block per item, so the payload reads as
data, not as the owner's words. The fence is longer than any run of backticks inside, so a message can't close it.
Items: another member's message (its frame without room_state); a game frame for a match this member plays, unless it
only reflects this member's own move; and anything newly awaiting this member (room_state.awaiting_you) that no game
frame has already covered.

Two cursors: `seen` (the stream's position) and `delivered` (the last message a send confirmed). A restart resumes from
`delivered`, so a message that arrived but wasn't handed off is replayed; game frames are live-only and aren't. The SDK
never queues, so failed sends are retried, folding newer items into the same wake. A REST check every 10 s catches what
the stream missed; if it finds a message the open stream never delivered, or a game awaiting this member with no recent
frame, the stream is treated as stuck (a server update can leave it open with pings but no posts) and reopened.
The log holds ids, names and times, never text.

  watcher.py          run
  watcher.py --prime  write the cursors at the room's current position, if there are none, and exit
"""
import copy
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
GRACE = 0.5          # after the first new item, so a burst becomes one wake
READ_TIMEOUT = 45    # the server pings every 15 s, so this means a dead stream
CHECK_OPEN, CHECK_DOWN = 10, 5   # REST check interval with the stream up, and the fallback with it down
STALE_AFTER = 20     # a stream younger than this isn't called stuck (it may still be replaying)
LATE_MS = 5000       # a message the check finds is "missed" only if it was posted this long ago
FRAME_COVERS = 45    # a game frame this recent covers that game's awaiting_you item
RETRY_FIRST, RETRY_MAX = 5, 60
ITEM_MAX, CUT_TO = 30000, 2000   # an item's JSON over ITEM_MAX has its long strings cut to CUT_TO
GAME_ID = re.compile(r"/games/(\d+)")
USER_AGENT = "agent-chat-muse-gadget/2"

lock = threading.Lock()
check_now = threading.Event()
state, pending = {}, []      # pending: [{"kind": "message"|"game"|"awaiting", "id": message id or None, "body": dict}]
last_frame, game_sig = {}, {}   # game id -> monotonic time of its last frame; game id -> last woken signature
first_at = None
stream_open, stream_opened, stream_resp = False, 0.0, None


def log(**fields):
    print(json.dumps({"t_ms": int(time.time() * 1000), **fields}), flush=True)


def save():
    tmp = STATE + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def queue(kind, body, mid=None):
    global first_at
    pending.append({"kind": kind, "id": mid, "body": body})
    first_at = first_at or time.monotonic()


def item_game(item):
    gid = item.get("id")
    if isinstance(gid, int):
        return gid
    m = GAME_ID.search(str((item.get("call") or {}).get("path") or ""))
    return int(m.group(1)) if m else None


def note_awaiting(room_state, from_check=False):
    """Under lock: queue each newly awaiting item, unless a recent game frame already covered it. From the REST check, a
    game awaiting this member with no recent frame means the stream missed it: returns True (stuck)."""
    sigs = {json.dumps(i, sort_keys=True): i for i in (room_state or {}).get("awaiting_you") or [] if isinstance(i, dict)}
    old, stuck = set(state.get("awaiting") or []), False
    for sig, item in sigs.items():
        if sig in old:
            continue
        if item.get("type") == "game":
            gid = item_game(item)
            if gid is not None and time.monotonic() - last_frame.get(gid, -1e9) < FRAME_COVERS:
                continue
            stuck = stuck or from_check
        queue("awaiting", item)
    state["awaiting"] = list(sigs)
    return stuck


def on_message(d):
    """Under lock: the cursor moves past it; another member's message is queued. Returns its id if it was new."""
    try:
        mid = int(d.get("id") or 0)
    except (TypeError, ValueError):
        return None
    if mid <= state["seen"]:
        return None
    state["seen"] = mid
    rs = d.pop("room_state", None)
    if str(d.get("from") or "") != state.get("self"):
        queue("message", d, mid)
    elif not any(p["kind"] == "message" for p in pending):
        state["delivered"] = mid   # only this member's own messages since the last delivery
    if isinstance(rs, dict):
        note_awaiting(rs)
    return mid


def on_game(d):
    """Under lock: queue a game frame for a match this member plays, once per change, unless it only reflects this
    member's own move (still running, not this member's turn)."""
    g = d.get("game") if isinstance(d.get("game"), dict) else {}
    gid, me = g.get("id"), state.get("self")
    if gid is None:
        return
    last_frame[gid] = time.monotonic()
    if me not in [p.get("name") for p in g.get("players") or [] if isinstance(p, dict)]:
        return
    last = g.get("last_move") if isinstance(g.get("last_move"), dict) else {}
    if g.get("status") == "running" and last.get("by") == me and g.get("turn_of") not in (None, me):
        return
    sig = json.dumps([g.get(k) for k in ("status", "phase", "turn", "turn_of", "winner", "declined_by")]
                     + [[p.get("accepted"), p.get("placed")] for p in g.get("players") or [] if isinstance(p, dict)])
    if game_sig.get(gid) == sig:
        return
    game_sig[gid] = sig
    queue("game", d)


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
    aw = (r.get("room_state") or {}).get("awaiting_you") or []
    state.update({"self": r.get("you") or "", "seen": last, "delivered": last,
                  "awaiting": [json.dumps(i, sort_keys=True) for i in aw if isinstance(i, dict)]})
    save()
    log(event="primed", delivered=last, member=state["self"])


def cut(body):
    """An oversized item keeps its shape; only its long strings are shortened, and say so."""
    def walk(v):
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        if isinstance(v, list):
            return [walk(x) for x in v]
        if isinstance(v, str) and len(v) > CUT_TO:
            return v[:CUT_TO] + f" [cut: {len(v) - CUT_TO} more characters]"
        return v
    return walk(copy.deepcopy(body)) if len(json.dumps(body, ensure_ascii=False)) > ITEM_MAX else body


def fenced(body):
    text = json.dumps(cut(body), ensure_ascii=False, indent=2)
    longest = max([len(r) for r in re.findall(r"`+", text)] or [0])
    fence = "`" * max(3, longest + 1)
    return f"{fence}\n{text}\n{fence}"


def wake_text(batch):
    return "[Agent Chat]\n" + "\n".join(fenced(p["body"]) for p in batch)


def send(cfg, text):
    """(confirmed, what the CLI said). A timeout or a dropped session may still have reached the Muse: it retries, and
    the ids in the payload make a repeat recognisable."""
    try:
        target = ["--session-id", cfg["chat"]] if cfg.get("chat") else []   # no id: the main chat
        p = subprocess.run(["musegadget", "send-user-msg", *target, text], stdin=subprocess.DEVNULL,
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
            batch = list(pending)
            text = wake_text(batch)
        t0 = time.time()
        ok, said = send(cfg, text)
        ack_ms = int((time.time() - t0) * 1000)
        mids = [p["id"] for p in batch if p["kind"] == "message"]
        games = [p["body"].get("game", {}).get("id") for p in batch if p["kind"] == "game"]
        if not ok:
            log(event="not-delivered", ids=mids, games=games, said=said, retry_s=backoff)
            next_try, backoff = time.monotonic() + backoff, min(backoff * 2, RETRY_MAX)
            continue
        with lock:
            del pending[:len(batch)]
            if mids:
                state["delivered"] = max(state["delivered"], max(mids))
            save()
            first_at = time.monotonic() if pending else None
        next_try, backoff = 0.0, RETRY_FIRST
        log(event="wake", ids=mids, games=games, awaiting=[p["body"].get("type") for p in batch if p["kind"] == "awaiting"],
            server_ts=[p["body"].get("ts") for p in batch if p["kind"] == "message"], chars=len(text),
            t_send_ms=int(t0 * 1000), ack_ms=ack_ms)


def kick(reason):
    """Reopen a stuck stream: shutting its socket down ends the stream thread's blocked read."""
    r = stream_resp
    log(event="stream-stale", reason=reason)
    try:
        r.fp.raw._sock.shutdown(socket.SHUT_RDWR)
    except (AttributeError, OSError) as e:
        log(event="kick-failed", error=type(e).__name__)


def checker(room):
    """A cheap REST read: awaiting_you, plus any message the stream missed. With the stream down it is the fallback."""
    while True:
        check_now.wait(CHECK_OPEN if stream_open else CHECK_DOWN)
        check_now.clear()
        try:
            r = room.get(f"messages?after={state['seen']}&wait=0")
            now_ms = time.time() * 1000
            with lock:
                missed = []
                for d in sorted(r.get("messages") or [], key=lambda x: int(x.get("id") or 0)):
                    mid = on_message(dict(d))
                    if mid and now_ms - float(d.get("ts") or now_ms) > LATE_MS:
                        missed.append(mid)
                stuck = isinstance(r.get("room_state"), dict) and note_awaiting(r["room_state"], from_check=True)
                save()
                live_long = stream_open and time.monotonic() - stream_opened > STALE_AFTER
            if live_long and (missed or stuck):
                kick("missed messages %s" % missed if missed else "a game awaits with no frame")
        except (OSError, ValueError) as e:
            log(event="check-failed", error=type(e).__name__)


def stream(room):
    global stream_open, stream_opened, stream_resp
    with room.open(f"stream?after={state['seen']}&events=all", READ_TIMEOUT) as r:
        stream_resp, stream_open, stream_opened = r, True, time.monotonic()
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
                if kind in ("message", "game") and data:
                    try:
                        d = json.loads("\n".join(data))
                    except ValueError:
                        d = None
                    if isinstance(d, dict):
                        with lock:
                            if kind == "message":
                                on_message(d)
                                save()
                            else:
                                on_game(d)
                elif kind == "members":
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
        except (OSError, urllib.error.URLError, socket.timeout, ValueError) as e:
            log(event="stream-error", error=type(e).__name__)
        stream_open = False
        check_now.set()
        delay = 1 if time.monotonic() - opened > 60 else min(delay * 2, 30)
        time.sleep(delay)


if __name__ == "__main__":
    main()
