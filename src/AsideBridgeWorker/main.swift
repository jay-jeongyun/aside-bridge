// AsideBridgeWorker (`bridged`) - resident fast worker for AsideBridge.
//
// Started BY AsideBridge, so it inherits its TCC grants (Accessibility, Screen Recording,
// Automation). Listens on a unix socket: one JSON request per connection, one JSON reply.
// Rebuilding this binary does NOT touch AsideBridge.app's signature or grants.
// Shows a small menu bar pill: red = controlling the screen, blue = background job,
// orange = paused (STOP file), gray = idle. Clicking it offers STOP / Resume.
//
// Unofficial community tool. Not affiliated with At Your Side Inc. / Aside.
import Cocoa
import CoreGraphics
import Carbon
import IOKit
import Vision
import Darwin

let VERSION = "0.1.0"
let HOMEDIR = NSHomeDirectory()
let ENV = ProcessInfo.processInfo.environment
/// Data directory: $ASIDEBRIDGE_HOME, otherwise ~/.asidebridge (must match the bridge and the CLI).
let BASE: String = {
    if let e = ENV["ASIDEBRIDGE_HOME"], !e.isEmpty { return (e as NSString).expandingTildeInPath }
    return HOMEDIR + "/.asidebridge"
}()
/// OCR languages, comma separated BCP-47 tags. Default: English + Korean.
let OCR_LANGS: [String] = (ENV["ASIDEBRIDGE_OCR_LANGS"] ?? "en-US,ko-KR")
    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
let HEADLESS = CommandLine.arguments.contains("--headless")
let RUN = BASE + "/run"
let SOCK = RUN + "/bridged.sock"
let STOPFILE = BASE + "/STOP"
let SHOTS = BASE + "/work/shots"
let LOGF = BASE + "/logs/bridged.log"
let fm = FileManager.default
var TOKEN = ""
var lastSelfInput: Double = 0      // epoch of our last synthetic input
var activeJobs = 0
let stateLock = NSLock()

func nowEpoch() -> Double { Date().timeIntervalSince1970 }
func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: LOGF) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { fm.createFile(atPath: LOGF, contents: line.data(using: .utf8)) }
}

// ---------- process ----------
struct PR { var code: Int32; var out: String; var err: String; var timedOut: Bool }
func run(_ path: String, _ args: [String], timeout: Double = 60, stdin: String? = nil) -> PR {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOME"] = HOMEDIR; env["ASIDEBRIDGE_HOME"] = BASE
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: BASE + "/work")
    let o = Pipe(), e = Pipe(), i = Pipe()
    p.standardOutput = o; p.standardError = e; p.standardInput = stdin == nil ? FileHandle.nullDevice : i
    var od = Data(), ed = Data(); let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { od = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    g.enter(); DispatchQueue.global().async { ed = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    do { try p.run() } catch { return PR(code: -1, out: "", err: "spawn failed: \(error)", timedOut: false) }
    if let s = stdin { i.fileHandleForWriting.write(s.data(using: .utf8)!); try? i.fileHandleForWriting.close() }
    let dl = Date().addingTimeInterval(timeout); var to = false
    while p.isRunning { if Date() > dl { to = true; p.terminate(); usleep(300_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) }; break }; usleep(5_000) }
    p.waitUntilExit(); _ = g.wait(timeout: .now() + 3)
    return PR(code: p.terminationStatus, out: String(decoding: od.prefix(2_000_000), as: UTF8.self),
              err: String(decoding: ed.prefix(200_000), as: UTF8.self), timedOut: to)
}

