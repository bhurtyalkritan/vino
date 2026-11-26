import Foundation

/// Fallback for Inno Setup installers whose installer program won't run in Wine (it crashes on this Wine build):
/// unpack them with innoextract, put the app in C:\Program Files, and give it a Start Menu shortcut.
/// The installer's own extra steps (registry, runtimes, file types) are skipped, so this is only a fallback.
enum Inno {
    static func isInstaller(_ file: URL) -> Bool {
        guard let d = try? Data(contentsOf: file, options: .alwaysMapped) else { return false }
        return d.range(of: Data("Inno Setup Setup Data (".utf8)) != nil
    }

    /// innoextract ships inside Vino.app; $VINO_INNOEXTRACT or one on the PATH also work.
    static var tool: String? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("innoextract").path
        return [ProcessInfo.processInfo.environment["VINO_INNOEXTRACT"], bundled, Vino.which("innoextract")]
            .compactMap { $0 }.first { Vino.runnable($0) }
    }

    /// "WinMerge-2.16.60-x64-Setup" -> "WinMerge"
    static func appName(fromInstaller stem: String) -> String {
        let noise: Set<String> = ["setup", "installer", "install", "release", "x64", "x86", "win64", "win32", "64bit", "32bit", "amd64", "full"]
        let words = stem.split(whereSeparator: { "-_ .".contains($0) }).map(String.init)
            .filter { !noise.contains($0.lowercased()) && $0.range(of: #"^v?\d"#, options: .regularExpression) == nil }  // drops versions
        return words.isEmpty ? stem : words.joined(separator: " ")
    }

    /// The app's main program among the unpacked files: a top-level .exe that isn't an uninstaller or helper,
    /// preferring one named like the app, then the biggest.
    static func mainProgram(in dir: URL, name: String) -> URL? {
        let skip = ["unins", "setup", "proxy", "update", "crash", "helper", "install", "elevate", "launcher-"]
        let exes = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "exe" }
            .filter { e in !skip.contains { e.lastPathComponent.lowercased().contains($0) } }
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return exes.first { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(key) } ?? exes.max { size($0) < size($1) }
    }

    /// Unpacks `installer` into the bottle and adds a Start Menu shortcut. Returns the shortcut's name.
    static func unpack(_ installer: URL, into b: URL, name: String) throws -> String {
        guard let tool else { throw VinoError("the installer failed, and innoextract isn't available to unpack it instead") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("vino-inno-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // installers can hold alternative copies of a file (like 32- and 64-bit); keep the last instead of failing
        guard Vino.run(tool, ["--silent", "--collisions", "overwrite", "-d", tmp.path, installer.path]) == 0 else {
            throw VinoError("couldn't unpack \(installer.lastPathComponent)")
        }
        let app = tmp.appendingPathComponent("app")
        guard let exe = mainProgram(in: app, name: name) else { throw VinoError("unpacked \(installer.lastPathComponent), but found no program in it") }

        let folder = name.replacingOccurrences(of: "/", with: "-")
        let dest = b.appendingPathComponent("drive_c/Program Files/\(folder)")
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: app, to: dest)

        let menu = b.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs")
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        let target = "C:\\Program Files\\\(folder)\\\(exe.lastPathComponent)"
        try Shortcut.data(target: target, workdir: "C:\\Program Files\\\(folder)").write(to: menu.appendingPathComponent("\(folder).lnk"))
        return folder
    }
}

/// Writes a minimal Windows shortcut (MS-SHLLINK): a local target path plus its working folder.
enum Shortcut {
    static func data(target: String, workdir: String) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16 & 0xFFFF) }

        // header: size, the shortcut class ID, flags (has link info, has working dir, unicode strings)
        u32(0x4C)
        d.append(contentsOf: [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46])
        u32(0x02 | 0x10 | 0x80)
        u32(0x20)  // a normal file
        d.append(Data(count: 24))  // creation, access, write times
        u32(0)  // file size
        u32(0)  // icon index
        u32(1)  // show normally
        u16(0); u16(0); u32(0); u32(0)  // hot key, reserved

        // link info: a volume ID, then the local path (ANSI) and an empty suffix
        let volume: [UInt8] = [0x11, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 0]  // size 17, fixed disk, serial 0, empty label
        let path = Array(target.utf8) + [0]
        let headerSize = 0x1C
        let size = headerSize + volume.count + path.count + 1
        u32(size)
        u32(headerSize)
        u32(1)  // has a volume ID and local base path
        u32(headerSize)  // volume ID offset
        u32(headerSize + volume.count)  // local base path offset
        u32(0)  // no network path
        u32(headerSize + volume.count + path.count)  // common path suffix offset
        d.append(contentsOf: volume)
        d.append(contentsOf: path)
        d.append(0)

        // working folder, as UTF-16 with a count of characters
        let wide = Array(workdir.utf16)
        u16(wide.count)
        for c in wide { u16(Int(c)) }
        u32(0)  // no extra data blocks
        return d
    }
}
