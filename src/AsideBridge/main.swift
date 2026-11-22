// AsideBridge - the "bridge" process.
//
// Runs AppleScript / JXA / shell jobs that a sandboxed AI agent (for example the
// Aside browser's agent) drops into a folder queue, from OUTSIDE the sandbox.
// Child processes inherit this app's TCC identity, so Accessibility, Automation
// and Screen Recording are granted once to "AsideBridge" instead of to every tool.
//
// It also starts the resident fast worker (AsideBridgeWorker / bridged) on demand,
// which then inherits the same grants. See docs/architecture.md.
//
// Unofficial community tool. Not affiliated with At Your Side Inc. / Aside.

import Cocoa
import ApplicationServices
import Darwin

let VERSION = "0.1.0"
let DEFAULT_LABEL = "io.github.jay-jeongyun.asidebridge"
let LABEL = Bundle.main.bundleIdentifier ?? DEFAULT_LABEL
let HOMEDIR = NSHomeDirectory()

/// Data directory: $ASIDEBRIDGE_HOME, otherwise ~/.asidebridge
let BASE: String = {
    if let e = ProcessInfo.processInfo.environment["ASIDEBRIDGE_HOME"], !e.isEmpty {
        return (e as NSString).expandingTildeInPath
    }
    return HOMEDIR + "/.asidebridge"
}()
let INBOX = BASE + "/inbox"
let OUTBOX = BASE + "/outbox"
let WORK = BASE + "/work"
let LOGDIR = BASE + "/logs"
let LOGFILE = LOGDIR + "/bridge.log"
let TOKENFILE = BASE + "/token"
let STOPFILE = BASE + "/STOP"
let STATUSFILE = BASE + "/status.json"
let LOCKFILE = BASE + "/bridge.lock"
let PLIST = HOMEDIR + "/Library/LaunchAgents/" + LABEL + ".plist"
let MAX_OUT = 1_000_000
let MAX_TIMEOUT = 900.0

let fm = FileManager.default
let isoFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func now() -> String { isoFmt.string(from: Date()) }

func log(_ msg: String) {
    let line = "\(now()) [\(getpid())] \(msg)\n"
    if let h = FileHandle(forWritingAtPath: LOGFILE) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        h.closeFile()
    } else {
        fm.createFile(atPath: LOGFILE, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
    }
}

func ensureDirs() {
    for d in [BASE, INBOX, OUTBOX, WORK, LOGDIR] {
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: nil)
        chmod(d, 0o700)
    }
}

/// 48 hex chars from SecRandomCopyBytes, stored with mode 0600.
func loadOrCreateToken() -> String {
    if let t = try? String(contentsOfFile: TOKENFILE, encoding: .utf8) {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 16 { return s }
    }
    var bytes = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let tok = bytes.map { String(format: "%02x", $0) }.joined()
    fm.createFile(atPath: TOKENFILE, contents: Data(tok.utf8), attributes: [.posixPermissions: 0o600])
    chmod(TOKENFILE, 0o600)
    return tok
}

struct RunResult { var code: Int32; var out: String; var err: String; var timedOut: Bool }

final class Box<T> { var v: T; init(_ v: T) { self.v = v } }

func childEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOME"] = HOMEDIR
    env["ASIDEBRIDGE_HOME"] = BASE
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    return env
}

func runProcess(_ path: String, _ args: [String], timeout: Double) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = childEnvironment()
    p.currentDirectoryURL = URL(fileURLWithPath: WORK)
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = FileHandle.nullDevice
    let outBox = Box(Data()), errBox = Box(Data())
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outBox.v = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errBox.v = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    do { try p.run() } catch {
        return RunResult(code: -1, out: "", err: "spawn failed: \(error)", timedOut: false)
    }
    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while p.isRunning {
        if Date() > deadline {
            timedOut = true
            p.terminate()
            usleep(500_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            break
        }
        usleep(50_000)
    }
    p.waitUntilExit()
    _ = group.wait(timeout: .now() + 5)
    func clip(_ d: Data) -> String {
        let s = String(decoding: d.prefix(MAX_OUT), as: UTF8.self)
        return d.count > MAX_OUT ? s + "\n...[truncated \(d.count - MAX_OUT) bytes]" : s
    }
    return RunResult(code: p.terminationStatus, out: clip(outBox.v), err: clip(errBox.v), timedOut: timedOut)
}