// ---------- system state ----------
func hidIdle() -> Double {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    defer { IOObjectRelease(svc) }
    if let v = IORegistryEntryCreateCFProperty(svc, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
        return v.doubleValue / 1_000_000_000
    }
    return 999
}
// user idle seconds, ignoring our own synthetic input
func userIdle() -> Double {
    let idle = hidIdle()
    let sinceSelf = nowEpoch() - lastSelfInput
    // if the last HID activity coincides with our own input, count from before it
    if idle <= sinceSelf + 0.6 && sinceSelf < 60 && abs(idle - sinceSelf) < 0.6 { return 999 }
    return idle
}
func screenLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}
func frontApp() -> [String: Any] {
    var r: [String: Any] = [:]
    DispatchQueue.main.sync {
        if let a = NSWorkspace.shared.frontmostApplication {
            r = ["name": a.localizedName ?? "", "bundle": a.bundleIdentifier ?? "", "pid": Int(a.processIdentifier)]
        }
    }
    return r
}
func notify(_ msg: String) {
    _ = run("/usr/bin/osascript", ["-e", "display notification \"\(msg.replacingOccurrences(of: "\"", with: "'"))\" with title \"AsideBridge\""], timeout: 5)
}

struct GuardErr: Error { let code: String; let msg: String }
// Mandatory guard for every input action: STOP file, lock screen, user idle, expected front app.
func guardInput(_ req: [String: Any]) throws {
    if (req["force"] as? Bool) == true { return }
    if fm.fileExists(atPath: STOPFILE) { throw GuardErr(code: "STOPPED", msg: "STOP file present (user pause)") }
    if screenLocked() { throw GuardErr(code: "LOCKED", msg: "screen is locked; input impossible") }
    let need = (req["idle"] as? Double) ?? 3
    var waited = 0.0, notified = false
    let maxWait = (req["idleWait"] as? Double) ?? 20
    while userIdle() < need {
        if !notified { notified = true; DispatchQueue.global().async { notify("You are using the Mac. The agent will continue when you pause.") } }
        if waited >= maxWait { throw GuardErr(code: "USER_ACTIVE", msg: "user active for \(Int(maxWait))s; aborted") }
        if fm.fileExists(atPath: STOPFILE) { throw GuardErr(code: "STOPPED", msg: "STOP file present") }
        usleep(250_000); waited += 0.25
    }
    if let exp = req["expect"] as? String, !exp.isEmpty {
        let f = frontApp()
        let n = (f["name"] as? String ?? ""), b = (f["bundle"] as? String ?? "")
        if !(n.localizedCaseInsensitiveContains(exp) || b.localizedCaseInsensitiveContains(exp)) {
            throw GuardErr(code: "FRONT_CHANGED", msg: "front app is '\(n)' (\(b)), expected '\(exp)'")
        }
    }
}

// ---------- input ----------
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); lastSelfInput = nowEpoch() }
func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks); post(e)
}
let KEYS: [String: CGKeyCode] = [
    "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
    "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,
    "i":34,"p":35,"enter":36,"return":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,
    "tab":48,"space":49,"`":50,"delete":51,"backspace":51,"esc":53,"escape":53,"fwddelete":117,"home":115,"end":119,
    "pageup":116,"pagedown":121,"left":123,"right":124,"down":125,"up":126,
    "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111]
func keyCombo(_ combo: String) throws {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    var flags: CGEventFlags = []
    var key: CGKeyCode? = nil
    for p in parts {
        switch p {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: key = KEYS[p]; if key == nil { throw GuardErr(code: "BAD_KEY", msg: "unknown key \(p)") }
        }
    }
    guard let k = key else { throw GuardErr(code: "BAD_KEY", msg: "no key in \(combo)") }
    let d = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true); d?.flags = flags
    let u = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false); u?.flags = flags
    post(d); usleep(8_000); post(u)
}
func typeText(_ text: String) {
    let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    var switched = false
    if let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: "com.apple.keylayout.ABC"] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource], let abc = list.first {
        TISSelectInputSource(abc); switched = true; usleep(80_000)
    }
    for ch in text {
        if ch == "\n" { try? keyCombo("enter"); usleep(15_000); continue }
        let u = Array(String(ch).utf16)
        let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        d?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u); up?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        post(d); post(up); usleep(8_000)
    }
    if switched { usleep(60_000); TISSelectInputSource(cur) }
}
func clipGet() -> String { var s = ""; DispatchQueue.main.sync { s = NSPasteboard.general.string(forType: .string) ?? "" }; return s }
func clipSet(_ s: String) { DispatchQueue.main.sync { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) } }
func paste(_ text: String, restore: Bool) throws {
    let old = clipGet(); clipSet(text); usleep(40_000)
    try keyCombo("cmd+v")
    if restore { usleep(350_000); clipSet(old) }
}

