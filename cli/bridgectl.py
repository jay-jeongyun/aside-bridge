#!/usr/bin/env python3
"""bridgectl 0.1.0 - command line client for AsideBridge (macOS).

Lets a sandboxed AI agent (e.g. the Aside browser agent) run AppleScript, JXA, shell,
synthetic input, screenshots and OCR OUTSIDE its sandbox, through the AsideBridge app.
Fast path: resident worker `bridged` over a unix socket (auto-started through AsideBridge
so it inherits its permissions). Fallback: the bridge's folder queue.

Usage: bridgectl.py COMMAND [args] [options]

Scripts:     as 'src' | jxa 'src' | sh 'src'      (or -f FILE, or stdin)
             --timeout N  --json  --bg (detached, parallel)  --legacy (force folder queue)
Status:      status | ping | version | daemon start|stop|restart|status | quit (restart bridge)
Input:       type 'text' | paste 'text' [--keep-clip] | key cmd+shift+g
             click X Y | dclick X Y | rclick X Y | move X Y | drag X1 Y1 X2 Y2 | scroll DY [DX]
             clicktext 'label' [--win APP] [--th 0.75]
             Guarded: STOP file, screen lock, user idle (--idle S, default 3), --expect APP.
             --force skips the guard (only when the human asked for it).
Screen:      wins [filter] | front | idle | shot [--win APP|ID] [--region x,y,w,h] [--out PATH]
             ocr [--win APP] [--region ..] [--find TEXT] [--fast] [--keep]
             wait text|gone-text|window|gone-window TARGET [--win APP] [--timeout S]
             watch [--win APP | --region ..] [--sec 1]
Agent tools: desktop ARGS... (Vercel agent-desktop: snapshot, click @ref)  alias: ad
             browser ARGS... (Vercel agent-browser: CDP web automation)    alias: web
             Runs the tool outside the sandbox. Binaries: PATH or AGENT_DESKTOP_BIN / AGENT_BROWSER_BIN.
Other:       clip [text] | activate APP | notify 'msg' | sysinfo | stop | resume
Sequences:   seq -f steps.txt | seq 'step1' 'step2' ...  [--expect APP] [--save NAME] [--vars k=v ...]
             One step per line, same syntax as above plus `sleep S` and `expect APP`;
             prefix `?` marks an optional step. Stops on the first failure and saves a screenshot.
             Successful runs of 3+ steps are remembered as recipes (auto-<hash>).
Recipes:     recipe list | show NAME | run NAME k=v ... | save NAME --from auto-xxxx k=v ... | rm NAME

Environment: ASIDEBRIDGE_HOME (default ~/.asidebridge), ASIDEBRIDGE_WORKER (path to bridged),
             ASIDEBRIDGE_IDLE (default idle guard seconds, default 3)
Exit codes:  0 ok, 1 command failed, 2 bridge unavailable.
"""
import datetime
import hashlib
import json
import os
import re
import shlex
import socket
import sys
import time
import uuid

VERSION = "0.1.0"

BASE = os.path.expanduser(os.environ.get("ASIDEBRIDGE_HOME") or "~/.asidebridge")
INBOX, OUTBOX = os.path.join(BASE, "inbox"), os.path.join(BASE, "outbox")
SOCK = os.path.join(BASE, "run", "bridged.sock")
RECIPES = os.path.join(BASE, "recipes.json")
STOPFILE = os.path.join(BASE, "STOP")
WORKER_APP = os.path.join(BASE, "app", "AsideBridgeWorker.app")
WORKER = os.environ.get("ASIDEBRIDGE_WORKER") or os.path.join(WORKER_APP, "Contents", "MacOS", "bridged")
DEFAULT_IDLE = float(os.environ.get("ASIDEBRIDGE_IDLE", "3"))
HEARTBEAT_MAX_AGE = 20

INPUT_CMDS = {"type", "paste", "key", "click", "dclick", "rclick", "drag", "scroll", "move", "clicktext"}
JSON_CMDS = {"wins", "front", "idle", "ocr", "shot", "sysinfo", "wait", "watch", "clicktext"}
KINDS = {"as": "applescript", "jxa": "jxa", "sh": "shell"}

