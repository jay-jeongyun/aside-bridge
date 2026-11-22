#!/usr/bin/env python3
"""bridgectl 0.1.0 - command line client for AsideBridge for Windows.

Lets an AI agent whose shell cannot reach the interactive desktop (for example the Aside agent
on Windows) run PowerShell, UI Automation, Unicode keyboard/mouse input, screenshots and OCR in
the logged-in user's desktop session, through the AsideBridge scheduled task (folder queue).

Usage: bridgectl.py COMMAND [args] [options]

Scripts:     ps 'src' (alias: sh) | cmd 'src'          (or -f FILE, or stdin)
Status:      status | ping | version | quit (stop the bridge; the watchdog restarts it) | stop | resume
Input:       type 'text' | paste 'text' | key ctrl+shift+s (alias: keys)
             click X Y | dclick X Y | rclick X Y | move X Y | drag X1 Y1 X2 Y2 | scroll X Y LINES [HLINES]
             clicktext 'label' [--win TITLE] [--th 0.75]
             Guarded: STOP file, lock screen / UAC desktop, user idle (settings.json idleGuardSec, default 3 s),
             --expect TITLE (foreground window must match). --force skips the idle/expect checks.
Screen:      wins [filter] (alias: windows) | front | idle
             shot [--win TITLE] [--region X,Y,W,H] [--out PATH] [--ocr] [--bg] [--lang TAG]
             ocr [PATH] [--win TITLE] [--region ..] [--find TEXT] [--lang TAG]
             wait text|gone-text|window|gone-window TARGET [--win TITLE] [--timeout S]
             watch [--win TITLE | --region ..] [--wait S] [--threshold PCT]   (returns when the area changes)
Windows:     activate TITLE (alias: focus) | win move|min|max|restore|close|top|notop TITLE [--region X,Y,W,H]
             uia tree|find|action --win TITLE [--name N] [--type Button] [--id ID] [--index I]
                 [--action invoke|setvalue|focus|click|text|toggle|select|expand] [--value V] [--depth 6]
             run --name 'Start menu name' | run PATH [ARGS...] [--cwd D] [--elevated]   (default: non-admin)
             filedlg 'C:\\path\\file.txt' [--title DIALOG] [--noconfirm]
             reg get|set|del 'HKCU:\\Software\\Key' NAME [VALUE] [--type String|DWord|QWord|ExpandString]
             cdp tabs|eval|navigate|new|raw [--port 9222] [--tab 0|id|text] [--expr JS] [--url URL]
Other:       clip [get | set TEXT | paste TEXT] | notify 'msg' [--title T] | notifications [--limit 20] [--app NAME]
             sysinfo | steps [--last 20]
Sequences:   seq -f steps.txt | seq 'step1' 'step2' ...  [--expect TITLE] [--save NAME --desc D --vars k=v,k2=v2]
             One step per line, same syntax as above plus `sleep MS` and `expect TITLE`; `;;` also separates
             steps; prefix `?` marks an optional step. Stops on the first failure with a screenshot path.
             Successful runs of 3+ steps are remembered as recipes (auto-<hash>).
Recipes:     recipe list | show NAME | run NAME k=v ... | rename NAME NEW [desc] | rm NAME (alias: del)

Options:     --timeout N (default 60)  --json  --nowait  --force  --expect TITLE
Environment: ASIDEBRIDGE_HOME (default: this script's folder if it holds a token, else %LOCALAPPDATA%\\aside-bridge)
Exit codes:  0 ok, 1 command failed, 2 bridge unavailable.
"""
import datetime
import hashlib
import json
import os
import shlex
import sys
import time
import uuid

VERSION = "0.1.0"
HEARTBEAT_MAX_AGE = 15


def _home():
    env = os.environ.get("ASIDEBRIDGE_HOME")
    if env:
        return os.path.expandvars(os.path.expanduser(env))
    here = os.path.dirname(os.path.abspath(__file__))
    if os.path.exists(os.path.join(here, "token")):
        return here
    local = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    return os.path.join(local, "aside-bridge")


BASE = _home()
INBOX, OUTBOX = os.path.join(BASE, "inbox"), os.path.join(BASE, "outbox")
STOPFILE = os.path.join(BASE, "STOP")
STEPS = os.path.join(BASE, "work", "steps")
RECIPES = os.path.join(BASE, "recipes")
EXIT_OK, EXIT_FAIL, EXIT_UNAVAILABLE = 0, 1, 2