// ---------- windows / capture / OCR ----------
func windows(_ filter: String?) -> [[String: Any]] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var out: [[String: Any]] = []
    for w in list {
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        if layer != 0 { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let name = w[kCGWindowName as String] as? String ?? ""
        if let f = filter, !f.isEmpty, !(owner.localizedCaseInsensitiveContains(f) || name.localizedCaseInsensitiveContains(f)) { continue }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        out.append(["id": w[kCGWindowNumber as String] as? Int ?? 0, "app": owner, "title": name,
                    "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0,
                    "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0])
    }
    return out
}
// returns (path, originX, originY, widthPts)
func shot(window: String?, region: [Double]?, path: String?) throws -> (String, Double, Double, Double) {
    try? fm.createDirectory(atPath: SHOTS, withIntermediateDirectories: true)
    let p = path ?? "\(SHOTS)/\(Int(nowEpoch()*1000)).png"
    var args = ["-x", "-t", p.hasSuffix(".jpg") ? "jpg" : "png"]
    var ox = 0.0, oy = 0.0, wpts = 0.0
    if let w = window, !w.isEmpty {
        let ws = windows(nil)
        let m = Int(w).flatMap { id in ws.first { ($0["id"] as! Int) == id } } ?? windows(w).first
        guard let win = m else { throw GuardErr(code: "NO_WINDOW", msg: "window '\(w)' not found") }
        args += ["-o", "-l", "\(win["id"] as! Int)"]
        ox = win["x"] as! Double; oy = win["y"] as! Double; wpts = win["w"] as! Double
    } else if let r = region, r.count == 4 {
        args += ["-R", r.map { String(Int($0)) }.joined(separator: ",")]
        ox = r[0]; oy = r[1]; wpts = r[2]
    } else {
        args += ["-m"]; wpts = Double(CGDisplayBounds(CGMainDisplayID()).width)
    }
    let r = run("/usr/sbin/screencapture", args + [p], timeout: 15)
    if r.code != 0 || !fm.fileExists(atPath: p) { throw GuardErr(code: "SHOT_FAILED", msg: r.err) }
    return (p, ox, oy, wpts)
}
func ocr(_ path: String, ox: Double, oy: Double, wpts: Double, fast: Bool) throws -> [[String: Any]] {
    guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw GuardErr(code: "BAD_IMAGE", msg: path) }
    let W = Double(cg.width), H = Double(cg.height)
    let scale = wpts > 0 ? W / wpts : 2
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate  // .fast is Latin-only (garbles Hangul)
    req.recognitionLanguages = OCR_LANGS
    req.usesLanguageCorrection = !fast
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    var out: [[String: Any]] = []
    for o in req.results ?? [] {
        guard let c = o.topCandidates(1).first else { continue }
        let bb = o.boundingBox
        let x = bb.minX * W / scale + ox, y = (1 - bb.maxY) * H / scale + oy
        let w = bb.width * W / scale, h = bb.height * H / scale
        out.append(["text": c.string, "conf": Double(c.confidence), "x": Int(x), "y": Int(y), "w": Int(w), "h": Int(h),
                    "cx": Int(x + w/2), "cy": Int(y + h/2)])
    }
    return out
}
// OCR-tolerant similarity: LCS ratio on whitespace-stripped strings (substring-aware)
func lcs(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty || b.isEmpty { return 0 }
    var prev = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count { var cur = [Int](repeating: 0, count: b.count + 1)
        for j in 1...b.count { cur[j] = a[i-1] == b[j-1] ? prev[j-1] + 1 : max(prev[j], cur[j-1]) }
        prev = cur }
    return prev[b.count]
}
func norm(_ s: String) -> [Character] { Array(s.lowercased().filter { !$0.isWhitespace }) }
func sim(_ needle: String, _ hay: String) -> Double {
    let n = norm(needle), h = norm(hay)
    if n.isEmpty { return 0 }
    if String(h).contains(String(n)) { return 1 }
    return Double(lcs(n, h)) / Double(n.count) * (h.count >= n.count ? 1 : Double(h.count) / Double(n.count))
}
func findText(_ needle: String, _ items: [[String: Any]], th: Double) -> [String: Any]? {
    var best: [String: Any]? = nil; var bs = 0.0
    for it in items { let s = sim(needle, it["text"] as! String); if s > bs { bs = s; best = it } }
    if bs >= th, var b = best { b["score"] = bs; return b }
    return nil
}

// ---------- sysinfo ----------
func sysinfo() -> [String: Any] {
    func sh(_ c: String) -> String { run("/bin/zsh", ["-c", c], timeout: 8).out.trimmingCharacters(in: .whitespacesAndNewlines) }
    return ["battery": sh("pmset -g batt | tail -n +2"), "power": sh("pmset -g ps | head -1"),
            "wifi": sh("ipconfig getsummary en0 2>/dev/null | awk -F' : ' '/ SSID/{print $2;exit}'"),
            "idleSec": hidIdle(), "locked": screenLocked(), "front": frontApp(),
            "disk": sh("df -h / | tail -1"), "uptime": sh("uptime"),
            "displays": sh("system_profiler SPDisplaysDataType 2>/dev/null | awk '/Resolution/{print $2\"x\"$4}'")]
}

// ---------- menu bar indicator ----------
// red = screen control (input/shot/ocr/wait), blue = background job (as/jxa/sh/sysinfo),
// orange = paused (STOP file), gray outline = idle.
var statusItem: NSStatusItem?
var screenJobs = 0, bgJobs = 0
func pillImage(_ text: String, _ color: NSColor, filled: Bool) -> NSImage {
    let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: filled ? NSColor.white : color]
    let ts = (text as NSString).size(withAttributes: attrs)
    let size = NSSize(width: ceil(ts.width) + 16, height: 20)
    return NSImage(size: size, flipped: false) { r in
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
        if filled { color.setFill(); path.fill() } else { path.lineWidth = 1.2; color.setStroke(); path.stroke() }
        (text as NSString).draw(at: NSPoint(x: 8, y: (r.height - ts.height) / 2), withAttributes: attrs)
        return true
    }
}
var lastPill = ""
func setIndicator(_ on: Bool) {
    DispatchQueue.main.async {
        let paused = fm.fileExists(atPath: STOPFILE)
        stateLock.lock(); let sj = screenJobs, bj = bgJobs; stateLock.unlock()
        let (key, text, color, filled): (String, String, NSColor, Bool) =
            paused ? ("p", "⏸ Bridge", .systemOrange, true) :
            sj > 0 ? ("s", "● Bridge", .systemRed, true) :
            bj > 0 ? ("b", "● Bridge", .systemBlue, true) :
                     ("i", "Bridge", .secondaryLabelColor, false)
        guard !HEADLESS, let b = statusItem?.button, key != lastPill else { return }
        lastPill = key
        b.title = ""; b.image = pillImage(text, color, filled: filled); b.imagePosition = .imageOnly
        b.toolTip = paused ? "AsideBridge paused (STOP file present)" : sj > 0 ? "AsideBridge is controlling the screen" : bj > 0 ? "AsideBridge background job running" : "AsideBridge idle"
    }
}
final class MenuTarget: NSObject {
    @objc func stop() { fm.createFile(atPath: STOPFILE, contents: Data("stopped from menu bar \(Date())".utf8)); setIndicator(false) }
    @objc func resume() { try? fm.removeItem(atPath: STOPFILE); setIndicator(false) }
}
let menuTarget = MenuTarget()

