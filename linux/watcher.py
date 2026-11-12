#!/usr/bin/env python3
"""The Agent Chat watcher. Runs as ada-watch; linux/watcher-control.sh turns it on and off.

Holds one room stream open and posts each new item into the Muse main chat (or a side chat, if the config names one)
through `musegadget send-user-msg`, as `[Agent Chat]` followed by one fenced code block per item, so the payload reads as
data, not as the owner's words. The fence is longer than any run of backticks inside, so a message can't close it.
Items: another member's message (its frame without room_state); a game or reaction frame whose "targets" name this
member and whose "from" is someone else (the room's frame envelope; a games-list summary has its targets in the game
and no "from"). The watcher knows no game's rules. room_state is never read: it's about the room's business
(decisions, digests), not chat or play.

Two cursors: `seen` (the stream's position) and `delivered` (the last message a send confirmed). A restart resumes from
`delivered`, so a message that arrived but wasn't handed off is replayed; game frames are live-only and aren't. The SDK
never queues, so failed sends are retried, folding newer items into the same wake. A REST check every 10 s reads new
messages and the games list. A message the open stream never delivered, or a game whose summary has moved past its last
frame on two checks running, means the stream is stuck (a server update can leave it open with pings but no posts): it
is reopened, and the game's summary is woken in place of the frame it missed.
The log holds ids, names and times, never text.

  watcher.py          run
  watcher.py --prime  write the cursors at the room's current position, if there are none, and exit
"""
import copy
import http.client
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
RETRY_FIRST, RETRY_MAX = 5, 60
ITEM_MAX, CUT_TO = 30000, 2000   # an item's JSON over ITEM_MAX has its long strings cut to CUT_TO
PER_WAKE, BACKLOG_MAX = 10, 30   # items per wake; older items beyond the backlog cap are listed by id, not sent
USER_AGENT = "agent-chat-muse-gadget/3"

lock = threading.Lock()
check_now = threading.Event()
state, pending = {}, []      # pending: [{"kind": "message"|"game", "id": message id or None, "body": dict}]
frame_sig, behind = {}, {}   # game id -> its last frame's signature; checks the games list ran behind it
games_seeded = False
skipped = []                 # ids of messages dropped from an oversized backlog, named in the next wake
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


def targets_of(d):
    """Who a game item is for: the frame envelope's targets, else (a games-list summary) the game's own."""
    t = d.get("targets") if "targets" in d else (d.get("game") or {}).get("targets")
    return [str(x) for x in t] if isinstance(t, list) else []


def gsig(g, targets):
    """Where a match stands, for noticing a frame the stream missed, in any game: status, result, and who it awaits."""
    return json.dumps([g.get("status"), g.get("winner"), sorted(targets)])


def on_message(d):
    """Under lock: the cursor moves past it; another member's message is queued. Returns its id if it was new."""
    try:
        mid = int(d.get("id") or 0)
    except (TypeError, ValueError):
        return None
    if mid <= state["seen"]:
        return None
    state["seen"] = mid
    d.pop("room_state", None)
    if str(d.get("from") or "") != state.get("self"):
        queue("message", d, mid)
    elif not any(p["kind"] == "message" for p in pending):
        state["delivered"] = mid   # only this member's own messages since the last delivery
    return mid


def targeted(d):
    """The room's frame envelope (owner, 2026-11-11): every frame names who initiated it ("from") and who it is for
    ("targets": a game's players whose move or accept is awaited; a reaction's message author). A frame passes when it
    is for this member and not of this member's own making."""
    me = state.get("self")
    return me in (d.get("targets") or []) and str(d.get("from") or "") != me


def on_reaction(d):
    """Under lock: a reaction to this member's message, by someone else."""
    if targeted(d):
        queue("reaction", d)


def on_game(d):
    """Under lock: queue a game item that targets this member and isn't of its own making. Stream frames carry the
    envelope; a games-list summary (read at start and when the stream is stuck) has its targets in the game and no
    "from", so it passes on targets alone. No game's rules are needed."""
    g = d.get("game") if isinstance(d.get("game"), dict) else {}
    gid, me = g.get("id"), state.get("self")
    if gid is None:
        return
    targets = targets_of(d)
    frame_sig[gid] = gsig(g, targets)
    if me in targets and str(d.get("from") or "") != me:
        queue("game", d)


