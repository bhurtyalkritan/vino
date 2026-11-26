import Foundation

/// Installs what vino needs, so the app is the only download: Rosetta, then its own copy of Wine.
public enum Setup {
    // vino-wine (github.com/bhurtyalkritan/vino-wine): CodeWeavers' CrossOver Wine with MSync; checksum from its release
    static let wine = (url: "VINO_WINE_URL",
                       sha256: "VINO_WINE_SHA256")

    public static var needsRosetta: Bool {
        var arm: Int32 = 0, size = MemoryLayout<Int32>.size
        let apple = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1  // true even if vino itself runs under Rosetta
        return apple && Vino.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) != 0
    }

    /// `wine --version`, or nil when that Wine can't start (missing, broken, or blocked by macOS).
    public static func wineVersion(_ w: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: w)
        p.arguments = ["--version"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { p.terminate() }  // a Gatekeeper prompt can hold it open
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeout.cancel()
        let v = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !v.isEmpty ? v : nil
    }

    /// Rosetta if missing, then Wine unless a working one exists. `say` gets progress lines; `fraction` the download's progress.
    public static func install(say: @escaping (String) -> Void, fraction: ((Double) -> Void)? = nil) throws {
        if needsRosetta {
            say("Installing Rosetta…")
            guard Vino.run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"]) == 0, !needsRosetta else {
                throw VinoError("couldn't install Rosetta. Try: softwareupdate --install-rosetta --agree-to-license")
            }
        }
        if let w = Vino.wineBuilds().first(where: { wineVersion($0) != nil }) {
            say("Wine is ready: \(w)")
            return
        }
        // shortcut: vino-wine has no release yet, so a missing Wine can't be fixed automatically; set its URL once released
        guard !wine.url.hasPrefix("VINO_WINE") else { throw VinoError("vino-wine isn't released yet. Install Wine for now with: brew install --cask gcenx/wine/wine-stable") }
        try downloadWine(say: say, fraction: fraction)
        guard let v = wineVersion(Vino.ownWine) else { throw VinoError("Wine was installed but won't start: \(Vino.ownWine)") }
        say("Wine is ready: \(v)")
    }

    static func downloadWine(say: @escaping (String) -> Void, fraction: ((Double) -> Void)?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Vino.support, withIntermediateDirectories: true)
        let archive = Vino.support.appendingPathComponent("wine-download.tar.xz")
        defer { try? fm.removeItem(at: archive) }
        say("Downloading vino-wine…")
        var lastShown = -1
        try Download.file(URL(string: wine.url)!, to: archive) { f in
            fraction?(f)
            let pct = Int(f * 100)
            if pct / 10 != lastShown / 10 { lastShown = pct; say("Downloading Wine… \(pct)%") }
        }
        say("Checking the download…")
        guard try Vino.sha256(file: archive) == wine.sha256 else { throw VinoError("the Wine download doesn't match its checksum, not installing it") }
        say("Unpacking Wine…")
        let fresh = Vino.support.appendingPathComponent("wine.new"), final = Vino.support.appendingPathComponent("wine")
        try? fm.removeItem(at: fresh)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        guard Vino.run("/usr/bin/tar", ["-xJf", archive.path, "-C", fresh.path]) == 0,
              Vino.runnable(fresh.appendingPathComponent("vino-wine/bin/wine").path) else {
            try? fm.removeItem(at: fresh)
            throw VinoError("couldn't unpack Wine")
        }
        try? fm.removeItem(at: final)
        try fm.moveItem(at: fresh, to: final)
    }
}

/// Downloads a file with progress. Files vino downloads itself aren't flagged by Gatekeeper, unlike a browser download.
enum Download {
    final class Delegate: NSObject, URLSessionDownloadDelegate {
        let dest: URL
        let progress: (Double) -> Void
        var error: Error?
        let done = DispatchSemaphore(value: 0)
        init(dest: URL, progress: @escaping (Double) -> Void) { self.dest = dest; self.progress = progress }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                error = VinoError("the server answered \(http.statusCode)")
                return
            }
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: location, to: dest) } catch { self.error = error }  // must move before returning
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { self.error = error }
            done.signal()
        }
    }

    static func file(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) throws {
        let d = Delegate(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        d.done.wait()
        session.finishTasksAndInvalidate()
        if let e = d.error { throw VinoError("couldn't download \(url.lastPathComponent): \(e.localizedDescription)") }
    }
}
