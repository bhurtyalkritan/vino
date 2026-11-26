import Foundation

/// The `vino` command line. The app's own binary runs it when its first argument is a command.
public enum CLI {
    struct Spec {
        let help: String
        var bottle = true  // takes -b NAME
        var flags: [String] = []  // like --json
        var positionals: [String] = []  // required, in order
        var optional: String? = nil  // one optional positional
        var rest: String? = nil  // everything left, unparsed (args passed to a program)
        var many: String? = nil  // one or more
    }

    static let specs: [String: Spec] = [
        "run": Spec(help: "run a .exe/.msi (installers too) or an installed app by name", flags: ["--debug"], positionals: ["target"], rest: "args"),
        "apps": Spec(help: "list installed apps", flags: ["--json"]),
        "bottles": Spec(help: "list bottles and their settings", bottle: false, flags: ["--json"]),
        "wines": Spec(help: "list the Wine versions on this Mac", bottle: false, flags: ["--json"]),
        "installed": Spec(help: "list programs installed in a bottle", flags: ["--json"]),
        "quit": Spec(help: "close an app, or everything in a bottle", optional: "name"),
        "ps": Spec(help: "list the Windows programs running in a bottle", flags: ["--json"]),
        "kill": Spec(help: "close a running Windows program by its number from `vino ps`", flags: ["--force"], positionals: ["pid"]),
        "new": Spec(help: "create an empty bottle", bottle: false, positionals: ["name"]),
        "wine": Spec(help: "run a Wine program in a bottle, e.g. taskmgr, regedit, wineboot -r", rest: "args"),
        "set": Spec(help: "save settings for a bottle: Wine env vars, VINO_WINE=/path/to/wine, VINO_WINVER=win7, VINO_RETINA=1, VINO_CMDCTRL=1, VINO_DXVK=1, VINO_SDL=1, VINO_DESKTOP=1280x800, VINO_PADS_OFF=name|name; NAME= removes one", many: "pairs"),
        "settings": Spec(help: "open Wine's settings window (winecfg)"),
        "files": Spec(help: "show a bottle's C: drive in Finder"),
        "delete": Spec(help: "move a bottle to the Trash", bottle: false, positionals: ["name"]),
        "install": Spec(help: "install an app from the catalog by name, or from a recipe file", bottle: false, positionals: ["recipe"]),
        "catalog": Spec(help: "list the apps Vino can install for you", bottle: false, flags: ["--json"]),
        "components": Spec(help: "list common Windows components (Visual C++, .NET, fonts) and which this bottle has", flags: ["--json"]),
        "winetricks": Spec(help: "install Windows components with Winetricks, like: vino winetricks vcrun2022 corefonts", many: "verbs"),
        "configure": Spec(help: "save an app's own settings: VINO_ARGS=\"-windowed\", LC_ALL=ja_JP.UTF-8 (its language), or any environment variable; NAME= removes one",
                          positionals: ["name"], many: "pairs"),
        "shortcut": Spec(help: "make a Mac app in ~/Applications that opens a Windows app, for the Dock, Launchpad and Spotlight", positionals: ["name"]),
        "doctor": Spec(help: "check that everything is set up, and say how to fix it", bottle: false),
        "setup": Spec(help: "install what vino needs: Rosetta and Wine", bottle: false),
    ]

    struct Args {
        var bottle: String?
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var list: [String] = []
        func has(_ f: String) -> Bool { flags.contains(f) }
    }