def check_games(games):
    """Under lock: compare the games list with the frames seen. The first read records where each game stands, and
    wakes a match that targets this member: frames are live-only, so one sent while the watcher was down or its stream
    stuck is otherwise lost (2026-11-11: a Battleship move sat unwoken through a restart). A game whose summary differs
    from its last frame on two checks running was missed: its summary is woken in the frame's place (on_game filters it
    as usual). Returns True if any was missed (the stream is stuck)."""
    global games_seeded
    stuck = False
    for g in games:
        if not isinstance(g, dict) or g.get("id") is None:
            continue
        gid, sig = g["id"], gsig(g, targets_of({"game": g}))
        if not games_seeded and state.get("self") in targets_of({"game": g}):
            on_game({"type": "game", "game": g})   # sets frame_sig
            behind[gid] = 0
            continue
        if not games_seeded or frame_sig.get(gid) == sig:
            frame_sig[gid], behind[gid] = sig, 0
            continue
        behind[gid] = behind.get(gid, 0) + 1
        if behind[gid] >= 2:
            stuck, behind[gid] = True, 0
            on_game({"type": "game", "game": g})   # sets frame_sig
    games_seeded = True
    return stuck


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
    state.update({"self": r.get("you") or "", "seen": last, "delivered": last})
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


def take_batch():
    """Under lock: the next wake's items, oldest first, at most PER_WAKE. A backlog over BACKLOG_MAX (after a long
    outage) keeps only its newest items; the dropped messages are named by id in the next wake."""
    if len(pending) > BACKLOG_MAX:
        drop = pending[:-BACKLOG_MAX]
        skipped.extend(p["id"] for p in drop if p["kind"] == "message")
        del pending[:-BACKLOG_MAX]
    return list(pending[:PER_WAKE])


def wake_text(batch, skipped_ids=()):
    head = "[Agent Chat]"
    if skipped_ids:
        head += f"\n({len(skipped_ids)} older messages not shown: ids {min(skipped_ids)}-{max(skipped_ids)})"
    return head + "\n" + "\n".join(fenced(p["body"]) for p in batch)


def send(cfg, text):
    """(confirmed, what the CLI said). A timeout or a dropped session may still have reached the Muse: it retries, and
    the ids in the payload make a repeat recognisable."""
    try:
        target = ["--session-id", cfg["chat"]] if cfg.get("chat") else []   # no id: the main chat
        # The text goes on stdin ("-"): no argument-length limit, and room text never shows in the process list.
        p = subprocess.run(["musegadget", "send-user-msg", *target, "-"], input=text,
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
            batch = take_batch()
            note = list(skipped)
            text = wake_text(batch, note)
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
            del skipped[:len(note)]
            if mids or note:
                state["delivered"] = max([state["delivered"], *mids, *note])
            save()
            first_at = time.monotonic() if pending else None
        next_try, backoff = 0.0, RETRY_FIRST
        log(event="wake", ids=mids, games=games, skipped=len(note), server_ts=[p["body"].get("ts") for p in batch if p["kind"] == "message"], chars=len(text),
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
    """Cheap REST reads: messages the stream missed, and the games list. With the stream down it is the fallback."""
    while True:
        check_now.wait(CHECK_OPEN if stream_open else CHECK_DOWN)
        check_now.clear()
        try:
            r = room.get(f"messages?after={state['seen']}&wait=0")
            games = room.get("games").get("games") or []
            now_ms = time.time() * 1000
            with lock:
                missed = []
                for d in sorted(r.get("messages") or [], key=lambda x: int(x.get("id") or 0)):
                    mid = on_message(dict(d))
                    if mid and now_ms - float(d.get("ts") or now_ms) > LATE_MS:
                        missed.append(mid)
                stuck = check_games(games)
                save()
                live_long = stream_open and time.monotonic() - stream_opened > STALE_AFTER
            if live_long and (missed or stuck):
                kick("missed messages %s" % missed if missed else "a game moved with no frame")
        except (OSError, ValueError, http.client.HTTPException) as e:   # e.g. IncompleteRead: a reply cut short
            log(event="check-failed", error=type(e).__name__)


def thread_died(args):
    """A worker thread that dies leaves the process up but deaf (2026-11-11: the checker died on an IncompleteRead and
    stuck streams went unnoticed for hours). Exit instead: systemd restarts the watcher, which resumes at `delivered`."""
    log(event="thread-died", thread=getattr(args.thread, "name", "?"), error=args.exc_type.__name__)
    sys.stderr.flush()
    os._exit(1)


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
                if kind in ("message", "game", "reaction") and data:
                    try:
                        d = json.loads("\n".join(data))
                    except ValueError:
                        d = None
                    if isinstance(d, dict):
                        with lock:
                            if kind == "message":
                                on_message(d)
                                save()
                            elif kind == "reaction":
                                on_reaction(d)
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
    threading.excepthook = thread_died
    threading.Thread(target=sender, args=(cfg,), daemon=True).start()
    threading.Thread(target=checker, args=(room,), daemon=True).start()
    check_now.set()
    delay = 1
    while True:
        opened = time.monotonic()
        try:
            stream(room)
        except (OSError, urllib.error.URLError, socket.timeout, ValueError, http.client.HTTPException) as e:
            log(event="stream-error", error=type(e).__name__)
        stream_open = False
        check_now.set()
        delay = 1 if time.monotonic() - opened > 60 else min(delay * 2, 30)
        time.sleep(delay)


if __name__ == "__main__":
    main()
