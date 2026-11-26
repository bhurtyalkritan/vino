import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VinoCore

// The app is a face on its own `vino` command line (the same binary, run with a command), which does all the work.

struct VinoApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)  // the frosted window runs right up to the top, like the mockup
        .defaultSize(width: 1040, height: 700)
    }
}

// MARK: - Data from the CLI

struct LastRun: Decodable, Hashable {
    let time: Double
    let code: Int32
}

struct WinApp: Identifiable, Decodable, Hashable {
    let name: String
    let bottle: String
    let last: LastRun?
    let log: String?
    let icon: String?  // a PNG read out of the Windows program, when it has one
    let exe: String?  // the program its shortcut opens, used to tell whether it's running
    var id: String { bottle + "/" + name }
}

struct Bottle: Identifiable, Decodable, Hashable {
    let name: String
    let path: String
    var env: [String: String]
    var id: String { name }
    var title: String { name == "default" ? "Default" : name }
}

struct WineBuild: Decodable, Hashable {
    let name: String
    let path: String
}

/// An app in the Get Apps catalog (a recipe that ships with Vino).
struct CatalogItem: Decodable, Hashable, Identifiable {
    let name: String
    let app: String  // the name it shows up under once installed
    let summary: String?
    let symbol: String?
    let size: Int?
    let file: String
    var id: String { name }
}

struct Proc: Decodable, Hashable, Identifiable {
    let name: String
    let pid: Int
    var id: Int { pid }
}

struct Program: Decodable, Hashable {
    let name: String
    let version: String
}

struct Fix: Identifiable {
    let id = UUID()
    let problem: String
    let command: String
    var canRun = true  // false when `command` is just details to read
}