// ---------- dispatch ----------
func handle(_ req: [String: Any]) -> [String: Any] {
    let cmd = req["cmd"] as? String ?? ""
    let inputCmds: Set<String> = ["type", "paste", "key", "click", "dclick", "rclick", "drag", "scroll", "move", "clicktext"]
    do {
        if inputCmds.contains(cmd) { try guardInput(req) }
        switch cmd {
        case "ping": return ["ok": true, "stdout": "pong", "version": VERSION, "pid": Int(getpid()), "axTrusted": AXIsProcessTrusted()]
        case "as", "jxa":
            let src = req["script"] as? String ?? ""
            let args = cmd == "jxa" ? ["-l", "JavaScript", "-"] : ["-"]
            let r = run("/usr/bin/osascript", args, timeout: req["timeout"] as? Double ?? 60, stdin: src)
            return ["ok": r.code == 0 && !r.timedOut, "exitCode": Int(r.code), "stdout": r.out, "stderr": r.err, "timedOut": r.timedOut]
        case "sh":
            let r = run("/bin/zsh", ["-c", req["script"] as? String ?? ""], timeout: req["timeout"] as? Double ?? 60)
            return ["ok": r.code == 0 && !r.timedOut, "exitCode": Int(r.code), "stdout": r.out, "stderr": r.err, "timedOut": r.timedOut]
        case "type": typeText(req["text"] as? String ?? ""); return ["ok": true]
        case "paste": try paste(req["text"] as? String ?? "", restore: (req["restore"] as? Bool) ?? true); return ["ok": true]
        case "key": try keyCombo(req["key"] as? String ?? ""); return ["ok": true]
        case "click", "dclick", "rclick", "move":
            let p = CGPoint(x: req["x"] as? Double ?? 0, y: req["y"] as? Double ?? 0)
            mouse(.mouseMoved, p); usleep(30_000)
            if cmd == "click" { mouse(.leftMouseDown, p); mouse(.leftMouseUp, p) }
            if cmd == "rclick" { mouse(.rightMouseDown, p, .right); mouse(.rightMouseUp, p, .right) }
            if cmd == "dclick" { mouse(.leftMouseDown, p); mouse(.leftMouseUp, p); usleep(50_000); mouse(.leftMouseDown, p, clicks: 2); mouse(.leftMouseUp, p, clicks: 2) }
            return ["ok": true]
        case "drag":
            let p1 = CGPoint(x: req["x"] as? Double ?? 0, y: req["y"] as? Double ?? 0), p2 = CGPoint(x: req["x2"] as? Double ?? 0, y: req["y2"] as? Double ?? 0)
            mouse(.mouseMoved, p1); usleep(50_000); mouse(.leftMouseDown, p1)
            for i in 1...20 { let t = Double(i)/20; mouse(.leftMouseDragged, CGPoint(x: p1.x+(p2.x-p1.x)*t, y: p1.y+(p2.y-p1.y)*t)); usleep(12_000) }
            mouse(.leftMouseUp, p2); return ["ok": true]
        case "scroll":
            post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(req["dy"] as? Double ?? 0), wheel2: Int32(req["dx"] as? Double ?? 0), wheel3: 0))
            return ["ok": true]
        case "clip":
            if let s = req["text"] as? String { clipSet(s); return ["ok": true] }
            return ["ok": true, "stdout": clipGet()]
        case "front": return ["ok": true, "front": frontApp()]
        case "idle": return ["ok": true, "idleSec": hidIdle(), "userIdleSec": userIdle(), "locked": screenLocked()]
        case "wins": return ["ok": true, "windows": windows(req["filter"] as? String)]
        case "shot":
            let s = try shot(window: req["window"] as? String, region: req["region"] as? [Double], path: req["path"] as? String)
            return ["ok": true, "path": s.0, "origin": [s.1, s.2]]
        case "ocr":
            let s = try shot(window: req["window"] as? String, region: req["region"] as? [Double], path: nil)
            let items = try ocr(s.0, ox: s.1, oy: s.2, wpts: s.3, fast: (req["fast"] as? Bool) ?? false)
            if (req["keep"] as? Bool) != true { try? fm.removeItem(atPath: s.0) }
            if let f = req["find"] as? String {
                if let m = findText(f, items, th: req["th"] as? Double ?? 0.75) { return ["ok": true, "match": m] }
                return ["ok": false, "error": "NOT_FOUND", "texts": items.map { $0["text"]! }]
            }
            return ["ok": true, "items": items, "text": items.map { $0["text"] as! String }.joined(separator: "\n")]
        case "clicktext":
            let s = try shot(window: req["window"] as? String, region: req["region"] as? [Double], path: nil)
            let items = try ocr(s.0, ox: s.1, oy: s.2, wpts: s.3, fast: false); try? fm.removeItem(atPath: s.0)
            guard let m = findText(req["find"] as? String ?? "", items, th: req["th"] as? Double ?? 0.75) else {
                return ["ok": false, "error": "NOT_FOUND", "texts": items.map { $0["text"]! }] }
            let p = CGPoint(x: Double(m["cx"] as! Int), y: Double(m["cy"] as! Int))
            mouse(.mouseMoved, p); usleep(30_000); mouse(.leftMouseDown, p); mouse(.leftMouseUp, p)
            return ["ok": true, "match": m]
        case "wait":
            // what: window|text|gone-window|gone-text ; target ; timeout
            let what = req["what"] as? String ?? "text", target = req["target"] as? String ?? ""
            let dl = nowEpoch() + (req["timeout"] as? Double ?? 10)
            while nowEpoch() < dl {
                if fm.fileExists(atPath: STOPFILE) { return ["ok": false, "error": "STOPPED"] }
                switch what {
                case "window", "gone-window":
                    let found = !windows(target).isEmpty
                    if found == (what == "window") { return ["ok": true] }
                    usleep(100_000)
                default:
                    let s = try shot(window: req["window"] as? String, region: req["region"] as? [Double], path: nil)
                    let items = try ocr(s.0, ox: s.1, oy: s.2, wpts: s.3, fast: false); try? fm.removeItem(atPath: s.0)
                    let m = findText(target, items, th: req["th"] as? Double ?? 0.75)
                    if (m != nil) == (what == "text") { return ["ok": true, "match": m ?? [:]] }
                    usleep(250_000)
                }
            }
            return ["ok": false, "error": "WAIT_TIMEOUT"]
        case "watch":
            // percent of changed pixels in a region over `sec`
            let r = req["region"] as? [Double], w = req["window"] as? String
            func thumb() throws -> [UInt8] {
                let s = try shot(window: w, region: r, path: nil); defer { try? fm.removeItem(atPath: s.0) }
                guard let img = NSImage(contentsOfFile: s.0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
                var buf = [UInt8](repeating: 0, count: 64*64*4)
                let ctx = CGContext(data: &buf, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: 64, height: 64)); return buf
            }
            let a = try thumb(); usleep(UInt32((req["sec"] as? Double ?? 1) * 1_000_000)); let b = try thumb()
            var diff = 0
            for i in stride(from: 0, to: min(a.count, b.count), by: 4) where abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i+1]) - Int(b[i+1])) + abs(Int(a[i+2]) - Int(b[i+2])) > 30 { diff += 1 }
            return ["ok": true, "changedPct": Double(diff) / 40.96]
        case "activate":
            let r = run("/usr/bin/open", ["-a", req["app"] as? String ?? ""], timeout: 15)
            return ["ok": r.code == 0, "stderr": r.err]
        case "notify": notify(req["text"] as? String ?? ""); return ["ok": true]
        case "sysinfo": var s = sysinfo(); s["ok"] = true; return s
        case "quit": DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }; return ["ok": true]
        default: return ["ok": false, "error": "unknown cmd \(cmd)"]
        }
    } catch let g as GuardErr { return ["ok": false, "error": g.code, "detail": g.msg] }
    catch { return ["ok": false, "error": "\(error)"] }
}