# mac-compatible option names -> Windows job argument names
OPT_ALIASES = {"--win": "--window", "--out": "--path", "--region": "--rect"}
RAW_TEXT_CMDS = {"ps", "sh", "cmd", "type", "paste", "clip", "notify"}


def status():
    try:
        with open(os.path.join(BASE, "status.json"), encoding="utf-8-sig") as f:
            st = json.load(f)
    except Exception as e:
        return {"running": False, "alive": False, "error": f"no status.json in {BASE} ({e.__class__.__name__})"}
    st["heartbeatAgeSec"] = round(time.time() - float(st.get("heartbeatEpoch", 0)), 1)
    st["running"] = st["alive"] = st["heartbeatAgeSec"] < HEARTBEAT_MAX_AGE
    return st


CAPTURE = None  # list while `seq` collects steps instead of submitting them


def submit(kind, script="", args=None, timeout=60.0, wait=True):
    if CAPTURE is not None:
        CAPTURE.append({"kind": kind, "script": script, "args": args or {}, "timeout": timeout})
        return {"ok": True, "stdout": ""}
    st = status()
    if not st.get("running"):
        return {"ok": False, "error": "UNAVAILABLE: AsideBridge is not running (no fresh heartbeat)", "status": st}
    with open(os.path.join(BASE, "token"), encoding="utf-8-sig") as f:
        token = f.read().strip()
    jid = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    job = {"id": jid, "token": token, "kind": kind, "script": script, "args": args or {}, "timeout": timeout}
    tmp = os.path.join(INBOX, jid + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(job, f, ensure_ascii=False)
    os.replace(tmp, os.path.join(INBOX, jid + ".json"))
    if not wait:
        return {"ok": True, "id": jid, "queued": True}
    out = os.path.join(OUTBOX, jid + ".json")
    deadline = time.time() + timeout + 15
    while time.time() < deadline:
        if os.path.exists(out):
            time.sleep(0.005)
            try:
                with open(out, encoding="utf-8-sig") as f:
                    res = json.load(f)
                os.remove(out)
                return res
            except (json.JSONDecodeError, PermissionError):
                pass
        time.sleep(0.015)
    return {"ok": False, "id": jid, "error": "timed out waiting for the bridge result"}


def opts(argv, names):
    o, rest, i = {}, [], 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--") and a[2:] in names:
            if names[a[2:]] is bool:
                o[a[2:]] = True
                i += 1
            else:
                if i + 1 >= len(argv):
                    raise SystemExit(f"bridgectl: {a} needs a value")
                o[a[2:]] = argv[i + 1]
                i += 2
        else:
            rest.append(a)
            i += 1
    return o, rest


def rect(o, args):
    if "rect" in o:
        args.update(dict(zip("xywh", [int(float(v)) for v in o["rect"].split(",")])))


def fuzzy(hay, needle, th=0.75):
    """Same rule as the bridge: substring, or LCS covers >= th of the needle (tolerates OCR misreads)."""
    h, n = "".join(hay.split()), "".join(needle.split())
    if not n:
        return False
    if n in h:
        return True
    if len(n) < 3:
        return False
    prev = [0] * (len(n) + 1)
    for ch in h:
        cur = [0] * (len(n) + 1)
        for j in range(1, len(n) + 1):
            cur[j] = prev[j - 1] + 1 if ch == n[j - 1] else max(prev[j], cur[j - 1])
        prev = cur
    return prev[-1] / len(n) >= th


def notifications(limit=20, app=None):
    """Recent Windows toast notifications, read locally from the notification database (no bridge job)."""
    import html as _h
    import re
    import shutil
    import sqlite3
    import tempfile
    src = os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db")
    tmp = tempfile.mkdtemp()
    dst = os.path.join(tmp, "n.db")
    try:
        for ext in ("", "-wal", "-shm"):
            if os.path.exists(src + ext):
                shutil.copy2(src + ext, dst + ext)
        con = sqlite3.connect(dst)
        rows = con.execute("select h.PrimaryId, n.ArrivalTime, n.Payload from Notification n join NotificationHandler h "
                           "on n.HandlerId=h.RecordId where n.Type='toast' order by n.ArrivalTime desc limit ?",
                           (limit * 5 if app else limit,)).fetchall()
        con.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    out = []
    for pid, t, pl in rows:
        if app and app.lower() not in (pid or "").lower():
            continue
        xml = pl.decode("utf-8", "ignore") if isinstance(pl, bytes) else str(pl)
        texts = [_h.unescape(x) for x in re.findall(r"<text[^>]*>(.*?)</text>", xml, re.S)]
        when = None
        if t:  # FILETIME (100 ns since 1601, UTC) -> local time
            when = datetime.datetime.fromtimestamp(int(t) / 1e7 - 11644473600).strftime("%Y-%m-%d %H:%M:%S")
        out.append({"app": pid, "time": when, "text": texts})
        if len(out) >= limit:
            break
    return out


# ---------------- recipes (successful sequences, stored as <home>\recipes\*.json) ----------------
def _rpath(name):
    safe = "".join(ch for ch in name if ch.isalnum() or ch in "-_.")
    return os.path.join(RECIPES, ("auto" if name.startswith("auto-") else ""), safe + ".json")


def _rload(name):
    p = _rpath(name)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def _rsave(r):
    p = _rpath(r["name"])
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(r, f, ensure_ascii=False, indent=1)


def _now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


def _auto_name(lines):
    return "auto-" + hashlib.sha1("\n".join(lines).encode("utf-8")).hexdigest()[:8]


def recipe_record(lines, ok, err=None, name=None, desc=None, vars_=None):
    """Save/update a recipe after a seq run. name=None -> auto recipe (deduplicated by content hash)."""
    lines = list(lines)
    if vars_:  # concrete values -> {placeholders}
        for k, v in vars_.items():
            if v:
                lines = [ln.replace(v, "{" + k + "}") for ln in lines]
    if not name:
        if not ok or len(lines) < 3:
            return None
        name = _auto_name(lines)
    r = _rload(name) or {"name": name, "desc": desc or "", "steps": lines, "vars": sorted(vars_ or []),
                         "created": _now(), "ok": 0, "fail": 0}
    if desc:
        r["desc"] = desc
    if ok:
        r["ok"] += 1
        r["lastOk"] = _now()
        if not r.get("steps") or name.startswith("auto-") or vars_:
            r["steps"] = lines
    else:
        r["fail"] += 1
        r["lastFail"] = _now()
        r["lastError"] = (err or "")[:300]
    _rsave(r)
    return name


def recipe_list():
    out = []
    for d in (RECIPES, os.path.join(RECIPES, "auto")):
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if fn.endswith(".json"):
                with open(os.path.join(d, fn), encoding="utf-8") as f:
                    r = json.load(f)
                e = {k: r.get(k) for k in ("name", "desc", "vars", "ok", "fail", "lastOk", "lastError")}
                e["first"] = (r.get("steps") or [""])[0]
                out.append(e)
    out.sort(key=lambda r: (r["name"].startswith("auto-"), -(r.get("ok") or 0)))
    return out


def recipe_cmd(rest, force, as_json):
    op = rest[0] if rest else "list"
    if op == "list":
        for r in recipe_list():
            line = f"{r['name']:<28} ok={r['ok']} fail={r['fail']} vars={','.join(r['vars'] or [])}  {r['desc'] or r['first'][:50]}"
            if r.get("lastError") and (r.get("fail") or 0) > 0:
                line += f"  !last error: {r['lastError'][:60]}"
            print(line)
        return EXIT_OK
    r = _rload(rest[1]) if len(rest) > 1 else None
    if not r:
        print(f"recipe not found: {rest[1:2]}", file=sys.stderr)
        return EXIT_FAIL
    if op == "show":
        print(json.dumps(r, ensure_ascii=False, indent=1))
        return EXIT_OK
    if op in ("rm", "del"):
        os.remove(_rpath(r["name"]))
        print("deleted " + r["name"])
        return EXIT_OK
    if op == "rename":
        os.remove(_rpath(r["name"]))
        r["name"] = rest[2]
        if len(rest) > 3:
            r["desc"] = " ".join(rest[3:])
        _rsave(r)
        print("renamed -> " + r["name"])
        return EXIT_OK
    if op == "run":
        kv = dict(x.split("=", 1) for x in rest[2:] if "=" in x)
        missing = [v for v in r.get("vars", []) if v not in kv]
        if missing:
            print(f"missing vars: {missing}", file=sys.stderr)
            return EXIT_UNAVAILABLE
        lines = []
        for ln in r["steps"]:
            for k, v in kv.items():
                ln = ln.replace("{" + k + "}", v)
            lines.append(ln)
        rc = main(["seq"] + lines + (["--force"] if force else []) + (["--json"] if as_json else []))
        auto = _rload(_auto_name(lines))  # main(seq) counted this run under an auto name; keep it on this recipe only
        if auto and auto["name"] != r["name"]:
            try:
                os.remove(_rpath(auto["name"]))
            except OSError:
                pass
        r = _rload(r["name"]) or r
        if rc == 0:
            r["ok"] += 1
            r["lastOk"] = _now()
        else:
            r["fail"] += 1
            r["lastFail"] = _now()
        _rsave(r)
        return rc
    print("recipe list|show|run|rename|rm", file=sys.stderr)
    return EXIT_UNAVAILABLE


def read_script(rest):
    if rest[:1] == ["-f"]:
        with open(rest[1], encoding="utf-8-sig") as f:
            return f.read()
    return " ".join(rest) if rest else sys.stdin.read()


def main(argv):
    global CAPTURE
    argv = list(argv)
    as_json = "--json" in argv
    nowait = "--nowait" in argv
    force = "--force" in argv
    argv = [a for a in argv if a not in ("--json", "--nowait", "--force")]
    timeout = 60.0
    if "--timeout" in argv:
        i = argv.index("--timeout")
        timeout = float(argv[i + 1])
        del argv[i:i + 2]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return EXIT_OK
    cmd, rest = argv[0], argv[1:]
    if cmd not in RAW_TEXT_CMDS:
        rest = [OPT_ALIASES.get(a, a) for a in rest]
    expect = None
    if cmd not in RAW_TEXT_CMDS and "--expect" in rest:
        i = rest.index("--expect")
        expect = rest[i + 1]
        del rest[i:i + 2]
    kind, script, args = None, "", {}
    num = lambda xs: [int(float(x)) for x in xs]
    seq_meta = None

    if cmd in ("version", "--version"):
        print(f"bridgectl {VERSION} (home: {BASE})")
        return EXIT_OK
    if cmd == "status":
        st = status()
        st["home"] = BASE
        print(json.dumps(st, ensure_ascii=False, indent=1))
        return EXIT_OK if st.get("running") else EXIT_UNAVAILABLE
    if cmd == "stop":
        with open(STOPFILE, "w", encoding="utf-8") as f:
            f.write("stopped by agent " + time.ctime())
        print("STOP set: no jobs or input will run until `resume`")
        return EXIT_OK
    if cmd == "resume":
        try:
            os.remove(STOPFILE)
        except FileNotFoundError:
            pass
        print("resumed")
        return EXIT_OK
    if cmd == "recipe":
        return recipe_cmd(rest, force, as_json)
    if cmd == "notifications":
        o, _ = opts(rest, {"limit": str, "app": str})
        print(json.dumps(notifications(int(o.get("limit", 20)), o.get("app")), ensure_ascii=False, indent=1))
        return EXIT_OK
    if cmd == "steps":
        o, _ = opts(rest, {"last": str})
        files = []
        for d, _, fs in os.walk(STEPS):
            files += [os.path.join(d, f) for f in fs if f.endswith(".jpg")]
        files.sort(key=os.path.getmtime)
        print("\n".join(files[-int(o.get("last", 20)):]))
        return EXIT_OK

    if cmd in ("ping", "quit", "sysinfo", "front", "idle"):
        kind = cmd
    elif cmd in ("wins", "windows"):
        kind = "windows"
    elif cmd in ("ps", "sh", "cmd"):
        kind = "cmd" if cmd == "cmd" else "ps"
        script = read_script(rest)
    elif cmd == "type":
        kind, args = "input", {"action": "type", "text": " ".join(rest) if rest else sys.stdin.read()}
    elif cmd == "paste":
        kind, args = "clip", {"op": "paste", "text": " ".join(rest) if rest else sys.stdin.read()}
    elif cmd in ("key", "keys"):
        kind, args = "input", {"action": "keys", "keys": rest[0]}
    elif cmd in ("click", "dclick", "rclick", "move"):
        x, y = num(rest[:2])
        kind, args = "input", {"action": cmd, "x": x, "y": y}
    elif cmd == "drag":
        x, y, x2, y2 = num(rest[:4])
        kind, args = "input", {"action": "drag", "x": x, "y": y, "x2": x2, "y2": y2}
    elif cmd == "scroll":
        v = num(rest[:4])
        if len(v) < 3:
            raise SystemExit("bridgectl: scroll X Y LINES [HLINES]  (positive = up / right)")
        kind, args = "input", {"action": "scroll", "x": v[0], "y": v[1], "lines": v[2], "hlines": v[3] if len(v) > 3 else 0}
    elif cmd == "clicktext":
        o, r = opts(rest, {"window": str, "th": str, "lang": str})
        kind, args = "clicktext", {"find": " ".join(r), **{k: v for k, v in o.items() if k != "th"}}
        if "th" in o:
            args["fuzzy"] = float(o["th"])
    elif cmd == "notify":
        o, r = opts(rest, {"title": str})
        kind, args = "notify", {"text": " ".join(r), **o}
    elif cmd == "seq":
        so, rest = opts(rest, {"save": str, "desc": str, "vars": str})
        seq_vars = dict(kv.split("=", 1) for kv in so["vars"].split(",")) if so.get("vars") else None
        src = read_script(rest) if rest[:1] == ["-f"] else ("\n".join(rest) if rest else sys.stdin.read())
        seq_lines = [ln.strip() for ln in src.replace(";;", "\n").splitlines() if ln.strip() and not ln.strip().startswith("#")]
        seq_meta = (seq_lines, so.get("save"), so.get("desc"), seq_vars)
        steps, total, cur_expect = [], 0.0, expect
        for line in seq_lines:
            opt = line.startswith("?")
            line = line.lstrip("?").strip()
            parts = shlex.split(line, posix=True)
            if parts[0] == "sleep":
                steps.append({"kind": "sleep", "args": {"ms": int(parts[1])}})
                total += int(parts[1]) / 1000
                continue
            if parts[0] == "expect":
                cur_expect = " ".join(parts[1:]) or None
                continue
            CAPTURE = []
            try:
                main(parts)
            finally:
                cap, CAPTURE = CAPTURE, None
            if not cap:
                print(f"seq: not a bridge step: {line}", file=sys.stderr)
                return EXIT_UNAVAILABLE
            for c in cap:
                if opt:
                    c["optional"] = True
                if cur_expect and c["kind"] in ("input", "clip", "clicktext") and "expect" not in c["args"]:
                    c["args"]["expect"] = cur_expect
                total += min(float(c.pop("timeout", 60)), 60)
            steps += cap
        kind, args = "seq", {"steps": steps}
        timeout = max(timeout, total + 10)
        expect = None
    elif cmd == "watch":
        o, _ = opts(rest, {"window": str, "rect": str, "wait": str, "threshold": str, "path": str})
        ws = float(o.pop("wait", 60))
        kind, args = "watch", {k: v for k, v in o.items() if k != "rect"}
        args["timeoutSec"] = ws
        timeout = max(timeout, ws + 20)
        rect(o, args)
    elif cmd == "filedlg":
        o, r = opts(rest, {"title": str, "noconfirm": bool})
        kind, args = "filedlg", {"path": r[0], **o}
    elif cmd == "clip":
        sub = rest[0] if rest and rest[0] in ("get", "set", "paste") else None
        if sub:
            text = " ".join(rest[1:]) if len(rest) > 1 else (sys.stdin.read() if sub != "get" else "")
        else:
            sub, text = ("set", " ".join(rest)) if rest else ("get", "")
        kind, args = "clip", {"op": sub, "text": text}
    elif cmd == "wait":
        o, r = opts(rest, {"window": str, "text": str, "gone": bool, "rect": str, "wait": str, "lang": str})
        if r and r[0] in ("text", "gone-text", "window", "gone-window"):  # mac-style: wait text|window TARGET
            what, target = r[0], " ".join(r[1:])
            if what.endswith("text"):
                o["text"] = target
            else:
                o["window"] = target
            if what.startswith("gone"):
                o["gone"] = True
            ws = float(o.pop("wait", timeout))
        else:
            ws = float(o.pop("wait", 20))
        kind, args = "wait", {k: v for k, v in o.items() if k != "rect"}
        args["timeoutSec"] = ws
        timeout = max(timeout, ws + 20)
        rect(o, args)
    elif cmd == "run":
        o, r = opts(rest, {"name": str, "cwd": str, "elevated": bool})
        kind, args = "run", dict(o)
        if r:
            args["path"] = r[0]
            args["argv"] = " ".join(r[1:])
    elif cmd == "reg":
        o, r = opts(rest, {"type": str})
        kind, args = "reg", {"op": r[0], "path": r[1], "name": r[2], **o}
        if len(r) > 3:
            args["value"] = r[3]
        elif r[0] == "set":
            args["value"] = ""
    elif cmd == "win":
        o, r = opts(rest, {"rect": str, "handle": str})
        kind, args = "win", {"op": r[0], "title": " ".join(r[1:]), **{k: v for k, v in o.items() if k != "rect"}}
        rect(o, args)
    elif cmd in ("activate", "focus"):
        kind, args = "focus", {"title": " ".join(rest)}
    elif cmd == "shot":
        o, _ = opts(rest, {"window": str, "ocr": bool, "path": str, "rect": str, "lang": str, "bg": bool})
        kind = "shotbg" if o.pop("bg", False) else "shot"
        args = {k: v for k, v in o.items() if k != "rect"}
        rect(o, args)
    elif cmd == "ocr":
        o, r = opts(rest, {"lang": str, "window": str, "rect": str, "find": str, "th": str, "fg": bool})
        find, th = o.pop("find", None), float(o.pop("th", 0.75))
        if r:  # OCR an image file
            kind, args = "ocr", {"path": r[0], **{k: v for k, v in o.items() if k == "lang"}}
        else:  # OCR the screen, a region, or a window (background capture unless --fg)
            kind = "shotbg" if o.get("window") and not o.pop("fg", False) else "shot"
            o.pop("fg", None)
            args = {"ocr": True, **{k: v for k, v in o.items() if k != "rect"}}
            rect(o, args)
        if find and CAPTURE is None:
            res = submit(kind, "", args, timeout)
            data = res.get("data") or {}
            ocr = data.get("ocr", data) if isinstance(data, dict) else {}
            hits = [ln for ln in (ocr.get("lines") or []) if fuzzy(ln.get("text", ""), find, th)]
            out = {"ok": bool(hits) and res.get("ok", False), "find": find, "matches": hits}
            if not res.get("ok"):
                out["error"] = res.get("error") or res.get("stderr")
            print(json.dumps(out, ensure_ascii=False, indent=1))
            return EXIT_OK if out["ok"] else (EXIT_UNAVAILABLE if "UNAVAILABLE" in str(out.get("error")) else EXIT_FAIL)
    elif cmd == "uia":
        o, r = opts(rest, {"window": str, "handle": str, "name": str, "type": str, "id": str, "index": str,
                           "action": str, "value": str, "depth": str, "max": str})
        kind, args = "uia", {"op": r[0] if r else "tree", **o}
    elif cmd == "cdp":
        o, r = opts(rest, {"port": str, "tab": str, "expr": str, "url": str, "method": str})
        if "tab" in o and o["tab"].isdigit():
            o["tab"] = int(o["tab"])
        kind, args = "cdp", {"op": r[0] if r else "tabs", **o}
    else:
        print(f"unknown command {cmd} (see --help)", file=sys.stderr)
        return EXIT_UNAVAILABLE

    if force:
        args["force"] = True
    if expect:
        args["expect"] = expect
    res = submit(kind, script, args, timeout, wait=not nowait)
    if cmd in ("wins", "windows") and rest and res.get("ok") and isinstance(res.get("data"), list):
        flt = " ".join(rest).lower()
        res["data"] = [w for w in res["data"] if flt in str(w.get("Title", "")).lower()]
        res["stdout"] = json.dumps(res["data"], ensure_ascii=False)
    if seq_meta and CAPTURE is None and not nowait:
        try:
            nm = recipe_record(seq_meta[0], bool(res.get("ok")), res.get("stderr") or res.get("error"), *seq_meta[1:])
            if nm and not as_json:
                sys.stderr.write("[recipe] " + nm + (" saved" if res.get("ok") else " failure recorded") + "\n")
        except Exception as e:
            sys.stderr.write(f"[recipe] not saved: {e}\n")
    if as_json:
        print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        if res.get("stdout"):
            sys.stdout.write(res["stdout"] if res["stdout"].endswith("\n") else res["stdout"] + "\n")
        if res.get("stderr"):
            sys.stderr.write(res["stderr"])
        if res.get("error"):
            sys.stderr.write("bridge error: " + res["error"] + "\n")
    if "UNAVAILABLE" in (res.get("error") or ""):
        return EXIT_UNAVAILABLE
    return EXIT_OK if res.get("ok") else EXIT_FAIL


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass
    sys.exit(main(sys.argv[1:]))