var jobsDone = 0
var token = ""
let startedAt = now()
let launchedBy = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "manual"
let jobQueue = DispatchQueue(label: "asidebridge.jobs")
var busy = false

func writeJSONAtomic(_ obj: [String: Any], to path: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    let tmp = path + ".tmp"
    fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
    _ = rename(tmp, path)
}

/// Heartbeat read by the CLI: running == heartbeat younger than 20 s.
func writeStatus() {
    writeJSONAtomic([
        "pid": Int(getpid()),
        "version": VERSION,
        "startedAt": startedAt,
        "heartbeat": now(),
        "heartbeatEpoch": Date().timeIntervalSince1970,
        "launchedBy": launchedBy,
        "axTrusted": AXIsProcessTrusted(),
        "paused": fm.fileExists(atPath: STOPFILE),
        "jobsDone": jobsDone,
        "busy": busy,
    ], to: STATUSFILE)
}

func processJob(file: String) {
    let name = (file as NSString).lastPathComponent
    let claimed = WORK + "/" + name + ".processing"
    guard rename(file, claimed) == 0 else { return }
    let t0 = Date()
    var result: [String: Any] = ["startedAt": now()]
    var jobId = (name as NSString).deletingPathExtension
    defer {
        result["id"] = jobId
        result["finishedAt"] = now()
        result["durationMs"] = Int(Date().timeIntervalSince(t0) * 1000)
        writeJSONAtomic(result, to: OUTBOX + "/" + jobId + ".json")
        try? fm.removeItem(atPath: claimed)
        jobsDone += 1
    }
    guard let data = fm.contents(atPath: claimed),
          let job = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        result["ok"] = false; result["error"] = "invalid job json"; log("job \(jobId): invalid json"); return
    }
    if let i = job["id"] as? String, i.range(of: "^[A-Za-z0-9._-]{1,120}$", options: .regularExpression) != nil { jobId = i }
    guard (job["token"] as? String) == token else {
        result["ok"] = false; result["error"] = "bad token"; log("job \(jobId): REJECTED bad token"); return
    }
    let kind = (job["kind"] as? String) ?? "applescript"
    let script = (job["script"] as? String) ?? ""
    let timeout = min(max((job["timeout"] as? Double) ?? 60, 1), MAX_TIMEOUT)
    let preview = script.replacingOccurrences(of: "\n", with: " ").prefix(160)
    log("job \(jobId) kind=\(kind) timeout=\(Int(timeout)) script=\(preview)")
    switch kind {
    case "ping":
        result["ok"] = true; result["stdout"] = "pong"; result["axTrusted"] = AXIsProcessTrusted()
        result["version"] = VERSION; result["pid"] = Int(getpid()); result["launchedBy"] = launchedBy
        return
    case "quit":
        // Exit after writing the result; launchd (KeepAlive) restarts a fresh instance.
        result["ok"] = true; result["stdout"] = "quitting pid \(getpid())"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { log("quit job received; exiting"); exit(0) }
        return
    case "applescript", "jxa", "shell":
        break
    default:
        result["ok"] = false; result["error"] = "unknown kind '\(kind)' (expected applescript|jxa|shell|ping|quit)"; return
    }
    let ext = kind == "shell" ? "sh" : (kind == "jxa" ? "js" : "applescript")
    let scriptPath = WORK + "/" + jobId + "." + ext
    fm.createFile(atPath: scriptPath, contents: Data(script.utf8), attributes: [.posixPermissions: 0o600])
    defer { try? fm.removeItem(atPath: scriptPath) }
    let r: RunResult
    switch kind {
    case "jxa": r = runProcess("/usr/bin/osascript", ["-l", "JavaScript", scriptPath], timeout: timeout)
    case "shell": r = runProcess("/bin/zsh", [scriptPath], timeout: timeout)
    default: r = runProcess("/usr/bin/osascript", [scriptPath], timeout: timeout)
    }
    result["ok"] = (r.code == 0 && !r.timedOut)
    result["exitCode"] = Int(r.code)
    result["stdout"] = r.out
    result["stderr"] = r.err
    result["timedOut"] = r.timedOut
    log("job \(jobId) done code=\(r.code) timedOut=\(r.timedOut) ms=\(Int(Date().timeIntervalSince(t0) * 1000)) err=\(r.err.prefix(200).replacingOccurrences(of: "\n", with: " "))")
}