// ---------- socket server ----------
func serve() {
    unlink(SOCK)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in SOCK.withCString { strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), $0, 103) } }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }) == 0 else { log("bind failed \(errno)"); exit(1) }
    chmod(SOCK, 0o600); listen(fd, 32)
    log("bridged \(VERSION) listening pid=\(getpid()) ax=\(AXIsProcessTrusted())")
    while true {
        let c = accept(fd, nil, nil); if c < 0 { continue }
        DispatchQueue.global().async {
            var data = Data(); var buf = [UInt8](repeating: 0, count: 65536)
            while true { let n = read(c, &buf, buf.count); if n <= 0 { break }; data.append(buf, count: n); if buf[n-1] == 10 { break } }
            var resp: [String: Any]
            let t0 = nowEpoch()
            if let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if (req["token"] as? String) != TOKEN { resp = ["ok": false, "error": "bad token"] }
                else {
                    let cmd = req["cmd"] as? String ?? ""
                    let screenCmds: Set<String> = ["type","paste","key","click","dclick","rclick","move","drag","scroll","clicktext","shot","ocr","wait","watch","activate"]
                    let quiet: Set<String> = ["ping","idle","front","wins","clip","quit"]
                    let isScreen = screenCmds.contains(cmd), isBg = !isScreen && !quiet.contains(cmd)
                    if isScreen || isBg { stateLock.lock(); if isScreen { screenJobs += 1 } else { bgJobs += 1 }; stateLock.unlock(); setIndicator(true) }
                    resp = handle(req)
                    if isScreen || isBg { stateLock.lock(); if isScreen { screenJobs -= 1 } else { bgJobs -= 1 }; stateLock.unlock(); setIndicator(false) }
                    log("\(cmd) ok=\(resp["ok"] ?? false) ms=\(Int((nowEpoch()-t0)*1000)) \(resp["error"] ?? "")")
                }
            } else { resp = ["ok": false, "error": "bad json"] }
            resp["ms"] = Int((nowEpoch() - t0) * 1000)
            let out = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{}".utf8)
            out.withUnsafeBytes { p in var off = 0; while off < out.count { let w = write(c, p.baseAddress! + off, out.count - off); if w <= 0 { break }; off += w } }
            close(c)
        }
    }
}

