import AppKit
@testable import VinoCore
import XCTest

final class CoreTests: XCTestCase {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fixtures/notepad++.lnk").standardized

    func testUnixPath() {
        let b = URL(fileURLWithPath: "/B")
        XCTAssertEqual(Vino.unixPath(b, "C:\\Program Files\\x.exe")?.path, "/B/dosdevices/c:/Program Files/x.exe")
        XCTAssertNil(Vino.unixPath(b, "app.exe"))  // no drive letter: Wine handles it
        XCTAssertNil(Vino.unixPath(b, "\\\\server\\x.exe"))
        XCTAssertEqual(Vino.unixPath(b, "C:\\..\\..\\etc\\passwd")?.path, "/B/dosdevices/c:/etc/passwd")  // can't leave the drive
    }

    func testRegistryEscapes() {
        XCTAssertEqual(Vino.regUnescape(#"Caf\xe9 \x4e2d\x6587 \"q\" a\\b"#), "Café 中文 \"q\" a\\b")
        XCTAssertEqual(Vino.regUnescape(#"App \xd83d\xde00"#), "App 😀")  // emoji arrive as two halves
    }

    func testOverrides() {
        XCTAssertEqual(Vino.overrides([:]), "winemenubuilder.exe=d")
        XCTAssertEqual(Vino.overrides(["VINO_DXVK": "1", "WINEDLLOVERRIDES": "x=n"]), "winemenubuilder.exe=d;d3d11,d3d10core=n,b;x=n")
        XCTAssertEqual(Vino.overrides(["VINO_DXVK": "0"]), "winemenubuilder.exe=d;d3d11,d3d10core=b")
    }

    func testSplitArgs() {
        XCTAssertEqual(Vino.splitArgs(#"-a "C:\Program Files\x" '' b"#), ["-a", #"C:\Program Files\x"#, "", "b"])
    }

    func testRealShortcut() throws {
        let s = try XCTUnwrap(Vino.readLnk(try Data(contentsOf: fixture)))
        XCTAssertEqual(s.target, "C:\\Program Files\\Notepad++\\notepad++.exe")
        XCTAssertEqual(s.workdir, "C:\\Program Files\\Notepad++")
        XCTAssertEqual(s.args, "")
    }

    func testShortcutsVinoWritesReadBack() throws {
        let d = Shortcut.data(target: "C:\\Program Files\\WinMerge\\WinMergeU.exe", workdir: "C:\\Program Files\\WinMerge")
        let s = try XCTUnwrap(Vino.readLnk(d))
        XCTAssertEqual(s.target, "C:\\Program Files\\WinMerge\\WinMergeU.exe")
        XCTAssertEqual(s.workdir, "C:\\Program Files\\WinMerge")
    }

    func testInnoNamesAndMainProgram() throws {
        XCTAssertEqual(Inno.appName(fromInstaller: "WinMerge-2.16.60-x64-Setup"), "WinMerge")
        XCTAssertEqual(Inno.appName(fromInstaller: "Greenshot-INSTALLER-1.3.328-RELEASE"), "Greenshot")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vino-main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (f, size) in [("unins000.exe", 900), ("WinMerge32BitPluginProxy.exe", 50), ("WinMergeU.exe", 100), ("tool.exe", 500)] {
            try Data(count: size).write(to: dir.appendingPathComponent(f))
        }
        XCTAssertEqual(Inno.mainProgram(in: dir, name: "WinMerge")?.lastPathComponent, "WinMergeU.exe")  // named like the app
        XCTAssertEqual(Inno.mainProgram(in: dir, name: "Other")?.lastPathComponent, "tool.exe")  // else the biggest non-helper
    }

    func testBrokenShortcutsNeverCrash() throws {
        let real = [UInt8](try Data(contentsOf: fixture))
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            var d = real
            for _ in 0..<4 { d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = Vino.readLnk(Data(d.prefix(Int.random(in: 0...d.count, using: &rng))))
        }
        XCTAssertNil(Vino.readLnk(Data()))
    }

    /// The single-download promise: vino fetches Wine itself, and macOS lets it run.
    func testDownloadWine() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VINO_TEST_DOWNLOAD"] == "1", "downloads 185 MB; run with VINO_TEST_DOWNLOAD=1")
        let oldHome = ProcessInfo.processInfo.environment["HOME"]!
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vino-download-\(UUID().uuidString)")
        setenv("HOME", home.path, 1)
        defer { setenv("HOME", oldHome, 1); try? FileManager.default.removeItem(at: home) }

        var last = 0.0
        try Setup.downloadWine(say: { print($0) }, fraction: { last = $0 })
        XCTAssertEqual(last, 1, accuracy: 0.01)
        XCTAssertTrue(Vino.ownWine.hasPrefix(home.path))
        XCTAssertNotNil(Setup.wineVersion(Vino.ownWine), "vino's own Wine should start")
        // vino's own download carries no quarantine flag, so Gatekeeper never stops it
        XCTAssertEqual(getxattr(Vino.ownWine, "com.apple.quarantine", nil, 0, 0, 0), -1)
    }

    func testIconFromWindowsProgram() throws {
        let exe = URL(fileURLWithPath: "/Applications/Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-windows/notepad.exe")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: exe.path), "needs Wine installed")
        let png = try XCTUnwrap(Icons.png(from: exe))
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThanOrEqual(image.pixelsWide, 32)
        XCTAssertNil(Icons.icoFromPE(Data("MZ not really a program".utf8), index: 0))
        XCTAssertNil(Icons.icoFromPE(Data(), index: 0))
    }
}