EXIT_OK, EXIT_FAIL, EXIT_UNAVAILABLE = 0, 1, 2


class Unavailable(Exception):
    """The bridge (or its worker) cannot be reached."""


# ---------------- legacy folder queue ----------------
def status():
    try:
        with open(os.path.join(BASE, "status.json")) as f:
            st = json.load(f)
    except Exception as e:
        return {"running": False, "error": f"no status.json in {BASE} ({e.__class__.__name__})"}
    age = time.time() - float(st.get("heartbeatEpoch", 0))
    st["heartbeatAgeSec"] = round(age, 1)
    st["running"] = age < HEARTBEAT_MAX_AGE
    return st


def _token():
    try:
        with open(os.path.join(BASE, "token")) as f:
            return f.read().strip()
    except OSError:
        raise Unavailable(f"token not found in {BASE} (is AsideBridge installed and started?)")


def _new_id():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]


def submit(kind, script="", timeout=60.0, wait=True):
    """Drop a job into the bridge inbox and wait for its result file."""
    if not status().get("running"):
        raise Unavailable("AsideBridge is not running (no fresh heartbeat in status.json)")
    jid = _new_id()
    job = {"id": jid, "token": _token(), "kind": kind, "script": script, "timeout": timeout}
    tmp = os.path.join(INBOX, jid + ".json.tmp")
    with open(tmp, "w") as f:
        json.dump(job, f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.rename(tmp, os.path.join(INBOX, jid + ".json"))
    if not wait:
        return {"ok": True, "id": jid, "queued": True}
    out = os.path.join(OUTBOX, jid + ".json")
    deadline = time.time() + timeout + 20
    while time.time() < deadline:
        if os.path.exists(out):
            time.sleep(0.05)
            try:
                with open(out) as f:
                    res = json.load(f)
                os.remove(out)
                return res
            except json.JSONDecodeError:
                pass  # still being written
        time.sleep(0.15)
    return {"ok": False, "id": jid, "error": "timed out waiting for the bridge result"}


def submit_bg(kind, script, timeout):
    """Run a job as a detached child of the bridge, so a job stuck on a permission prompt
    never blocks the bridge queue. Several --bg jobs run in parallel."""
    jid = _new_id()
    d = os.path.join(BASE, "work", "bg-" + jid)
    os.makedirs(d, exist_ok=True)
    ext = {"applescript": "applescript", "jxa": "js", "shell": "sh"}[kind]
    with open(os.path.join(d, "job." + ext), "w") as f:
        f.write(script)
    q = shlex.quote
    runner = {"applescript": f"/usr/bin/osascript {q(d + '/job.applescript')}",
              "jxa": f"/usr/bin/osascript -l JavaScript {q(d + '/job.js')}",
              "shell": f"/bin/zsh {q(d + '/job.sh')}"}[kind]
    # perl alarm = portable timeout (exit 142 on SIGALRM)
    launcher = (f"cd {q(d)}; nohup /usr/bin/perl -e 'alarm shift; exec @ARGV' {int(timeout)} /bin/zsh -c {q(runner)} "
                f"> {q(d + '/out')} 2> {q(d + '/err')} < /dev/null; echo $? > {q(d + '/rc.tmp')}; mv {q(d + '/rc.tmp')} {q(d + '/rc')}")
    r = submit("shell", f"( {launcher} ) > /dev/null 2>&1 &\necho started", 15)
    if not r.get("ok"):
        return r
    deadline = time.time() + timeout + 5
    rc_path = os.path.join(d, "rc")
    while time.time() < deadline:
        if os.path.exists(rc_path):
            def read(n):
                with open(os.path.join(d, n)) as f:
                    return f.read()
            rc = int(read("rc").strip() or 1)
            return {"ok": rc == 0, "id": jid, "exitCode": rc, "stdout": read("out"), "stderr": read("err"),
                    "timedOut": rc == 142, "via": "bg"}
        time.sleep(0.2)
    return {"ok": False, "id": jid, "error": "background job timed out", "timedOut": True, "via": "bg"}


# ---------------- resident worker (fast path) ----------------
def dcall(req, timeout=60):
    req = dict(req)
    req["token"] = _token()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout + 30)
    try:
        s.connect(SOCK)
        s.sendall(json.dumps(req, ensure_ascii=False).encode() + b"\n")
        buf = b""
        while True:
            b = s.recv(65536)
            if not b:
                break
            buf += b
    finally:
        s.close()
    return json.loads(buf.decode())