struct Failure: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var apps: [WinApp] = []
    @Published var bottles: [Bottle] = []
    @Published var wines: [WineBuild] = []
    @Published var fixes: [Fix]? = nil  // nil until the first check finishes
    @Published var running: Set<String> = []  // app ids Vino opened and is waiting on
    @Published var live: Set<String> = []  // app ids whose program is running right now, however it was started
    @Published var catalog: [CatalogItem] = []
    @Published var getting: Set<String> = []  // catalog apps being installed
    @Published var busy: Set<String> = []  // "bottle|SETTING" while a setting is applied
    @Published var activities: [UUID: String] = [:]  // long jobs; the pill shows one while any run
    @Published var toast: String?
    @Published var failure: Failure?
    @Published var setupStatus: String?  // what one-click setup is doing
    @Published var setupProgress: Double?  // the Wine download, 0…1
    private var quitting: Set<String> = []  // bottles and apps the user just quit, so their exit isn't reported as a crash

    var activity: String? { activities.values.sorted().first }

    static let windowsTypes = ["exe", "msi", "lnk", "bat"]

    func refresh() async {
        let doctor = await Self.vino(["doctor"])
        if doctor.status == 0 {
            fixes = []
        } else {
            let parsed = Self.parseFixes(doctor.out)
            // no fix we recognise means vino itself is broken: say so instead of showing an empty library
            fixes = parsed.isEmpty ? [Fix(problem: "vino couldn't check your Mac", command: (doctor.err + doctor.out).trimmed, canRun: false)] : parsed
        }
        if fixes?.isEmpty == true { await reload() }
    }

    func reload() async {
        async let a = Self.vino(["apps", "--json"])
        async let b = Self.vino(["bottles", "--json"])
        async let w = Self.vino(["wines", "--json"])
        async let c = Self.vino(["catalog", "--json"])
        let (ra, rb, rw, rc) = await (a, b, w, c)
        if let v = try? JSONDecoder().decode([CatalogItem].self, from: Data(rc.out.utf8)) { catalog = v }
        if let v = try? JSONDecoder().decode([WinApp].self, from: Data(ra.out.utf8)) { apps = v }
        if let v = try? JSONDecoder().decode([Bottle].self, from: Data(rb.out.utf8)) { bottles = v }
        if let v = try? JSONDecoder().decode([WineBuild].self, from: Data(rw.out.utf8)) { wines = v }
    }

    func bottle(_ name: String) -> Bottle? { bottles.first { $0.name == name } }

    /// Running means its program is running: launchers like Steam exit and leave the real app behind.
    func isRunning(_ app: WinApp) -> Bool { running.contains(app.id) || live.contains(app.id) }

    func installedApp(_ item: CatalogItem) -> WinApp? { apps.first { $0.name.lowercased() == item.app.lowercased() } }

    /// Checks which apps' programs are running. Cheap when a bottle is idle: vino answers without starting Wine.
    func pollRunning() async {
        var now = Set<String>()
        for b in Set(apps.map(\.bottle)) {
            let r = await Self.vino(["ps", "-b", b, "--json"])
            let names = Set(((try? JSONDecoder().decode([Proc].self, from: Data(r.out.utf8))) ?? []).map { $0.name.lowercased() })
            for app in apps where app.bottle == b {
                if let exe = app.exe?.lowercased(), names.contains(exe) { now.insert(app.id) }
            }
        }
        if now != live { live = now }
    }

    /// One click from Get Apps: download (checked against the publisher's checksum) and install silently.
    func get(_ item: CatalogItem) {
        guard !getting.contains(item.name) else { return }
        getting.insert(item.name)
        let job = UUID()
        activities[job] = "Installing \(item.name)…"
        Task {
            let r = await Self.vino(["install", item.file])
            activities[job] = nil
            getting.remove(item.name)
            if r.status != 0 { failure = Failure(title: "Couldn't install \(item.name)", text: r.err.trimmed) }
            else { show(r.out.contains("Unpacked") ? "\(item.name) is ready (unpacked: its installer doesn't run in Wine)" : "\(item.name) is ready") }
            await reload()
        }
    }

    /// Where new installs go when the user hasn't picked a bottle.
    var defaultBottle: String { bottles.contains { $0.name == "default" } ? "default" : bottles.first?.name ?? "default" }

    /// Distinct colours for the first eight bottles; hashing names made neighbours look alike.
    func color(_ bottle: String) -> Color {
        let palette: [Color] = [.teal, .purple, .orange, .pink, .blue, .green, .indigo, .yellow]
        return palette[(bottles.firstIndex { $0.name == bottle } ?? 0) % palette.count]
    }
    func apps(in bottle: String) -> [WinApp] { apps.filter { $0.bottle == bottle } }

    // MARK: actions

    func open(_ app: WinApp, args: [String] = [], debug: Bool = false) {
        guard !running.contains(app.id) else { return }
        running.insert(app.id)
        Task {
            let r = await Self.vino(["run", "-b", app.bottle] + (debug ? ["--debug"] : []) + ["--", app.name] + args)
            running.remove(app.id)
            if r.status != 0 && !quitting.contains(app.id) && !quitting.contains(app.bottle) {
                failure = Failure(title: "\(app.name) stopped with a problem", text: r.err.trimmed)
            }
            await reload()
        }
    }

    func quit(_ app: WinApp) {
        quitting.insert(app.id)
        Task {
            let r = await Self.vino(["quit", "-b", app.bottle, "--", app.name])
            if r.status != 0 { failure = Failure(title: "Couldn't quit \(app.name)", text: r.err.trimmed) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            quitting.remove(app.id)
        }
    }

    func quitAll(_ bottle: String) {
        quitting.insert(bottle)
        Task {
            let r = await Self.vino(["quit", "-b", bottle])
            if r.status != 0 { failure = Failure(title: "Couldn't quit the apps in \(bottle)", text: r.err.trimmed) }
            else { show("Quit everything in \(self.bottle(bottle)?.title ?? bottle)") }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            quitting.remove(bottle)
        }
    }

    func install(_ url: URL, into bottle: String) {
        guard Self.windowsTypes.contains(url.pathExtension.lowercased()) else {
            failure = Failure(title: "That isn't a Windows program", text: "vino opens Windows programs: .exe, .msi and .bat files, and shortcuts (.lnk).")
            return
        }
        let job = UUID()
        activities[job] = "Running \(url.lastPathComponent)… finish the installer to see the app here"
        Task {
            let r = await Self.vino(["run", "-b", bottle, "--", url.path])
            activities[job] = nil
            if r.out.contains("Unpacked") { show("Installed by unpacking it: its installer doesn't run in Wine") }
            if r.status != 0 { failure = Failure(title: "\(url.lastPathComponent) stopped with a problem", text: r.err.trimmed) }
            await reload()
        }
    }

    func chooseInstaller(into bottle: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.windowsTypes.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { install(url, into: bottle) }
    }

    /// Changes a bottle setting. Some take a while (DXVK downloads, Windows version), so the row shows progress.
    func set(_ bottle: String, _ key: String, _ value: String) {
        let tag = bottle + "|" + key
        guard !busy.contains(tag) else { return }
        busy.insert(tag)
        // show the new value right away; reload() brings back the saved one if vino refuses it
        if let i = bottles.firstIndex(where: { $0.name == bottle }) { bottles[i].env[key] = value.isEmpty ? nil : value }
        Task {
            let r = await Self.vino(["set", "-b", bottle, "\(key)=\(value)"])
            if r.status != 0 { failure = Failure(title: "Couldn't change that setting", text: r.err.trimmed) }
            await reload()
            busy.remove(tag)  // only after reload, so the control can't be clicked while it shows a stale value
        }
    }

    func tool(_ bottle: String, _ title: String, _ args: [String]) {
        show("Opening \(title)…")
        Task {
            let r = await Self.vino(["wine", "-b", bottle] + args)
            if r.status != 0 { failure = Failure(title: "\(title) stopped with a problem", text: r.err.trimmed) }
        }
    }

    func newBottle(_ name: String) async -> Bool {
        let job = UUID()
        activities[job] = "Creating \(name)…"
        let r = await Self.vino(["new", "--", name])
        activities[job] = nil
        if r.status != 0 {
            failure = Failure(title: "Couldn't create that bottle", text: r.err.trimmed)
            return false
        }
        await reload()
        return true
    }

    func delete(_ bottle: String) {
        Task {
            let r = await Self.vino(["delete", bottle])
            if r.status != 0 { failure = Failure(title: "Couldn't delete \(bottle)", text: r.err.trimmed) }
            else { show("Moved \(bottle) to the Trash") }
            await reload()
        }
    }

    /// Windows programs running in a bottle (Wine's own background services left out).
    func processes(_ bottle: String) async -> [Proc] {
        let r = await Self.vino(["ps", "-b", bottle, "--json"])
        return (try? JSONDecoder().decode([Proc].self, from: Data(r.out.utf8))) ?? []
    }

    func end(_ bottle: String, _ p: Proc, force: Bool) async {
        quitting.insert(bottle)  // a program the user ended isn't a crash
        let r = await Self.vino(["kill", "-b", bottle, "\(p.pid)"] + (force ? ["--force"] : []))
        if r.status != 0 { failure = Failure(title: "Couldn't end \(p.name)", text: (r.err + r.out).trimmed) }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        quitting.remove(bottle)
    }

    func showFiles(_ bottle: String) {
        Task {
            let r = await Self.vino(["files", "-b", bottle])
            if r.status != 0 { failure = Failure(title: "Couldn't show the files", text: r.err.trimmed) }
        }
    }

    func installed(_ bottle: String) async -> [Program] {
        let r = await Self.vino(["installed", "-b", bottle, "--json"])
        return (try? JSONDecoder().decode([Program].self, from: Data(r.out.utf8))) ?? []
    }

    func size(_ bottle: String) async -> String {
        guard let path = self.bottle(bottle)?.path else { return "" }  // the CLI's path, so it follows $HOME like the CLI does
        let r = await Self.exec("/usr/bin/du", ["-sk", path])
        guard let kb = Int64(r.out.split(separator: "\t").first ?? "") else { return "" }
        return ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .file)
    }

    func apply(_ fix: Fix) async {
        if fix.command == CLI.setupCommand {
            await setUp()
            return
        }
        // a login shell, so commands behave like they do in Terminal
        let r = await Self.exec("/bin/zsh", ["-lc", fix.command])
        if r.status != 0 { failure = Failure(title: "That didn't work", text: (r.err + r.out).trimmed) }
        await refresh()
    }

    /// One click: Rosetta, then vino's own Wine, with progress. Runs in this process so the bar can move.
    func setUp() async {
        setupStatus = "Getting ready…"
        let error: String? = await withCheckedContinuation { cont in
            Thread {
                do {
                    try Setup.install(say: { line in Task { @MainActor in self.setupStatus = line } },
                                      fraction: { f in Task { @MainActor in self.setupProgress = f } })
                    cont.resume(returning: nil)
                } catch {
                    cont.resume(returning: "\(error)")
                }
            }.start()
        }
        setupStatus = nil
        setupProgress = nil
        if let error { failure = Failure(title: "Setup didn't finish", text: error) }
        await refresh()
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if toast == message { toast = nil }
        }
    }

    // MARK: talking to the CLI

    static func vino(_ args: [String]) async -> (status: Int32, out: String, err: String) {
        // this same binary, as the command line, in its own process: `vino run` blocks until the app closes
        await exec(Bundle.main.executablePath ?? CommandLine.arguments[0], args)
    }

    /// Runs a program on its own thread: `vino run` blocks until the app closes, and blocking Swift's shared
    /// thread pool instead would freeze every other call once a few apps are open.
    static func exec(_ tool: String, _ args: [String]) async -> (status: Int32, out: String, err: String) {
        await withCheckedContinuation { cont in
            Thread {
                let p = Process(), out = Pipe(), err = Pipe()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "", error.localizedDescription))
                    return
                }
                // read both pipes at once, or a chatty stderr fills its pipe and both processes wait forever
                var e = Data()
                let done = DispatchSemaphore(value: 0)
                Thread { e = err.fileHandleForReading.readDataToEndOfFile(); done.signal() }.start()
                let o = out.fileHandleForReading.readDataToEndOfFile()
                done.wait()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self)))
            }.start()
        }
    }

    /// `vino doctor` prints "✗ <problem>. Fix…:" followed by an indented command.
    static func parseFixes(_ doctor: String) -> [Fix] {
        var fixes: [Fix] = [], problem: String?
        for line in doctor.components(separatedBy: "\n") {
            if line.hasPrefix("✗ ") {
                let text = String(line.dropFirst(2))
                problem = text.components(separatedBy: ". Fix").first ?? text
            } else if line.hasPrefix("    "), let p = problem {
                fixes.append(Fix(problem: p, command: line.trimmed))
                problem = nil
            }
        }
        return fixes
    }

    /// The last error lines of a log, read from its end so big debug logs stay cheap.
    static func errorLines(_ path: String?, limit: Int = 6) -> [String] {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let end = h.seekToEndOfFile()
        h.seek(toFileOffset: end > 65_536 ? end - 65_536 : 0)
        let lines = String(decoding: h.readDataToEndOfFile(), as: UTF8.self).components(separatedBy: "\n")
        return Array(lines.filter { $0.contains(":err:") }.suffix(limit))
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