// housekeeping: shots/work older than 2 days, log rotation 5MB
func housekeep() {
    for d in [SHOTS, BASE + "/work"] {
        for it in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
            let p = d + "/" + it
            if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, Date().timeIntervalSince(m) > 2*86400 { try? fm.removeItem(atPath: p) }
        }
    }
    for f in [LOGF, BASE + "/logs/bridge.log"] {
        if let s = (try? fm.attributesOfItem(atPath: f))?[.size] as? Int, s > 5_000_000 { try? fm.removeItem(atPath: f + ".1"); try? fm.moveItem(atPath: f, toPath: f + ".1") }
    }
}

// ---------- main ----------
if CommandLine.arguments.contains("--version") { print("bridged \(VERSION)"); exit(0) }
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    bridged \(VERSION) - resident AsideBridge worker (unix socket \(SOCK)).
    Normally started through AsideBridge by `bridgectl.py daemon start` so it inherits its permissions.
      --headless   no menu bar indicator (tests / CI)
    """)
    exit(0)
}
try? fm.createDirectory(atPath: RUN, withIntermediateDirectories: true); chmod(RUN, 0o700)
try? fm.createDirectory(atPath: BASE + "/logs", withIntermediateDirectories: true)
TOKEN = ((try? String(contentsOfFile: BASE + "/token", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
if TOKEN.count < 16 { print("no token at \(BASE)/token; start AsideBridge first"); exit(1) }
let lockFd = open(RUN + "/bridged.lock", O_CREAT | O_RDWR, 0o600)
if flock(lockFd, LOCK_EX | LOCK_NB) != 0 { print("already running"); exit(0) }
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if !HEADLESS {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let i1 = NSMenuItem(title: "Stop agent control (STOP)", action: #selector(MenuTarget.stop), keyEquivalent: ""); i1.target = menuTarget; menu.addItem(i1)
    let i2 = NSMenuItem(title: "Resume", action: #selector(MenuTarget.resume), keyEquivalent: ""); i2.target = menuTarget; menu.addItem(i2)
    item.menu = menu
    item.isVisible = true
    statusItem = item
}
setIndicator(false)
Thread.detachNewThread { serve() }
housekeep()
Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in housekeep() }
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in setIndicator(false) }
app.run()
