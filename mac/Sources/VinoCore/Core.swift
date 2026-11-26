import CryptoKit
import Darwin
import Foundation
import os

/// Each run also goes to macOS's Console app: filter on "app.vino".
let consoleLog = Logger(subsystem: "app.vino", category: "wine")

/// A problem to show the user as "vino: <message>".
public struct VinoError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public enum Vino {
    // $HOME first, so tests and the CLI can point vino somewhere else
    public static var home: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) }
    public static var support: URL { home.appendingPathComponent("Library/Application Support/vino") }
    public static var bottlesDir: URL { support.appendingPathComponent("bottles") }

    static let wineApps = ["Wine Crossover", "Wine Stable", "Wine Devel", "Wine Staging"]
    // GitHub publishes no checksum for this file; pinned from our own download on 2026-11-26
    static let dxvk = (url: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
                       sha256: "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477")
    static let boolKeys: Set<String> = ["VINO_RETINA", "VINO_CMDCTRL", "VINO_DXVK", "VINO_SDL"]
    static let specialKeys = boolKeys.union(["VINO_WINVER", "VINO_DESKTOP", "VINO_PADS_OFF"])
    public static let windows = ["win11", "win10", "win81", "win8", "win7", "vista", "winxp"]
    // Unix keeps only 8 bits of Wine's exit code: 3010 and 1641 ("installed, restart needed") arrive as 194 and 105
    static let installerOK: Set<Int32> = [194, 105]

    // MARK: bottles and their files

    public static func bottle(_ name: String) throws -> URL {
        if name.isEmpty || name.contains("/") || name.hasPrefix(".") || name.hasPrefix("-") {
            throw VinoError("bad bottle name: '\(name)'")
        }
        return bottlesDir.appendingPathComponent(name)
    }

    public static func bottles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bottlesDir.path)) ?? []
        return names.sorted().map { bottlesDir.appendingPathComponent($0) }.filter { isDir($0) }
    }

    static func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    static func isFile(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && !d.boolValue  // follows symlinks
    }

    static func isSymlink(_ u: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    public static func loadJSON(_ u: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static func saveJSON(_ u: URL, _ o: [String: Any]) throws {
        let tmp = u.deletingLastPathComponent().appendingPathComponent(u.lastPathComponent + ".tmp")
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: tmp)
        guard rename(tmp.path, u.path) == 0 else { throw VinoError("couldn't save \(u.path)") }  // atomic, so a reader never sees half a file
    }

    /// One vino at a time changes a bottle's files, so parallel runs and settings don't lose each other's writes.
    static func locked<T>(_ b: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let fd = open(b.appendingPathComponent(".vino.lock").path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw VinoError("can't lock \(b.path)") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        return try body()
    }

    public static func loadEnv(_ b: URL) -> [String: String] {
        var env: [String: String] = [:]
        for (k, v) in loadJSON(b.appendingPathComponent("vino-env.json")) where !(v is NSNull) {
            env[k] = v as? String ?? "\(v)"
        }
        return env
    }

    // MARK: finding Wine

    static func runnable(_ p: String?) -> Bool {
        guard let p, !p.isEmpty else { return false }
        return isFile(URL(fileURLWithPath: p)) && FileManager.default.isExecutableFile(atPath: p)
    }

    /// The Wine that `vino setup` downloads.
    public static var ownWine: String { support.appendingPathComponent("wine/Wine Stable.app/Contents/Resources/wine/bin/wine").path }

    static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":").map { "\($0)/\(name)" }.first { runnable($0) }
    }

    /// Every Wine found on this Mac, in the order vino prefers them.
    public static func wineBuilds() -> [String] {
        let apps = wineApps.flatMap { a in ["wine", "wine64"].map { "/Applications/\(a).app/Contents/Resources/wine/bin/\($0)" } }
        var seen = Set<String>(), found: [String] = []
        for c in [ProcessInfo.processInfo.environment["VINO_WINE"], ownWine, which("wine"), which("wine64")] + apps {
            guard let c, runnable(c) else { continue }
            if seen.insert(realpath(c)).inserted { found.append(c) }
        }
        return found
    }

    static func realpath(_ p: String) -> String {
        guard let r = Darwin.realpath(p, nil) else { return p }  // the real path, unlike Foundation's, which drops /private
        defer { free(r) }
        return String(cString: r)
    }

    static func findWine(_ b: URL?, _ env: [String: String]? = nil) throws -> String {
        let saved = (env ?? b.map(loadEnv) ?? [:])["VINO_WINE"]
        if runnable(saved) { return saved! }
        if let saved { warn("this bottle's Wine (\(saved)) is gone, using the default one") }
        guard let w = wineBuilds().first else { throw VinoError("Wine is not installed. Run: vino doctor") }
        return w
    }

    static func warn(_ s: String) { FileHandle.standardError.write(Data("vino: \(s)\n".utf8)) }

    // MARK: running Wine

    public static func logName(_ label: String) -> String {
        String(label.replacingOccurrences(of: "/", with: "-").prefix(100)) + ".log"  // long names would exceed the file system's limit
    }

    /// Wine's DLL choices: vino's own, then the user's WINEDLLOVERRIDES, which win where they overlap.
    public static func overrides(_ env: [String: String]) -> String {
        // winemenubuilder writes Linux menu files into the Mac's home folder; nothing on a Mac reads them
        var mine = ["winemenubuilder.exe=d"]
        if env["VINO_DXVK"] == "1" { mine.append("d3d11,d3d10core=n,b") }
        else if env["VINO_DXVK"] == "0" { mine.append("d3d11,d3d10core=b") }  // DXVK's files stay in system32 after it's turned off
        if let user = env["WINEDLLOVERRIDES"], !user.isEmpty { mine.append(user) }
        return mine.joined(separator: ";")
    }

    /// Run Wine in bottle b. label names an app: its run is logged to logs/<label>.log and kept in the history.
    /// env is the bottle's settings when the caller has newer ones than the saved file.
    /// capture=false shows the program's output instead of logging it.
    @discardableResult
    static func wine(_ b: URL, _ args: [String], cwd: URL? = nil, label: String? = nil, debug: Bool = false, check: Bool = true,
                     env: [String: String]? = nil, okCodes: Set<Int32> = [], capture: Bool = true) throws -> Int32 {
        let logs = b.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)  // Wine fills an empty prefix on first run
        let benv = env ?? loadEnv(b)
        let w = try findWine(b, benv)
        var full = ProcessInfo.processInfo.environment
        full["WINEDEBUG"] = debug ? "warn+all,+loaddll" : "fixme-all"
        full["MVK_CONFIG_LOG_LEVEL"] = "1"
        full.merge(benv) { $1 }
        full["WINEDLLOVERRIDES"] = overrides(benv)
        full["WINEPREFIX"] = b.path

        let log = logs.appendingPathComponent(logName(label ?? "vino"))
        if FileManager.default.fileExists(atPath: log.path) {  // keep the last run's log, so re-running a crash doesn't erase it
            let prev = log.deletingPathExtension().appendingPathExtension("prev.log")
            _ = rename(log.path, prev.path)
        }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let started = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: w)
        p.arguments = args
        p.environment = full
        if let cwd { p.currentDirectoryURL = cwd }
        if capture, let fh = FileHandle(forWritingAtPath: log.path) {
            p.standardOutput = fh
            p.standardError = fh
        }
        do { try p.run() } catch {
            throw VinoError("couldn't start Wine (\(w)): \((error as NSError).localizedDescription)")
        }
        consoleLog.info("\(b.lastPathComponent, privacy: .public): started \(args.joined(separator: " "), privacy: .public)")
        p.waitUntilExit()
        var code = p.terminationReason == .uncaughtSignal ? -p.terminationStatus : p.terminationStatus

        let marker = b.appendingPathComponent(".vino-quit")
        let quitAfterStart = ((try? FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate]) as? Date)
            .map { $0.timeIntervalSince(started) >= -1 } ?? false
        if code != 0 && (okCodes.contains(code) || quitAfterStart) {
            code = 0  // the user quit it with vino quit, or an installer asked for a restart: not a failure
        }
        consoleLog.info("\(b.lastPathComponent, privacy: .public): \(label ?? args.first ?? "wine", privacy: .public) ended with \(code)")
        if let label {
            try locked(b) {
                let h = b.appendingPathComponent("vino-history.json")
                var hist = loadJSON(h)
                hist[label] = ["time": Int(Date().timeIntervalSince1970), "code": Int(code)]
                try saveJSON(h, hist)
            }
        }
        if code != 0 && check { throw stopped(log, code) }
        return code
    }

    /// Prints a failed run's error lines and returns the error to show.
    static func stopped(_ log: URL, _ code: Int32) -> VinoError {
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        let errs = lines.filter { $0.contains(":err:") }
        FileHandle.standardError.write(Data(((errs.isEmpty ? lines : errs).suffix(15).joined(separator: "\n") + "\n").utf8))
        // Unix keeps only the low 8 bits of Windows exit codes, so say "status", not "code"
        return VinoError("the app stopped with exit status \(code). Full log: \(log.path)")
    }

    // MARK: installed apps = Start Menu and Desktop shortcuts, like Windows shows them

    public struct App {
        public let bottle: URL
        public let name: String
        public let shortcut: URL
    }

    public static func apps(_ only: URL? = nil) -> [App] {
        var found: [App] = []
        let fm = FileManager.default
        for b in (only.map { [$0] } ?? bottles()) {
            let c = b.appendingPathComponent("drive_c")
            let users = (try? fm.contentsOfDirectory(atPath: c.appendingPathComponent("users").path)) ?? []
            let userDirs = users.map { c.appendingPathComponent("users/\($0)") }
            let menus = [c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu")]
                + userDirs.map { $0.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu") }
            // A user's Desktop links to the real Mac Desktop; reading it makes macOS ask for Desktop access, so skip links
            let desks = userDirs.map { $0.appendingPathComponent("Desktop") }.filter { isDir($0) && !isSymlink($0) }
            var lnks: [URL] = []
            for m in menus where isDir(m) {
                let e = fm.enumerator(at: m, includingPropertiesForKeys: nil)
                while let u = e?.nextObject() as? URL {
                    if u.pathExtension.lowercased() == "lnk" { lnks.append(u) }
                }
            }
            for d in desks {
                lnks += ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "lnk" }
            }
            var names: [String: URL] = [:]
            for l in lnks where isFile(l) {
                let stem = l.deletingPathExtension().lastPathComponent
                if stem.lowercased().contains("uninstall") || opensDocument(b, l) { continue }
                names[stem] = l
            }
            for n in names.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                found.append(App(bottle: b, name: n, shortcut: names[n]!))
            }
        }
        return found
    }

    /// Shortcuts to help files, readmes and web links aren't apps.
    static func opensDocument(_ b: URL, _ lnk: URL) -> Bool {
        guard let r = resolve(b, lnk) else { return false }
        return !["exe", "bat", "cmd", "com", "msc", "lnk"].contains(r.exe.pathExtension.lowercased())
    }

    static func findApp(_ name: String, _ only: URL?) throws -> App {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw VinoError("which app? Give its name, like: vino run Notepad++") }
        var hits = apps(only).filter { $0.name.lowercased().contains(name.lowercased()) }
        let exact = hits.filter { $0.name.lowercased() == name.lowercased() }
        if !exact.isEmpty { hits = exact }
        if hits.isEmpty { throw VinoError("no file or installed app called '\(name)'. See: vino apps") }
        if hits.count > 1 { throw VinoError("which one? " + hits.map { "\"\($0.name)\" (-b \($0.bottle.lastPathComponent))" }.joined(separator: ", ")) }
        return hits[0]
    }

    // MARK: shortcuts

    public struct Shortcut {
        public var target: String?
        public var workdir = ""
        public var args = ""
        public var iconLocation = ""
        public var iconIndex: Int32 = 0
    }

    /// Reads a Windows shortcut (MS-SHLLINK format). Wine's `start` can't wait on a .lnk (it returns code 4 at once),
    /// so vino opens the target itself. Returns nil for anything malformed.
    public static func readLnk(_ d: Data) -> Shortcut? {
        let d = [UInt8](d)
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { guard let lo = u16(o), let hi = u16(o + 2) else { return nil }; return lo | hi << 16 }
        guard let flags = u32(0x14), let index = u32(0x38) else { return nil }
        var s = Shortcut(iconIndex: Int32(truncatingIfNeeded: index))
        var pos = 0x4C
        if flags & 0x1 != 0 {  // skip the ID list
            guard let n = u16(pos) else { return nil }
            pos += 2 + n
        }
        if flags & 0x2 != 0 {  // LinkInfo holds the local path
            guard let size = u32(pos), let header = u32(pos + 4), let infoFlags = u32(pos + 8), let base = u32(pos + 16) else { return nil }
            if infoFlags & 0x1 != 0 {
                if header >= 0x24 {  // newer shortcuts also store it as UTF-16
                    guard let off = u32(pos + 0x1C), pos + off <= d.count else { return nil }
                    s.target = utf16z(d, pos + off)
                } else {
                    guard pos + base <= d.count else { return nil }
                    let bytes = d[(pos + base)...].prefix { $0 != 0 }
                    s.target = String(decoding: bytes, as: UTF8.self)  // shortcut: ANSI paths decoded as UTF-8; fine for ASCII
                }
            }
            pos += size
        }
        let wide = flags & 0x80 != 0
        var strings: [String] = []
        for bit in [0x4, 0x8, 0x10, 0x20, 0x40] {  // name, relative path, working dir, arguments, icon location
            if flags & bit == 0 { strings.append(""); continue }
            guard let count = u16(pos) else { return nil }
            let n = count * (wide ? 2 : 1)
            guard pos + 2 + n <= d.count else { return nil }
            let raw = Array(d[(pos + 2)..<(pos + 2 + n)])
            // Wine counts the terminating null in n, Windows doesn't
            let text = wide ? utf16z(raw, 0) : String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            strings.append(text)
            pos += 2 + n
        }
        s.workdir = strings[2]
        s.args = strings[3]
        s.iconLocation = strings[4]
        return s
    }

    static func utf16z(_ d: [UInt8], _ start: Int) -> String {
        var units: [UInt16] = []
        var i = start
        while i + 1 < d.count {
            let u = UInt16(d[i]) | UInt16(d[i + 1]) << 8
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// C:\Program Files\x.exe -> <bottle>/dosdevices/c:/Program Files/x.exe, or nil without a drive letter.
    public static func unixPath(_ b: URL, _ win: String) -> URL? {
        let chars = Array(win)
        guard chars.count >= 2, chars[1] == ":", chars[0].isASCII, chars[0].isLetter else { return nil }  // relative or network paths: Wine handles those
        var parts: [String] = []
        for p in String(chars.dropFirst(2)).split(whereSeparator: { $0 == "\\" || $0 == "/" }) {
            if p == "." { continue }
            if p == ".." { _ = parts.popLast(); continue }  // ".." never climbs out of the drive
            parts.append(String(p))
        }
        var u = b.appendingPathComponent("dosdevices/\(chars[0].lowercased()):")
        for p in parts { u.appendPathComponent(p) }
        return u
    }

    /// Windows-style argument splitting: quotes group words, backslashes stay literal.
    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, has = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; has = true
            } else if ch.isWhitespace {
                if has || !cur.isEmpty { out.append(cur) }
                cur = ""; has = false
            } else {
                cur.append(ch); has = true
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The program a shortcut opens (as a Mac path), its working folder and arguments, or nil when vino can't read it.
    static func resolve(_ b: URL, _ lnk: URL) -> (exe: URL, cwd: URL?, args: [String])? {
        guard let d = try? Data(contentsOf: lnk), let s = readLnk(d), let t = s.target, let exe = unixPath(b, t) else { return nil }
        let cwd = s.workdir.isEmpty ? nil : unixPath(b, s.workdir)
        return (exe, cwd.flatMap { isDir($0) ? $0 : nil }, splitArgs(s.args))
    }

    /// How Wine should open a file. .exe files run directly: `start` gives console programs a new console,
    /// so their output never reaches the log. Everything else (.msi, .bat, .lnk) goes through start.
    static func program(_ f: URL) -> [String] {
        f.pathExtension.lowercased() == "exe" ? [f.path] : ["start", "/wait", "/unix", f.path]
    }

    static func launch(_ b: URL, _ lnk: URL, _ name: String, _ extra: [String], _ debug: Bool) throws {
        guard let r = resolve(b, lnk) else {
            // unreadable shortcut: Wine can open it, but start can't wait on it or report a real exit code
            try wine(b, ["start", "/unix", lnk.path] + extra, debug: debug, check: false)
            return
        }
        try wine(b, program(r.exe) + r.args + extra, cwd: r.cwd, label: name, debug: debug)
    }

    // MARK: installed programs, from Wine's registry files

    /// Wine's registry files escape text like C: \" \\ \n, and non-ASCII as \x4e2d (emoji as two \x halves).
    public static func regUnescape(_ s: String) -> String {
        var units: [UInt16] = []
        let c = Array(s.utf16)
        var i = 0
        while i < c.count {
            if c[i] == 0x5C, i + 1 < c.count {  // backslash
                let n = c[i + 1]
                if n == 0x78 {  // \x followed by up to 4 hex digits
                    var j = i + 2, v: UInt32 = 0
                    while j < c.count, j < i + 6, let h = hexValue(c[j]) { v = v * 16 + h; j += 1 }
                    if j > i + 2 { units.append(UInt16(v)); i = j; continue }
                }
                switch n {
                case 0x6E: units.append(0x0A)  // \n
                case 0x72: units.append(0x0D)  // \r
                case 0x74: units.append(0x09)  // \t
                case 0x30: units.append(0)  // \0
                default: units.append(n)
                }
                i += 2
            } else {
                units.append(c[i]); i += 1
            }
        }
        return String(decoding: units, as: UTF16.self)  // joins surrogate halves into one character
    }

    static func hexValue(_ u: UInt16) -> UInt32? {
        switch u {
        case 0x30...0x39: return UInt32(u - 0x30)
        case 0x41...0x46: return UInt32(u - 0x41 + 10)
        case 0x61...0x66: return UInt32(u - 0x61 + 10)
        default: return nil
        }
    }

    /// Programs listed in the bottle's Add/Remove Programs.
    public static func installed(_ b: URL) -> [(name: String, version: String)] {
        var found: [String: String] = [:]
        for file in ["system.reg", "user.reg"] {
            guard let text = try? String(contentsOf: b.appendingPathComponent(file), encoding: .utf8) else { continue }
            for block in text.components(separatedBy: "\n[") {
                let lines = block.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
                guard let head = lines.first, let close = head.range(of: "]", options: .backwards),
                      head[..<close.lowerBound].contains("\\\\Uninstall\\\\") else { continue }
                var vals: [String: String] = [:]
                var hidden = false
                for l in lines.dropFirst() {
                    // Windows hides system parts and updates from Add/Remove Programs too
                    if l.hasPrefix("\"ParentKeyName\"=") { hidden = true }
                    if l.hasPrefix("\"SystemComponent\"=dword:"), Int(l.dropFirst(24), radix: 16) == 1 { hidden = true }
                    for key in ["DisplayName", "DisplayVersion"] {
                        for prefix in ["\"\(key)\"=\"", "\"\(key)\"=str(2):\""] where l.hasPrefix(prefix) && l.hasSuffix("\"") && l.count > prefix.count {
                            vals[key] = String(l.dropFirst(prefix.count).dropLast())
                        }
                    }
                }
                if let n = vals["DisplayName"], !n.isEmpty, !hidden { found[regUnescape(n)] = regUnescape(vals["DisplayVersion"] ?? "") }
            }
        }
        return found.map { ($0.key, $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: what's running

    /// Whether Wine is running in this bottle, without starting it: a running bottle has a wineserver
    /// socket in /tmp/.wine-<uid>/server-<device>-<inode> of the bottle folder.
    public static func isRunning(_ b: URL) -> Bool {
        var st = stat()
        guard stat(b.path, &st) == 0 else { return false }
        let dir = String(format: "/tmp/.wine-%d/server-%llx-%llx", getuid(), UInt64(st.st_dev), UInt64(st.st_ino))
        return FileManager.default.fileExists(atPath: dir + "/socket")
    }

    /// Wine's own background programs, hidden from the task list.
    static let systemProcesses: Set<String> = ["services.exe", "explorer.exe", "winedevice.exe", "svchost.exe", "plugplay.exe", "rpcss.exe",
                                               "conhost.exe", "start.exe", "tasklist.exe", "taskkill.exe", "winemenubuilder.exe", "wineboot.exe"]

    /// The Windows programs running in a bottle, from Wine's tasklist.
    public static func processes(_ b: URL) throws -> [(name: String, pid: Int)] {
        guard isRunning(b) else { return [] }
        let out = try output(b, ["tasklist", "/fo", "csv", "/nh"])
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let cols = line.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            guard cols.count >= 2, let pid = Int(cols[1]), !systemProcesses.contains(cols[0].lowercased()) else { return nil }
            return (cols[0], pid)
        }
    }

    /// Runs a Wine program and returns what it printed.
    static func output(_ b: URL, _ args: [String]) throws -> String {
        let env = loadEnv(b)
        var full = ProcessInfo.processInfo.environment
        full.merge(env) { $1 }
        full["WINEDEBUG"] = "-all"
        full["WINEDLLOVERRIDES"] = overrides(env)
        full["WINEPREFIX"] = b.path
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: try findWine(b, env))
        p.arguments = args
        p.environment = full
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw VinoError("couldn't start Wine: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: helpers

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func sha256(file: URL) throws -> String {
        guard let h = FileHandle(forReadingAtPath: file.path) else { throw VinoError("can't read \(file.path)") }
        defer { try? h.close() }
        var hasher = SHA256()
        while case let chunk = h.readData(ofLength: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a tool and returns its exit status, with output silenced.
    @discardableResult
    static func run(_ tool: String, _ args: [String], env: [String: String]? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let env { p.environment = env }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