def daemon_alive():
    try:
        return bool(dcall({"cmd": "ping"}, 3).get("ok"))
    except Exception:
        return False


def daemon_start():
    """Start bridged THROUGH the bridge, so it inherits AsideBridge's TCC grants."""
    if daemon_alive():
        return True
    if not os.path.exists(WORKER):
        raise Unavailable(f"worker binary not found: {WORKER} (run scripts/install.sh or set ASIDEBRIDGE_WORKER)")
    app = os.path.dirname(os.path.dirname(os.path.dirname(WORKER)))
    q = shlex.quote
    log = os.path.join(BASE, "logs", "bridged.out")
    r = submit("shell", f"xattr -cr {q(app)} 2>/dev/null; nohup {q(WORKER)} >> {q(log)} 2>&1 < /dev/null &\necho started", 15)
    if not r.get("ok"):
        return False
    for _ in range(60):
        if daemon_alive():
            return True
        time.sleep(0.05)
    return False


def fast(req, timeout=60):
    """Call the worker, auto-starting it once. Raises Unavailable if it cannot be reached."""
    try:
        return dcall(req, timeout)
    except (OSError, ValueError):
        pass
    if daemon_start():
        return dcall(req, timeout)
    raise Unavailable("worker (bridged) unavailable")


# ---------------- argument parsing ----------------
def popopt(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 >= len(argv):
            raise SystemExit(f"bridgectl: option {name} needs a value")
        v = argv[i + 1]
        del argv[i:i + 2]
        return v
    return default


def popflag(argv, name):
    if name in argv:
        argv.remove(name)
        return True
    return False


def need(a, n, usage):
    if len(a) < n:
        raise SystemExit(f"bridgectl: usage: {usage}")


def read_script(a):
    if len(a) >= 2 and a[0] == "-f":
        with open(a[1]) as f:
            return f.read()
    if a:
        return a[0]
    return sys.stdin.read()


def build_req(argv):
    """Turn a command line (list) into a worker request. Returns (req, timeout)."""
    argv = list(argv)
    common = {"idle": DEFAULT_IDLE}
    if popflag(argv, "--force"): common["force"] = True
    if popflag(argv, "--keep-clip"): common["restore"] = False
    if popflag(argv, "--fast"): common["fast"] = True
    if popflag(argv, "--keep"): common["keep"] = True
    for opt, key, conv in (("--idle", "idle", float), ("--expect", "expect", str), ("--win", "window", str),
                           ("--th", "th", float), ("--sec", "sec", float), ("--out", "path", str),
                           ("--find", "find", str)):
        v = popopt(argv, opt)
        if v is not None:
            common[key] = conv(v)
    v = popopt(argv, "--region")
    if v:
        common["region"] = [float(x) for x in v.split(",")]
    t = float(popopt(argv, "--timeout", default=60))
    if not argv:
        raise SystemExit("bridgectl: missing command (see --help)")
    cmd, a = argv[0], argv[1:]
    req = {"cmd": cmd, **common}
    if cmd in KINDS:
        req["script"] = read_script(a)
        req["timeout"] = t
    elif cmd in ("type", "paste", "notify"):
        req["text"] = " ".join(a)
    elif cmd == "clip":
        if a:
            req["text"] = " ".join(a)
    elif cmd == "key":
        need(a, 1, "key cmd+shift+g")
        req["key"] = a[0]
    elif cmd in ("click", "dclick", "rclick", "move"):
        need(a, 2, f"{cmd} X Y")
        req.update(x=float(a[0]), y=float(a[1]))
    elif cmd == "drag":
        need(a, 4, "drag X1 Y1 X2 Y2")
        req.update(x=float(a[0]), y=float(a[1]), x2=float(a[2]), y2=float(a[3]))
    elif cmd == "scroll":
        need(a, 1, "scroll DY [DX]")
        req.update(dy=float(a[0]), dx=float(a[1]) if len(a) > 1 else 0)
    elif cmd == "clicktext":
        req["find"] = " ".join(a)
    elif cmd == "wins":
        req["filter"] = " ".join(a)
    elif cmd == "activate":
        req["app"] = " ".join(a)
    elif cmd == "wait":
        need(a, 2, "wait text|gone-text|window|gone-window TARGET")
        req.update(what=a[0], target=" ".join(a[1:]), timeout=t)
    return req, t


# ---------------- seq / recipes ----------------
def load_recipes():
    try:
        with open(RECIPES) as f:
            return json.load(f)
    except Exception:
        return {}


def save_recipes(r):
    tmp = RECIPES + ".tmp"
    with open(tmp, "w") as f:
        json.dump(r, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, RECIPES)


def run_seq(lines, vars_=None, save=None, expect=None, force=False):
    vars_ = vars_ or {}
    raw = [l.rstrip() for l in lines if l.strip() and not l.strip().startswith("#")]
    steps = [re.sub(r"\{(\w+)\}", lambda m: vars_.get(m.group(1), m.group(0)), l) for l in raw]
    log, t0 = [], time.time()
    first_input = True
    for i, line in enumerate(steps):
        opt = line.startswith("?")
        argv = shlex.split(line[1:] if opt else line)
        if argv[0] == "sleep":
            time.sleep(float(argv[1]))
            log.append({"step": i + 1, "ok": True, "line": line})
            continue
        if argv[0] == "expect":
            expect = " ".join(argv[1:])
            log.append({"step": i + 1, "ok": True, "line": line})
            continue
        req, t = build_req(argv)
        if expect and "expect" not in req:
            req["expect"] = expect
        if force:
            req["force"] = True
        if req["cmd"] in INPUT_CMDS:
            if not first_input:
                req["idle"] = 0  # full idle wait only before the first input; STOP/lock/front still checked
            first_input = False
        try:
            r = fast(req, t)
        except Unavailable as e:
            r = {"ok": False, "error": "UNAVAILABLE", "detail": str(e)}
        entry = {"step": i + 1, "ok": r.get("ok"), "line": line, "ms": r.get("ms")}
        if not r.get("ok"):
            entry.update(error=r.get("error"), detail=r.get("detail"))
        if r.get("stdout"):
            entry["stdout"] = r["stdout"][:500]
        if r.get("match"):
            entry["match"] = r["match"]
        log.append(entry)
        if not r.get("ok") and not opt:
            try:
                shot = fast({"cmd": "shot"}, 15)
            except Unavailable:
                shot = {}
            _record(raw, False, r.get("error"), save)
            return {"ok": False, "failedStep": i + 1, "line": line, "error": r.get("error"), "detail": r.get("detail"),
                    "screenshot": shot.get("path"), "steps": log, "sec": round(time.time() - t0, 2)}
    _record(raw, True, None, save)
    return {"ok": True, "steps": log, "sec": round(time.time() - t0, 2)}


def _record(raw, ok, err, save):
    if len(raw) < 3 and not save:
        return
    rec = load_recipes()
    key = save or "auto-" + hashlib.sha1("\n".join(raw).encode()).hexdigest()[:8]
    e = rec.get(key) or {"steps": raw, "ok": 0, "fail": 0, "created": time.strftime("%Y-%m-%d %H:%M")}
    e["ok" if ok else "fail"] += 1
    e["last"] = time.strftime("%Y-%m-%d %H:%M")
    e["lastError"] = err
    rec[key] = e
    save_recipes(rec)


def recipe_cmd(a):
    rec = load_recipes()
    if not a or a[0] == "list":
        for k, v in sorted(rec.items()):
            print(f"{k}\tok={v['ok']} fail={v['fail']} last={v.get('last')}\t{v['steps'][0][:60]} ... ({len(v['steps'])} steps)")
        return EXIT_OK
    op, name = a[0], (a[1] if len(a) > 1 else "")
    if op in ("show", "run", "save") and not name:
        print(f"bridgectl: recipe {op} NAME", file=sys.stderr)
        return EXIT_FAIL
    if op in ("show", "run") and name not in rec:
        print(f"bridgectl: no recipe named '{name}'", file=sys.stderr)
        return EXIT_FAIL
    if op == "show":
        print("\n".join(rec[name]["steps"]))
        return EXIT_OK
    if op == "rm":
        rec.pop(name, None)
        save_recipes(rec)
        return EXIT_OK
    if op == "save":
        rest = a[2:]
        src = popopt(rest, "--from")
        if src not in rec:
            print("bridgectl: recipe save NAME --from EXISTING [k=value ...]", file=sys.stderr)
            return EXIT_FAIL
        vars_ = dict(x.split("=", 1) for x in rest if "=" in x)
        steps = rec[src]["steps"]
        for k, v in vars_.items():  # concrete value -> {placeholder}
            steps = [s.replace(v, "{" + k + "}") for s in steps]
        rec[name] = {"steps": steps, "ok": 0, "fail": 0, "created": time.strftime("%Y-%m-%d %H:%M")}
        save_recipes(rec)
        print("\n".join(steps))
        return EXIT_OK
    if op == "run":
        vars_ = dict(x.split("=", 1) for x in a[2:] if "=" in x)
        res = run_seq(rec[name]["steps"], vars_, save=name)
        print(json.dumps(res, ensure_ascii=False, indent=1))
        return EXIT_OK if res["ok"] else EXIT_FAIL
    print("bridgectl: recipe list|show|run|save|rm", file=sys.stderr)
    return EXIT_FAIL


# ---------------- main ----------------
def print_result(cmd, res, as_json):
    if as_json or (cmd in JSON_CMDS and not (cmd == "ocr" and res.get("text") is not None)):
        print(json.dumps(res, ensure_ascii=False, indent=1))
        return
    out = res.get("stdout")
    if out:
        sys.stdout.write(out if (cmd in KINDS or out.endswith("\n")) else out + "\n")
    if cmd == "ocr" and res.get("text") is not None:
        print(res["text"])
    if res.get("stderr"):
        sys.stderr.write(res["stderr"])
    if res.get("error"):
        detail = f" - {res['detail']}" if res.get("detail") else ""
        sys.stderr.write(f"bridge error: {res['error']}{detail}\n")


EXTERNAL_TOOLS = {
    # Vercel Labs agent tools, run from the bridge context (outside the agent sandbox).
    "desktop": ("AGENT_DESKTOP_BIN", "agent-desktop"),  # accessibility-tree desktop control: snapshot, click @ref
    "browser": ("AGENT_BROWSER_BIN", "agent-browser"),  # CDP browser automation
}


def external_tool(cmd, args, as_json=False):
    """Pass arguments to agent-desktop / agent-browser, executed by the bridge outside the sandbox.

    The agent's own sandbox usually cannot reach Accessibility or launch Chrome; the bridge can.
    Binaries are taken from AGENT_DESKTOP_BIN / AGENT_BROWSER_BIN, else from PATH.
    """
    import unicodedata
    name = {"ad": "desktop", "web": "browser"}.get(cmd, cmd)
    env_var, default_bin = EXTERNAL_TOOLS[name]
    timeout = popopt(args, "--timeout", default=None)
    timeout = int(timeout) if timeout else 90
    binary = os.path.expanduser(os.environ.get(env_var, default_bin))
    args = [unicodedata.normalize("NFC", a) for a in args]  # AX names match in NFC
    if name == "browser" and "--session" not in args and not os.environ.get("AGENT_BROWSER_SESSION"):
        args = ["--session", "aside-bridge"] + args  # dedicated session, not the shared default
    # The shell path may decompose non-ASCII text (NFD); re-normalize right before exec.
    wrap = ("import sys,os,shutil,unicodedata;b=shutil.which(sys.argv[1]) or sys.argv[1];"
            "a=[unicodedata.normalize('NFC',x) for x in sys.argv[2:]];os.execv(b,[b]+a)")
    line = "/usr/bin/python3 -c " + shlex.quote(wrap) + " " + shlex.quote(binary) + " " + " ".join(shlex.quote(a) for a in args)
    try:
        res = fast({"cmd": "sh", "script": line, "timeout": timeout}, timeout + 10)
    except Unavailable:
        res = submit("shell", line, timeout)
    if as_json:
        print(json.dumps(res, ensure_ascii=False))
    else:
        sys.stdout.write(res.get("stdout", ""))
        sys.stderr.write(res.get("stderr", ""))
    return EXIT_OK if res.get("ok") else EXIT_FAIL


def main(argv):
    as_json = popflag(argv, "--json")
    bg = popflag(argv, "--bg")
    legacy = popflag(argv, "--legacy")
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return EXIT_OK
    cmd = argv[0]
    if cmd in ("version", "--version"):
        print(f"bridgectl {VERSION} (home: {BASE})")
        return EXIT_OK
    if cmd == "status":
        st = status()
        try:
            st["daemon"] = dcall({"cmd": "ping"}, 3)
        except Exception as e:
            st["daemon"] = f"down ({e.__class__.__name__})"
        st["home"] = BASE
        print(json.dumps(st, ensure_ascii=False, indent=1))
        return EXIT_OK if st.get("running") else EXIT_UNAVAILABLE
    if cmd == "stop":
        with open(STOPFILE, "w") as f:
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
        return recipe_cmd(argv[1:])
    if cmd in ("desktop", "ad", "browser", "web"):
        return external_tool(cmd, argv[1:], as_json)
    try:
        if cmd == "daemon":
            op = argv[1] if len(argv) > 1 else "status"
            if op in ("stop", "restart"):
                try:
                    dcall({"cmd": "quit"}, 3)
                except Exception:
                    pass
                time.sleep(0.4)
            if op in ("start", "restart"):
                ok = daemon_start()
                print("started" if ok else "FAILED to start worker")
                return EXIT_OK if ok else EXIT_FAIL
            alive = daemon_alive()
            print("alive" if alive else "down")
            return EXIT_OK if alive or op == "stop" else EXIT_FAIL
        if cmd == "seq":
            save = popopt(argv, "--save")
            vars_ = {}
            if "--vars" in argv:
                i = argv.index("--vars")
                vars_ = dict(x.split("=", 1) for x in argv[i + 1:] if "=" in x)
                del argv[i:]
            force = popflag(argv, "--force")
            expect = popopt(argv, "--expect")
            if len(argv) >= 3 and argv[1] == "-f":
                with open(argv[2]) as f:
                    lines = f.read().splitlines()
            elif len(argv) >= 2:
                lines = argv[1:]
            else:
                lines = sys.stdin.read().splitlines()
            res = run_seq(lines, vars_, save, expect, force)
            print(json.dumps(res, ensure_ascii=False, indent=1))
            return EXIT_OK if res["ok"] else EXIT_FAIL

        kind = KINDS.get(cmd)
        if cmd == "quit" or ((legacy or bg) and kind):
            rest = argv[1:]
            timeout = float(popopt(rest, "--timeout", default=60))
            script = read_script(rest) if kind else ""
            res = submit_bg(kind, script, timeout) if (bg and kind) else submit(kind or cmd, script, timeout)
        elif (legacy or bg) and not kind:
            raise SystemExit("bridgectl: --legacy/--bg only apply to as, jxa and sh")
        else:
            req, t = build_req(argv)
            try:
                res = fast(req, t)
            except Unavailable:
                if not kind:
                    raise
                res = submit(kind, req.get("script", ""), t)  # worker down -> folder queue
                res["via"] = "legacy"
    except Unavailable as e:
        res = {"ok": False, "error": "UNAVAILABLE", "detail": str(e)}
        print_result(cmd, res, as_json)
        return EXIT_UNAVAILABLE
    print_result(cmd, res, as_json)
    return EXIT_OK if res.get("ok") else EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
