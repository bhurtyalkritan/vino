import AppKit
import Foundation

/// App icons, read out of the Windows program itself, like Windows does.
public enum Icons {
    /// A cached PNG of the app's icon, extracted the first time (and again when the shortcut changes). nil when it has none.
    public static func cached(_ app: Vino.App) -> String? {
        let fm = FileManager.default
        let dir = app.bottle.appendingPathComponent("icons")
        let base = Vino.logName(app.name).dropLast(4)  // same safe file name as the app's log
        let png = dir.appendingPathComponent(base + ".png"), none = dir.appendingPathComponent(base + ".none")
        let changed = modified(app.shortcut) ?? .distantPast
        if let t = modified(png), t >= changed { return png.path }
        if let t = modified(none), t >= changed { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = extract(app), (try? data.write(to: png)) != nil { return png.path }
        fm.createFile(atPath: none.path, contents: nil)  // remember there's none, so listing stays fast
        return nil
    }

    static func modified(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    static func extract(_ app: Vino.App) -> Data? {
        guard let d = try? Data(contentsOf: app.shortcut), let s = Vino.readLnk(d) else { return nil }
        // the shortcut's own icon wins; otherwise the program it opens
        var sources: [(URL, Int32)] = []
        if !s.iconLocation.isEmpty, let u = Vino.unixPath(app.bottle, s.iconLocation) { sources.append((u, s.iconIndex)) }
        if let t = s.target, let u = Vino.unixPath(app.bottle, t) { sources.append((u, 0)) }
        return sources.lazy.compactMap { png(from: $0.0, index: $0.1) }.first
    }

    /// The largest image of an .ico file, or of an .exe/.dll's icon group number `index`
    /// (a negative index means the group with that resource ID, as in Windows).
    public static func png(from file: URL, index: Int32 = 0) -> Data? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        let ico = file.pathExtension.lowercased() == "ico" ? data : icoFromPE(data, index: index)
        guard let ico, let image = NSImage(data: ico) else { return nil }
        let reps = image.representations
        guard let biggest = reps.max(by: { $0.pixelsWide < $1.pixelsWide }), biggest.pixelsWide > 0 else { return nil }
        if let bitmap = biggest as? NSBitmapImageRep { return bitmap.representation(using: .png, properties: [:]) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: biggest.pixelsWide, pixelsHigh: biggest.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        biggest.draw(in: NSRect(x: 0, y: 0, width: biggest.pixelsWide, height: biggest.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Rebuilds an .ico file from a Windows program's icon resources (RT_GROUP_ICON plus the RT_ICON images it lists).
    static func icoFromPE(_ d: Data, index: Int32) -> Data? {
        let base = d.startIndex
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= d.count ? Int(d[base + o]) | Int(d[base + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { guard let lo = u16(o), let hi = u16(o + 2) else { return nil }; return lo | hi << 16 }

        guard u16(0) == 0x5A4D, let pe = u32(0x3C), u32(pe) == 0x4550,  // "MZ", then "PE\0\0"
              let sections = u16(pe + 6), let optSize = u16(pe + 20), let magic = u16(pe + 24) else { return nil }
        let opt = pe + 24
        guard let resRVA = u32(opt + (magic == 0x20B ? 112 : 96) + 2 * 8), resRVA != 0 else { return nil }  // data directory 2 = resources
        let table = opt + optSize
        func offset(_ rva: Int) -> Int? {
            for i in 0..<min(sections, 96) {
                let s = table + 40 * i
                guard let vsize = u32(s + 8), let va = u32(s + 12), let raw = u32(s + 16), let ptr = u32(s + 20) else { return nil }
                if rva >= va && rva < va + max(vsize, raw) { return ptr + rva - va }
            }
            return nil
        }
        guard let root = offset(resRVA) else { return nil }

        struct Entry { let id: Int; let named: Bool; let target: Int; let isDir: Bool }
        func entries(_ dir: Int) -> [Entry] {
            guard let named = u16(dir + 12), let ids = u16(dir + 14) else { return [] }
            return (0..<min(named + ids, 4096)).compactMap { k in
                let e = dir + 16 + 8 * k
                guard let name = u32(e), let data = u32(e + 4) else { return nil }
                return Entry(id: name & 0x7FFF_FFFF, named: name & 0x8000_0000 != 0, target: root + (data & 0x7FFF_FFFF), isDir: data & 0x8000_0000 != 0)
            }
        }
        func leaf(_ e: Entry, depth: Int = 0) -> Data? {  // first language of a resource
            if e.isDir { return depth < 4 ? entries(e.target).first.flatMap { leaf($0, depth: depth + 1) } : nil }
            guard let rva = u32(e.target), let size = u32(e.target + 4), let o = offset(rva), o + size <= d.count else { return nil }
            return d.subdata(in: (base + o)..<(base + o + size))
        }

        let types = entries(root).filter { !$0.named }
        guard let iconDir = types.first(where: { $0.id == 3 }), let groupDir = types.first(where: { $0.id == 14 }) else { return nil }
        let groups = entries(groupDir.target)
        let chosen = index < 0 ? groups.first { !$0.named && $0.id == Int(-index) } : (Int(index) < groups.count ? groups[Int(index)] : nil)
        guard let group = (chosen ?? groups.first).flatMap({ leaf($0) }) else { return nil }
        var images: [Int: Data] = [:]
        for e in entries(iconDir.target) where !e.named { images[e.id] = leaf(e) }

        let g = [UInt8](group)
        guard g.count >= 6 else { return nil }
        let count = min(Int(g[4]) | Int(g[5]) << 8, 64)
        var dirBytes: [UInt8] = [], blobs: [Data] = []
        for i in 0..<count {
            let e = 6 + 14 * i
            guard e + 14 <= g.count, let img = images[Int(g[e + 12]) | Int(g[e + 13]) << 8] else { continue }
            dirBytes += g[e..<(e + 8)]  // width, height, colours, reserved, planes, bits per pixel
            dirBytes += le32(img.count)
            blobs.append(img)
        }
        guard !blobs.isEmpty else { return nil }
        var ico = Data([0, 0, 1, 0, UInt8(blobs.count & 0xFF), UInt8(blobs.count >> 8)])
        var offset32 = 6 + 16 * blobs.count
        for (i, img) in blobs.enumerated() {
            ico.append(contentsOf: dirBytes[(12 * i)..<(12 * i + 12)])
            ico.append(contentsOf: le32(offset32))
            offset32 += img.count
        }
        blobs.forEach { ico.append($0) }
        return ico
    }

    static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
}