func scanInbox() {
    if busy || fm.fileExists(atPath: STOPFILE) { return }
    guard let items = try? fm.contentsOfDirectory(atPath: INBOX) else { return }
    let jobs = items.filter { $0.hasSuffix(".json") }.sorted()
    if jobs.isEmpty { return }
    busy = true
    jobQueue.async {
        for j in jobs { processJob(file: INBOX + "/" + j) }
        DispatchQueue.main.async { busy = false; writeStatus() }
    }
}

/// Remove results and leftovers older than 2 days.
func cleanup() {
    for dir in [OUTBOX, WORK] {
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for it in items {
            let p = dir + "/" + it
            if let a = try? fm.attributesOfItem(atPath: p), let m = a[.modificationDate] as? Date,
               Date().timeIntervalSince(m) > 2 * 86400 { try? fm.removeItem(atPath: p) }
        }
    }
}

func launchctl(_ args: [String]) -> RunResult { runProcess("/bin/launchctl", args, timeout: 15) }

func alert(_ title: String, _ text: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.addButton(withTitle: "OK")
    a.runModal()
}

// ---------------- main ----------------
let args = CommandLine.arguments
if args.contains("--version") { print("AsideBridge \(VERSION)"); exit(0) }
if args.contains("--help") || args.contains("-h") {
    print("""
    AsideBridge \(VERSION) - run AppleScript/JXA/shell jobs for a sandboxed agent, outside the sandbox.
    Usually started by launchd (see scripts/install.sh). Options:
      --foreground            run in this process even if a LaunchAgent is installed
      --selftest-seconds N    headless queue test (no UI), exit after N seconds
      --version
    Data dir: $ASIDEBRIDGE_HOME or ~/.asidebridge  (now: \(BASE))
    """)
    exit(0)
}

ensureDirs()
let uid = getuid()
var selftestSeconds: Double = 0
if let i = args.firstIndex(of: "--selftest-seconds"), i + 1 < args.count {
    selftestSeconds = Double(args[i + 1]) ?? 0
}

// Started by hand (Finder double-click): hand over to launchd so it survives logout / crashes.
if launchedBy != LABEL && fm.fileExists(atPath: PLIST) && !args.contains("--foreground") && selftestSeconds == 0 {
    let loaded = launchctl(["print", "gui/\(uid)/\(LABEL)"]).code == 0
    if !loaded {
        let r = launchctl(["bootstrap", "gui/\(uid)", PLIST])
        log("manual launch: bootstrap \(PLIST) -> code=\(r.code) err=\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        if r.code == 0 {
            alert("AsideBridge installed",
                  "AsideBridge is now registered as a background service.\n\nPlease allow the permission prompts that follow (Accessibility, Automation).\nSystem Settings > Privacy & Security > Accessibility > AsideBridge.")
            exit(0)
        }
    } else {
        _ = launchctl(["kickstart", "gui/\(uid)/\(LABEL)"])
        log("manual launch: service already loaded; kickstarted and exiting")
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        alert("AsideBridge is running",
              trusted ? "Already running in the background, and Accessibility access is granted."
                      : "Running in the background, but Accessibility access is missing.\nSystem Settings > Privacy & Security > Accessibility > enable AsideBridge.")
        exit(0)
    }
}

// Single instance per data directory.
let lockFd = open(LOCKFILE, O_CREAT | O_RDWR, 0o600)
if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
    log("another instance holds the lock; exiting")
    exit(0)
}

token = loadOrCreateToken()
log("AsideBridge \(VERSION) started (launchedBy=\(launchedBy), axTrusted=\(AXIsProcessTrusted()), home=\(BASE))")

if selftestSeconds > 0 {
    // Headless pipeline test (no WindowServer / NSApplication). Useful in CI or from a sandbox.
    log("selftest mode: exiting in \(Int(selftestSeconds))s")
    writeStatus()
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in scanInbox() }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in writeStatus() }
    DispatchQueue.main.asyncAfter(deadline: .now() + selftestSeconds) { log("selftest done; exiting"); exit(0) }
    RunLoop.main.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Ask for Accessibility once per start if missing (the system shows its own dialog).
if !AXIsProcessTrusted() {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
}
// Trigger the Automation (System Events) consent prompt early, off the main thread.
DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
    let r = runProcess("/usr/bin/osascript", ["-e", "tell application \"System Events\" to return name of first application process whose frontmost is true"], timeout: 120)
    log("automation probe (System Events): code=\(r.code) out=\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) err=\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
}

writeStatus()
cleanup()
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in scanInbox() }
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in writeStatus() }
Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in cleanup() }
app.run()
