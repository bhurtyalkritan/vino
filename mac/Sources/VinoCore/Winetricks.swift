import Foundation

/// Windows components (Visual C++, .NET, fonts…) installed with Winetricks, which ships inside Vino
/// along with cabextract, which many of its installs need. Winetricks checks its own downloads' checksums.
public enum Winetricks {
    public struct Component {
        public let verb: String
        public let title: String
        public let detail: String
    }

    /// The ones apps most often need, in plain words. Any other Winetricks verb works too.
    public static let components = [
        Component(verb: "vcrun2022", title: "Visual C++ 2015–2022", detail: "Needed by most modern apps and games"),
        Component(verb: "vcrun2013", title: "Visual C++ 2013", detail: "For apps from around 2013–2015"),
        Component(verb: "vcrun2010", title: "Visual C++ 2010", detail: "For older apps and games"),
        Component(verb: "dotnet48", title: ".NET Framework 4.8", detail: "For many desktop apps. Large; takes several minutes"),
        Component(verb: "dotnetdesktop8", title: ".NET Desktop Runtime 8", detail: "For newer .NET apps"),
        Component(verb: "d3dx9", title: "DirectX 9 extras", detail: "For older games that need d3dx9 files"),
        Component(verb: "d3dcompiler_47", title: "DirectX shader compiler", detail: "For games and apps that compile shaders"),
        Component(verb: "xact", title: "XACT audio", detail: "Sound in many older games"),
        Component(verb: "physx", title: "NVIDIA PhysX", detail: "Physics for some games"),
        Component(verb: "corefonts", title: "Microsoft fonts", detail: "Arial, Times New Roman, Verdana and more"),
        Component(verb: "cjkfonts", title: "Chinese, Japanese and Korean fonts", detail: "So Asian text shows instead of boxes"),
    ]

    /// Bundled in Vino.app; $VINO_WINETRICKS or one on the PATH also work.
    static var script: String? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("winetricks").path
        return [ProcessInfo.processInfo.environment["VINO_WINETRICKS"], bundled, Vino.which("winetricks")]
            .compactMap { $0 }.first { Vino.runnable($0) }
    }

    /// What Winetricks has installed in this bottle (it keeps a list in the bottle).
    public static func installed(_ b: URL) -> Set<String> {
        let log = (try? String(contentsOf: b.appendingPathComponent("winetricks.log"), encoding: .utf8)) ?? ""
        return Set(log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Installs components without questions. Output goes to the bottle's logs/winetricks.log.
    static func install(_ b: URL, _ verbs: [String]) throws {
        guard let script else { throw VinoError("Winetricks isn't available") }
        for v in verbs where v.range(of: #"^[A-Za-z0-9_.=-]+$"#, options: .regularExpression) == nil {
            throw VinoError("'\(v)' isn't a Winetricks name, like vcrun2022")
        }
        let benv = Vino.loadEnv(b)
        let wine = try Vino.findWine(b, benv)
        let bin = URL(fileURLWithPath: Vino.realpath(wine)).deletingLastPathComponent()
        var env = Vino.environment(b, benv, debug: "-all")
        env["WINE"] = wine
        env["WINESERVER"] = bin.appendingPathComponent("wineserver").path
        // cabextract sits next to the bundled script; Wine's own folder gives Winetricks wine64 and friends
        let tools = URL(fileURLWithPath: script).deletingLastPathComponent().path
        env["PATH"] = [tools, bin.path, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")

        try FileManager.default.createDirectory(at: b.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let log = b.appendingPathComponent("logs/winetricks.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script, "--unattended"] + verbs
        p.environment = env
        if let fh = FileHandle(forWritingAtPath: log.path) { p.standardOutput = fh; p.standardError = fh }
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Vino.stopped(log, p.terminationStatus) }
    }
}