    /// Returns an exit status when argv is a vino command, or nil to start the app.
    public static func runIfCommand(_ argv: [String]) -> Int32? {
        guard argv.count > 1 else { return nil }
        let cmd = argv[1]
        if cmd == "-h" || cmd == "--help" { print(usage()); return 0 }
        if cmd.hasPrefix("-") { return nil }  // macOS launch flags like -NSDocumentRevisionsDebugMode
        guard let spec = specs[cmd] else { return usageError("unknown command '\(cmd)'") }
        guard let a = parse(Array(argv.dropFirst(2)), spec, cmd) else { return 2 }
        if a.has("--help") { print("usage: vino \(cmd) …\n\n\(spec.help)"); return 0 }
        do {
            return try dispatch(cmd, a)
        } catch let e as VinoError {
            FileHandle.standardError.write(Data("vino: \(e.message)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("vino: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func usage() -> String {
        "usage: vino COMMAND [-b BOTTLE] …\n\nRun Windows apps on your Mac. Start with: vino doctor\n\n"
            + specs.keys.sorted().map { "  \($0.padding(toLength: 10, withPad: " ", startingAt: 0)) \(specs[$0]!.help)" }.joined(separator: "\n")
    }

    static func usageError(_ msg: String) -> Int32 {
        FileHandle.standardError.write(Data("usage: vino COMMAND [-b BOTTLE] …\nvino: error: \(msg)\n".utf8))
        return 2
    }

    static func parse(_ tokens: [String], _ spec: Spec, _ cmd: String) -> Args? {
        var a = Args(), positional: [String] = [], i = 0, optionsDone = false
        let wanted = spec.positionals.count
        while i < tokens.count {
            let t = tokens[i]
            // once the target is known (or, without one, at the first plain word), everything else belongs to the program
            if spec.rest != nil && positional.count == wanted && (wanted > 0 || optionsDone || !t.hasPrefix("-")) {
                a.list = Array(tokens[i...])
                break
            }
            if !optionsDone && t == "--" { optionsDone = true; i += 1; continue }
            if !optionsDone && t.hasPrefix("-") && t != "-" {
                if spec.bottle && (t == "-b" || t == "--bottle") {
                    guard i + 1 < tokens.count else { _ = usageError("argument -b/--bottle: expected one argument"); return nil }
                    a.bottle = tokens[i + 1]; i += 2; continue
                }
                if spec.bottle && t.hasPrefix("--bottle=") { a.bottle = String(t.dropFirst(9)); i += 1; continue }
                if spec.flags.contains(t) || t == "--help" || t == "-h" { a.flags.insert(t == "-h" ? "--help" : t); i += 1; continue }
                _ = usageError("unrecognized arguments: \(t)")
                return nil
            }
            positional.append(t)
            i += 1
        }
        if positional.count < wanted { _ = usageError("the following arguments are required: \(spec.positionals[positional.count])"); return nil }
        for (n, v) in zip(spec.positionals, positional) { a.values[n] = v }
        let extra = Array(positional.dropFirst(wanted))
        if spec.many != nil {
            if extra.isEmpty { _ = usageError("the following arguments are required: NAME=value"); return nil }
            a.list = extra
        } else if spec.optional != nil {
            if extra.count > 1 { _ = usageError("unrecognized arguments: \(extra.dropFirst().joined(separator: " "))"); return nil }
            if let v = extra.first { a.values["optional"] = v }
        } else if spec.rest == nil && !extra.isEmpty {
            _ = usageError("unrecognized arguments: \(extra.joined(separator: " "))")
            return nil
        }
        return a
    }

    static func dispatch(_ cmd: String, _ a: Args) throws -> Int32 {
        let bottle = { try Vino.bottle(a.bottle ?? "default") }
        switch cmd {
        case "run": try run(a)
        case "apps": try apps(a)
        case "bottles": bottles(a)
        case "wines": wines(a)
        case "installed":
            let items = Vino.installed(try bottle())
            if a.has("--json") { printJSON(items.map { ["name": $0.name, "version": $0.version] }) }
            else { items.forEach { print("\($0.name)  \($0.version)") } }
        case "quit": return try quit(a)
        case "ps":
            let list = try Vino.processes(try bottle())
            if a.has("--json") { printJSON(list.map { ["name": $0.name, "pid": $0.pid] }) }
            else { list.forEach { print("\($0.pid)\t\($0.name)") } }
        case "kill":
            guard let pid = Int(a.values["pid"]!) else { throw VinoError("expected a program number from `vino ps`, got '\(a.values["pid"]!)'") }
            // without --force, taskkill asks the program to close, like clicking its close button
            return try Vino.wine(try bottle(), ["taskkill", "/pid", "\(pid)"] + (a.has("--force") ? ["/f"] : []), check: false, capture: false)
        case "new": try new(a.values["name"]!)
        case "wine": return try Vino.wine(try bottle(), a.list, check: false, capture: false)
        case "set": try set(try bottle(), a.list)
        case "settings": try Vino.wine(try bottle(), ["winecfg"])
        case "files":
            let c = try bottle().appendingPathComponent("drive_c")
            guard Vino.isDir(c) else { throw VinoError("bottle '\(try bottle().lastPathComponent)' has no files yet") }
            Vino.run("/usr/bin/open", [c.path])
        case "delete": try delete(a.values["name"]!)
        case "install": try install(a.values["recipe"]!)
        case "configure": try configure(a)
        case "components":
            let have = Winetricks.installed(try bottle())
            let list = Winetricks.components.map { ["verb": $0.verb, "title": $0.title, "detail": $0.detail, "installed": have.contains($0.verb)] as [String: Any] }
            if a.has("--json") { printJSON(list) }
            else { list.forEach { print("\(($0["installed"] as! Bool) ? "✓" : " ") \($0["verb"]!)  \($0["title"]!)") } }
        case "winetricks": try Winetricks.install(try bottle(), a.list)
        case "shortcut": print(try macShortcut(try Vino.findApp(a.values["name"]!, try a.bottle.map(Vino.bottle))).path)
        case "catalog":
            let items = catalog()
            if a.has("--json") { printJSON(items.map { $0.info }) }
            else { items.forEach { print("\($0.info["name"] as? String ?? "")  \($0.info["summary"] as? String ?? "")") } }
        case "doctor": return doctor()
        case "setup": try Setup.install(say: { print($0) })
        default: break
        }
        return 0
    }

    static func printJSON(_ o: Any) {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        print(String(decoding: d, as: UTF8.self))
    }

    // MARK: commands

    static func run(_ a: Args) throws {
        let target = a.values["target"]!
        let f = URL(fileURLWithPath: target)
        if Vino.isFile(f) {
            let b = try Vino.bottle(a.bottle ?? "default")
            let file = URL(fileURLWithPath: Vino.realpath(f.path))
            let stem = file.deletingPathExtension().lastPathComponent
            if file.pathExtension.lowercased() == "lnk" { return try Vino.launch(b, file, stem, a.list, a.has("--debug")) }
            return try runInstaller(b, file, args: a.list, debug: a.has("--debug"), appName: nil)
        }
        let app = try Vino.findApp(target, try a.bottle.map(Vino.bottle))
        try Vino.launch(app.bottle, app.shortcut, app.name, a.list, a.has("--debug"))
    }

    /// Runs a program or installer. If it's an Inno Setup installer that fails (its installer program crashes
    /// in this Wine), unpacks it instead so the app still gets installed.
    static func runInstaller(_ b: URL, _ file: URL, args: [String], debug: Bool, appName: String?) throws {
        let stem = file.deletingPathExtension().lastPathComponent
        let code = try Vino.wine(b, Vino.program(file) + args, label: stem, debug: debug, check: false, okCodes: Vino.installerOK)
        guard code != 0 else { return }
        let log = b.appendingPathComponent("logs/" + Vino.logName(stem))
        guard file.pathExtension.lowercased() == "exe", Inno.isInstaller(file) else { throw Vino.stopped(log, code) }
        print("The installer stopped (exit status \(code)), so Vino is unpacking it instead…")
        let name = try Inno.unpack(file, into: b, name: appName ?? Inno.appName(fromInstaller: stem))
        print("Unpacked \(name). Its installer's own setup steps were skipped. Start it with: vino run \"\(name)\"")
    }

    static func configure(_ a: Args) throws {
        let app = try Vino.findApp(a.values["name"]!, try a.bottle.map(Vino.bottle))
        var changes: [(String, String)] = []
        for kv in a.list {
            guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else { throw VinoError("expected NAME=value, got '\(kv)'") }
            changes.append((String(kv[..<eq]), String(kv[kv.index(after: eq)...])))
        }
        try Vino.locked(app.bottle) {
            let file = app.bottle.appendingPathComponent("vino-apps.json")
            var all = Vino.loadJSON(file)
            var mine = all[app.name] as? [String: String] ?? [:]
            for (k, v) in changes { mine[k] = v.isEmpty ? nil : v }
            all[app.name] = mine.isEmpty ? nil : mine
            try Vino.saveJSON(file, all)
        }
    }

    /// A tiny Mac app in ~/Applications that opens a Windows app through this Vino,
    /// so it can live in the Dock and show up in Launchpad and Spotlight.
    static func macShortcut(_ app: Vino.App) throws -> URL {
        guard let vino = Bundle.main.executablePath.map(Vino.realpath) else { throw VinoError("can't tell where Vino is") }
        let fm = FileManager.default
        let bundle = Vino.home.appendingPathComponent("Applications/\(app.name.replacingOccurrences(of: "/", with: "-")).app")
        let contents = bundle.appendingPathComponent("Contents")
        try? fm.removeItem(at: bundle)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let quote = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // shortcut: points at this copy of Vino; moving Vino.app breaks it until the shortcut is made again
        let script = "#!/bin/sh\n# Opens \(app.name) with Vino\nexec \(quote(vino)) run -b \(quote(app.bottle.lastPathComponent)) -- \(quote(app.name))\n"
        let launcher = contents.appendingPathComponent("MacOS/launch")
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        var info: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleName": app.name,
            "CFBundleIdentifier": "app.vino.shortcut." + app.name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined(),
            "CFBundlePackageType": "APPL",
            "LSApplicationCategoryType": "public.app-category.games",  // lets macOS use Game Mode
        ]
        if let png = Icons.cached(app),
           Vino.run("/usr/bin/sips", ["-s", "format", "icns", png, "--out", contents.appendingPathComponent("Resources/icon.icns").path]) == 0 {
            info["CFBundleIconFile"] = "icon"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    static func quit(_ a: Args) throws -> Int32 {
        let b = try Vino.bottle(a.bottle ?? "default")
        if let name = a.values["optional"] {
            let app = try Vino.findApp(name, a.bottle != nil ? b : nil)
            guard let r = Vino.resolve(app.bottle, app.shortcut) else {
                throw VinoError("can't tell which program '\(app.name)' runs; quit everything with: vino quit -b \(app.bottle.lastPathComponent)")
            }
            touchQuitMarker(app.bottle)  // tells the waiting `vino run` this exit was asked for
            // taskkill without /f asks the app to close, like clicking its close button
            return try Vino.wine(app.bottle, ["taskkill", "/im", r.exe.lastPathComponent], check: false, capture: false)
        }
        let server = URL(fileURLWithPath: Vino.realpath(try Vino.findWine(b))).deletingLastPathComponent().appendingPathComponent("wineserver")
        guard Vino.runnable(server.path) else { throw VinoError("can't find wineserver next to \(server.deletingLastPathComponent().path)") }
        touchQuitMarker(b)
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = b.path
        Vino.run(server.path, ["-k"], env: env)
        return 0
    }

    static func touchQuitMarker(_ b: URL) {
        let m = b.appendingPathComponent(".vino-quit")
        FileManager.default.createFile(atPath: m.path, contents: nil)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: m.path)
    }

    static func apps(_ a: Args) throws {
        let found = Vino.apps(try a.bottle.map(Vino.bottle))
        if a.has("--json") {
            var hist: [URL: [String: Any]] = [:]
            printJSON(found.map { app -> [String: Any] in
                if hist[app.bottle] == nil { hist[app.bottle] = Vino.loadJSON(app.bottle.appendingPathComponent("vino-history.json")) }
                return ["name": app.name, "bottle": app.bottle.lastPathComponent,
                        "last": hist[app.bottle]![app.name] as? [String: Any] ?? NSNull(),
                        "log": app.bottle.appendingPathComponent("logs/" + Vino.logName(app.name)).path,
                        "icon": Icons.cached(app) ?? NSNull(),
                        "exe": Vino.resolve(app.bottle, app.shortcut)?.exe.lastPathComponent ?? NSNull(),
                        "settings": Vino.appSettings(app.bottle)[app.name] ?? [:]]
            })
            return
        }
        for app in found { print(app.bottle.lastPathComponent == "default" ? app.name : "\(app.name)  (\(app.bottle.lastPathComponent))") }
        if found.isEmpty { print("No apps yet. Install one with: vino run ~/Downloads/setup.exe") }
    }

    static func bottles(_ a: Args) {
        if a.has("--json") {
            printJSON(Vino.bottles().map { ["name": $0.lastPathComponent, "path": $0.path, "env": Vino.loadEnv($0)] })
            return
        }
        for b in Vino.bottles() {
            print(([b.lastPathComponent] + Vino.loadEnv(b).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: " "))
        }
    }

    static func wines(_ a: Args) {
        let name = { (w: String) -> String in
            let real = Vino.realpath(w)
            guard let r = real.range(of: ".app/") else { return w }
            return URL(fileURLWithPath: String(real[..<r.lowerBound])).lastPathComponent
        }
        let builds = Vino.wineBuilds()
        if a.has("--json") { printJSON(builds.map { ["name": name($0), "path": $0] }) }
        else { builds.forEach { print("\(name($0))  \($0)") } }
    }

    // MARK: settings

    static func set(_ b: URL, _ pairs: [String]) throws {
        var parsed: [(String, String)] = []
        for kv in pairs {
            guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else { throw VinoError("expected NAME=value, got '\(kv)'") }
            let k = String(kv[..<eq])
            var v = String(kv[kv.index(after: eq)...])
            if Vino.boolKeys.contains(k) && !["", "0", "1"].contains(v) { throw VinoError("\(k) takes 1 (on) or 0 (off)") }
            if k == "VINO_WINVER" && !v.isEmpty && !Vino.windows.contains(v) {
                throw VinoError("VINO_WINVER takes one of: \(Vino.windows.joined(separator: ", "))")
            }
            if k == "VINO_DESKTOP" && !v.isEmpty && v.range(of: #"^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$"#, options: .regularExpression) == nil {
                throw VinoError("VINO_DESKTOP takes a size like 1280x800, or nothing to turn it off")
            }
            if k == "VINO_WINE" && !v.isEmpty {
                v = URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL.path
                guard Vino.runnable(v) else { throw VinoError("there's no Wine program at \(v)") }
            }
            parsed.append((k, v))
        }
        // plain settings first, so special ones run with them (like a new VINO_WINE)
        let ordered = parsed.filter { !Vino.specialKeys.contains($0.0) } + parsed.filter { Vino.specialKeys.contains($0.0) }
        try Vino.locked(b) {
            var env = Vino.loadEnv(b)
            for (k, v) in ordered {
                try apply(b, k, v, env)
                env[k] = v.isEmpty ? nil : v
                try Vino.saveJSON(b.appendingPathComponent("vino-env.json"), env)  // after each one, so a later failure keeps what already changed
            }
        }
    }

    /// Settings that change the bottle itself, not just Wine's environment.
    static func apply(_ b: URL, _ k: String, _ v: String, _ env: [String: String]) throws {
        let on = v == "1"
        func reg(_ key: String, _ name: String, _ type: String, _ data: String) throws {
            try Vino.wine(b, ["reg", "add", key, "/v", name, "/t", type, "/d", data, "/f"], env: env)
        }
        switch k {
        case "VINO_WINVER": try Vino.wine(b, ["winecfg", "-v", v.isEmpty ? "win10" : v], env: env)
        case "VINO_RETINA":
            try reg("HKCU\\Software\\Wine\\Mac Driver", "RetinaMode", "REG_SZ", on ? "y" : "n")
            try reg("HKCU\\Control Panel\\Desktop", "LogPixels", "REG_DWORD", on ? "192" : "96")
        case "VINO_CMDCTRL":  // the Mac's ⌘ key acts as Ctrl, so ⌘C copies
            for side in ["Left", "Right"] { try reg("HKCU\\Software\\Wine\\Mac Driver", "\(side)CommandIsCtrl", "REG_SZ", on ? "y" : "n") }
        case "VINO_DXVK" where on: try installDXVK(b, env)  // the DLL overrides follow VINO_DXVK; see overrides()
        case "VINO_SDL":  // SDL is how Wine sees most game controllers
            try reg("HKLM\\System\\CurrentControlSet\\Services\\WineBus", "Enable SDL", "REG_DWORD", on ? "1" : "0")
        case "VINO_DESKTOP":  // "run in a window": Wine draws Windows' desktop in one Mac window of this size
            if v.isEmpty {
                try Vino.wine(b, ["reg", "delete", "HKCU\\Software\\Wine\\Explorer", "/v", "Desktop", "/f"], check: false, env: env)
            } else {
                try reg("HKCU\\Software\\Wine\\Explorer\\Desktops", "Default", "REG_SZ", v)
                try reg("HKCU\\Software\\Wine\\Explorer", "Desktop", "REG_SZ", "Default")
            }
        case "VINO_PADS_OFF":  // controllers the user switched off, by the name Windows sees
            let before = Set((env["VINO_PADS_OFF"] ?? "").split(separator: "|").map(String.init))
            let after = Set(v.split(separator: "|").map(String.init))
            for name in after.subtracting(before) { try reg("HKCU\\Software\\Wine\\DirectInput\\Joysticks", name, "REG_SZ", "disabled") }
            for name in before.subtracting(after) {
                try Vino.wine(b, ["reg", "delete", "HKCU\\Software\\Wine\\DirectInput\\Joysticks", "/v", name, "/f"], check: false, env: env)
            }
        default: break
        }
    }

    /// DXVK turns DirectX 10/11 into Vulkan, which MoltenVK turns into Metal.
    static func installDXVK(_ b: URL, _ env: [String: String]) throws {
        let cache = Vino.support.appendingPathComponent("cache/" + URL(string: Vino.dxvk.url)!.lastPathComponent)
        if (try? Vino.sha256(file: cache)) != Vino.dxvk.sha256 {
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            print("Downloading DXVK...")
            let data: Data
            do { data = try Data(contentsOf: URL(string: Vino.dxvk.url)!) } catch {
                throw VinoError("couldn't download DXVK: \(error.localizedDescription)")
            }
            guard Vino.sha256(data) == Vino.dxvk.sha256 else { throw VinoError("the DXVK download doesn't match its checksum, not installing it") }
            try data.write(to: cache)
        }
        if !Vino.isDir(b.appendingPathComponent("drive_c/windows/system32")) { try Vino.wine(b, ["wineboot", "-i"], env: env) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vino-dxvk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard Vino.run("/usr/bin/tar", ["-xzf", cache.path, "-C", tmp.path]) == 0 else { throw VinoError("couldn't unpack DXVK") }
        let e = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)
        while let f = e?.nextObject() as? URL {
            guard f.pathExtension == "dll" else { continue }
            let folder = f.path.contains("/x64/") ? "system32" : "syswow64"
            let dest = b.appendingPathComponent("drive_c/windows/\(folder)/\(f.lastPathComponent)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: f, to: dest)
        }
    }

    // MARK: bottles

    static func new(_ name: String) throws {
        let b = try Vino.bottle(name)
        if FileManager.default.fileExists(atPath: b.path) { throw VinoError("there's already a bottle called '\(name)'") }
        do { try Vino.wine(b, ["wineboot", "-i"]) } catch {
            try? FileManager.default.removeItem(at: b)  // don't leave a half-made bottle that blocks trying again
            throw error
        }
        print("Created bottle '\(name)'.")
    }

    static func delete(_ name: String) throws {
        let b = try Vino.bottle(name)
        guard FileManager.default.fileExists(atPath: b.path) else { throw VinoError("no bottle called '\(name)'") }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        let trashDir = Vino.home.appendingPathComponent(".Trash")
        var trash = trashDir.appendingPathComponent("vino \(name) \(stamp)"), n = 2
        while FileManager.default.fileExists(atPath: trash.path) {
            trash = trashDir.appendingPathComponent("vino \(name) \(stamp) \(n)"); n += 1
        }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: b, to: trash)
        print("Moved '\(name)' to the Trash as '\(trash.lastPathComponent)'.")
    }

    // MARK: recipes

    /// The recipes that ship with Vino: Vino.app/Contents/Resources/recipes, or $VINO_RECIPES.
    static func catalog() -> [(file: URL, info: [String: Any])] {
        let dir = ProcessInfo.processInfo.environment["VINO_RECIPES"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("recipes")
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let name = o["name"] as? String else { return nil }
            o["app"] = o["app"] ?? name  // the Start Menu name it installs as
            o["file"] = f.path
            o.removeValue(forKey: "args"); o.removeValue(forKey: "env")
            return (f, o)
        }.sorted { ($0.info["name"] as! String).lowercased() < ($1.info["name"] as! String).lowercased() }
    }

    static func install(_ nameOrPath: String) throws {
        var path = nameOrPath
        if !FileManager.default.fileExists(atPath: path) {
            guard let hit = catalog().first(where: { ($0.info["name"] as? String)?.lowercased() == nameOrPath.lowercased() }) else {
                throw VinoError("no recipe file or catalog app called '\(nameOrPath)'. See: vino catalog")
            }
            path = hit.file.path
        }
        let r: [String: Any]
        do {
            let o = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: path)))
            guard let d = o as? [String: Any] else { throw VinoError("a recipe is a JSON object, like the example in the README") }
            r = d
        } catch let e as VinoError { throw e } catch {
            throw VinoError("can't read the recipe \(path): \(error.localizedDescription)")
        }
        for k in ["name", "url", "sha256"] where !(r[k] is String) { throw VinoError("the recipe needs a '\(k)'") }
        let name = r["name"] as! String, url = r["url"] as! String, sum = (r["sha256"] as! String).lowercased()
        guard let bottleName = (r["bottle"] ?? "default") as? String else { throw VinoError("the recipe's 'bottle' must be a name") }
        guard let args = (r["args"] ?? []) as? [String] else { throw VinoError("the recipe's 'args' must be a list of strings") }
        guard let env = (r["env"] ?? [:]) as? [String: String] else { throw VinoError("the recipe's 'env' must map names to strings") }
        let b = try Vino.bottle(bottleName)
        guard let u = URL(string: url), u.scheme != nil else { throw VinoError("couldn't download \(name): '\(url)' isn't a web address") }
        print("Downloading \(name)...")
        let data: Data
        do { data = try Data(contentsOf: u) } catch { throw VinoError("couldn't download \(name): \(error.localizedDescription)") }
        guard Vino.sha256(data) == sum else { throw VinoError("download does not match the recipe's sha256, not running it") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vino-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent(u.lastPathComponent.isEmpty ? "setup.exe" : u.lastPathComponent)
        try data.write(to: file)
        if !env.isEmpty { try set(b, env.map { "\($0.key)=\($0.value)" }) }
        try runInstaller(b, file, args: args, debug: false, appName: r["app"] as? String ?? name)
        print("Installed \(name). Start it with: vino run \"\(name)\"")
    }

    // MARK: doctor

    public static let setupCommand = "vino setup"

    static func doctor() -> Int32 {
        var ok = true
        if Setup.needsRosetta {
            ok = false
            print("✗ Rosetta is missing (Wine needs it on Apple Silicon). Fix:\n    softwareupdate --install-rosetta --agree-to-license")
        }
        if let w = try? Vino.findWine(nil) {
            if let version = Setup.wineVersion(w) {
                print("✓ Wine: \(version) (\(w))")
            } else {
                ok = false
                // vino's own Wine never trips Gatekeeper (vino downloads it itself), so suggest that over unblocking this one
                print("✗ The Wine at \(w) won't start (macOS may be blocking it). Fix by letting vino install its own:\n    \(setupCommand)")
            }
        } else {
            ok = false
            print("✗ Wine is not installed. Fix:\n    \(setupCommand)")
        }
        print("  Bottles live in: \(Vino.bottlesDir.path)")
        print(ok ? "All good. Try: vino run ~/Downloads/setup.exe" : "Fix the ✗ items above, then run vino doctor again.")
        return ok ? 0 : 1
    }
}
