import AppKit
import SwiftUI
import VinoCore

// The "Glass" design: a frosted window the desktop shows through, a violet accent, soft cards.

enum Place: Hashable {
    case all
    case store
    case bottle(String)
}

// MARK: - Theme

extension Color {
    /// One colour for light mode, another for dark.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    static let accent = Color.dynamic(rgb(106, 75, 230), rgb(160, 140, 255))
    static let accentSoft = Color.dynamic(rgb(106, 75, 230, 0.12), rgb(160, 140, 255, 0.16))
    static let onAccent = Color.dynamic(.white, rgb(23, 18, 46))
    static let pane = Color.dynamic(rgb(250, 250, 253, 0.55), rgb(32, 31, 40, 0.5))
    static let side = Color.dynamic(rgb(240, 239, 246, 0.35), rgb(24, 23, 31, 0.35))
    static let card = Color.dynamic(rgb(255, 255, 255, 0.78), rgb(255, 255, 255, 0.055))
    static let segOn = Color.dynamic(.white, rgb(255, 255, 255, 0.14))
    static let line = Color.dynamic(rgb(20, 15, 40, 0.09), rgb(255, 255, 255, 0.08))
    static let hover = Color.dynamic(rgb(20, 15, 40, 0.05), rgb(255, 255, 255, 0.06))
    static let ok = Color.dynamic(rgb(31, 154, 87), rgb(63, 208, 139))
    static let info = Color.dynamic(rgb(47, 125, 225), rgb(106, 168, 255))
    static let bad = Color.dynamic(rgb(214, 59, 44), rgb(255, 111, 96))
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: Model
    @State private var place: Place = .all
    @State private var appID: String?
    @State private var query = ""
    @State private var dropping = false
    @State private var newBottle = false

    /// Where a dropped installer or the Add button installs to.
    private var target: String {
        if let id = appID, let app = model.apps.first(where: { $0.id == id }) { return app.bottle }
        if case .bottle(let b) = place { return b }
        return model.defaultBottle
    }

    var body: some View {
        Group {
            if let fixes = model.fixes, !fixes.isEmpty {
                SetupView(fixes: fixes)
            } else if model.fixes == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                main
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop().ignoresSafeArea())
        .tint(Theme.accent)
        .overlay(alignment: .bottom) { Pill() }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2.5)
                    .background(Theme.accentSoft.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
                    .padding(8)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            let into = target
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.install(url, into: into) } }
                }
            }
            return true
        }
        .sheet(item: $model.failure) { FailureView(failure: $0) }
        .sheet(isPresented: Binding(get: { model.opening != nil && model.fixes?.isEmpty == true }, set: { if !$0 { model.opening = nil } })) {
            if let url = model.opening { OpenFileSheet(url: url) }
        }
        .sheet(isPresented: $newBottle) { NewBottleSheet { name in place = .bottle(name); appID = nil } }
        .task {
            await model.refresh()
            await snapshotIfAsked()
        }
        .task {
            while !Task.isCancelled {  // keep "Running" true to what's actually running
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if model.fixes?.isEmpty == true { await model.pollRunning() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.fixes?.isEmpty == true { Task { await model.reload() } }
        }
    }

    private var main: some View {
        HStack(spacing: 0) {
            Sidebar(place: $place, appID: $appID, query: $query, newBottle: $newBottle)
                .frame(width: 224)
            Rectangle().fill(Theme.line).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pane)
        }
        .ignoresSafeArea()  // run under the hidden title bar, like the mockup
    }

    @ViewBuilder private var detail: some View {
        if let id = appID, let app = model.apps.first(where: { $0.id == id }) {
            AppPage(app: app, place: $place, appID: $appID)
        } else {
            switch place {
            case .all: AllAppsPage(query: query) { appID = $0.id }
            case .store: StorePage { appID = $0.id }
            case .bottle(let b): BottlePage(name: b, select: { appID = $0.id }, onDelete: { place = .all; appID = nil })
            }
        }
    }

    /// For screenshots and tests: VINO_START=bottle:NAME or app:BOTTLE/NAME picks the first screen,
    /// VINO_SNAPSHOT=/path.png saves the window there and quits. Works even when the window is on another Space.
    private func snapshotIfAsked() async {
        let env = ProcessInfo.processInfo.environment
        if let start = env["VINO_START"] {
            if start == "store" { place = .store }
            if start.hasPrefix("bottle:") { place = .bottle(String(start.dropFirst(7))) }
            if start.hasPrefix("app:"), let app = model.apps.first(where: { $0.id == start.dropFirst(4) }) {
                place = .bottle(app.bottle)
                appID = app.id
            }
        }
        guard let out = env["VINO_SNAPSHOT"] else { return }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: Model
    @Binding var place: Place
    @Binding var appID: String?
    @Binding var query: String
    @Binding var newBottle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 46)  // room for the window's buttons
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search apps", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 12)
            .onChange(of: query) { q in if !q.isEmpty { place = .all; appID = nil } }

            label("Library")
            NavItem(title: "All Apps", count: model.apps.count, selected: place == .all) {
                Image(systemName: "square.grid.2x2").font(.system(size: 13))
            } action: { place = .all; appID = nil }
            NavItem(title: "Get Apps", count: nil, selected: place == .store) {
                Image(systemName: "bag").font(.system(size: 13))
            } action: { place = .store; appID = nil }

            label("Bottles")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.bottles) { b in
                        NavItem(title: b.title, count: model.apps(in: b.name).count, selected: place == .bottle(b.name)) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(model.color(b.name)).frame(width: 10, height: 10)
                        } action: { place = .bottle(b.name); appID = nil }
                    }
                }
            }
            Spacer(minLength: 8)
            NavItem(title: "New Bottle", count: nil, selected: false, muted: true) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            } action: { newBottle = true }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .background(Theme.side)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }
}

struct NavItem<Icon: View>: View {
    let title: String
    let count: Int?
    let selected: Bool
    var muted = false
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon().frame(width: 16)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .foregroundStyle(selected ? Theme.accent : muted && !hover ? Color.secondary : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Theme.accentSoft : hover ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Shared pieces

/// A scrolling page with the mockup's margins.
struct Page<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content() }
                .padding(.horizontal, 30)
                .padding(.top, 46)
                .padding(.bottom, 80)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An inset-grouped card: a small title, rows with hairlines between them, an optional note under it.
struct Card<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            _VariadicView.Tree(Divided()) { content() }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Puts a hairline between each row of a card.
struct Divided: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != children.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14) }
            }
        }
    }
}

/// A setting row: title and explanation on the left, its control on the right.
struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    var mono = false
    var busy = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11.5, design: mono ? .monospaced : .default)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            control().disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
    }
}

/// The mockup's buttons: soft grey by default, violet for the main action, red for destructive ones.
struct PillButton: ButtonStyle {
    enum Kind { case plain, primary, danger, solidDanger }
    var kind = Kind.plain
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .padding(.horizontal, large ? 18 : 13)
            .padding(.vertical, large ? 9 : 7)
            .foregroundStyle(kind == .primary ? Theme.onAccent : kind == .danger ? Theme.bad : kind == .solidDanger ? Color.white : Color.primary)
            .background(kind == .primary ? Theme.accent : kind == .solidDanger ? Theme.bad : Theme.hover,
                        in: RoundedRectangle(cornerRadius: large ? 9 : 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// The mockup's segmented control.
struct Seg: View {
    let options: [String]
    let selected: Int
    let pick: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(options[i])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(i == selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(i == selected ? Theme.segOn : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(i == selected ? 0.12 : 0), radius: 1.5, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

extension View {
    func chip(_ tint: Color) -> some View {
        font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

struct ChipStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.chip(tint).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - All apps

struct AllAppsPage: View {
    @EnvironmentObject var model: Model
    let query: String
    let select: (WinApp) -> Void

    var body: some View {
        let list = query.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if model.apps.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                DropHere(bottle: model.defaultBottle).padding(.top, 22)
            }
            .padding(.horizontal, 30)
            .padding(.top, 46)
            .padding(.bottom, 30)
        } else {
            Page {
                header
                if list.isEmpty {
                    Text("No app called “\(query)”. Drop its installer here to add it.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(model.bottles) { b in
                    let apps = list.filter { $0.bottle == b.name }
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(model.color(b.name)).frame(width: 8, height: 8)
                                Text(b.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            TileGrid(apps: apps, select: select)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All Apps").font(.system(size: 22, weight: .semibold))
                Text(model.apps.isEmpty ? "Nothing installed yet"
                     : "\(model.apps.count) app\(model.apps.count == 1 ? "" : "s") in \(model.bottles.count) bottle\(model.bottles.count == 1 ? "" : "s") · drop an installer anywhere to add one")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.chooseInstaller(into: model.defaultBottle) } label: { Label("Add App", systemImage: "plus") }
                .buttonStyle(PillButton(kind: .primary))
        }
    }
}

struct TileGrid: View {
    let apps: [WinApp]
    let select: (WinApp) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 22) {
            ForEach(apps) { app in Tile(app: app) { select(app) } }
        }
    }
}

struct Tile: View {
    @EnvironmentObject var model: Model
    let app: WinApp
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        let running = model.isRunning(app)
        Button(action: select) {
            VStack(spacing: 8) {
                AppIcon(name: app.name, size: 62, icon: app.icon)
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: 96)
                HStack(spacing: 5) {
                    if running { LiveDot(); Text("Running") }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(height: 13)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(hover ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hover && !running {
                Button { model.open(app) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 26, height: 26)
                        .background(Theme.accent, in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .help("Open \(app.name)")
                .padding(.top, 4)
                .padding(.trailing, 12)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contextMenu {
            Button("Open") { model.open(app) }
            Button("Settings") { select() }
            Divider()
            Button("Show Files in Finder") { model.showFiles(app.bottle) }
        }
        .accessibilityLabel(app.name)
    }
}

struct LiveDot: View {
    var body: some View {
        Circle().fill(Theme.ok).frame(width: 6, height: 6)
            .overlay(Circle().stroke(Theme.ok.opacity(0.25), lineWidth: 3))
    }
}

struct AppIcon: View {
    let name: String
    let size: CGFloat
    var icon: String? = nil

    var body: some View {
        if let icon, let image = IconCache.image(icon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
        } else {
            let h = Palette.hue(name)
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(hue: h, saturation: 0.42, brightness: 0.98),
                                              Color(hue: (h + 0.055).truncatingRemainder(dividingBy: 1), saturation: 0.66, brightness: 0.8)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white))
                .frame(width: size, height: size)
                .shadow(color: Color(hue: h, saturation: 0.6, brightness: 0.5).opacity(0.3), radius: size * 0.1, y: size * 0.05)
        }
    }
}

/// Icons are drawn often; load each PNG once.
enum IconCache {
    static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

enum Palette {
    /// Stable per name (String.hashValue changes every launch).
    static func hue(_ s: String) -> Double {
        Double(s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }
}

struct DropHere: View {
    @EnvironmentObject var model: Model
    let bottle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("Drop a Windows app or installer here").font(.system(size: 15, weight: .medium))
            Button("or choose a file…") { model.chooseInstaller(into: bottle) }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 6]))
            .foregroundStyle(.tertiary))
    }
}

// MARK: - Get Apps

struct StorePage: View {
    @EnvironmentObject var model: Model
    let open: (WinApp) -> Void

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 2) {
                Text("Get Apps").font(.system(size: 22, weight: .semibold))
                Text("Windows apps that install with one click. Each download comes from its publisher and is checked against the checksum they publish.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(model.catalog) { item in StoreCard(item: item, open: open) }
            }
            if model.catalog.isEmpty {
                Text("The catalog is empty.").foregroundStyle(.secondary)
            }
        }
    }
}

struct StoreCard: View {
    @EnvironmentObject var model: Model
    let item: CatalogItem
    let open: (WinApp) -> Void

    var body: some View {
        let installed = model.installedApp(item)
        HStack(spacing: 14) {
            if let installed {
                AppIcon(name: item.name, size: 46, icon: installed.icon)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hue: Palette.hue(item.name), saturation: 0.42, brightness: 0.98),
                                                  Color(hue: Palette.hue(item.name), saturation: 0.66, brightness: 0.78)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Image(systemName: item.symbol ?? "app").font(.system(size: 20, weight: .medium)).foregroundStyle(.white))
                    .frame(width: 46, height: 46)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 14, weight: .semibold))
                Text(item.summary ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                if let size = item.size, installed == nil {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let installed {
                Button("Open") { open(installed) }.buttonStyle(PillButton())
            } else if model.getting.contains(item.name) {
                ProgressView().controlSize(.small).frame(width: 52)
            } else {
                Button("Get") { model.get(item) }.buttonStyle(PillButton(kind: .primary))
            }
        }
        .padding(14)
        .frame(minHeight: 96)  // cards in a row line up whether or not they show a size
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

// MARK: - App page

struct AppPage: View {
    @EnvironmentObject var model: Model
    let app: WinApp
    @Binding var place: Place
    @Binding var appID: String?
    @State private var options = false

    var body: some View {
        Page {
            Button { appID = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(backTitle)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -14)

            hero
            activity
            AppSettingsCard(app: app).id(app.id)
            BottleSettings(name: app.bottle, onDelete: { place = .all; appID = nil })
        }
        .sheet(isPresented: $options) { OpenOptions(app: app) }
    }

    private var backTitle: String {
        if case .bottle(let b) = place { return model.bottle(b)?.title ?? b }
        return "All Apps"
    }

    private var hero: some View {
        HStack(spacing: 18) {
            AppIcon(name: app.name, size: 76, icon: app.icon)
            VStack(alignment: .leading, spacing: 8) {
                Text(app.name).font(.system(size: 26, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    switch app.last?.code {
                    case nil: Text("Not opened yet").chip(.secondary)
                    case 0: Text("Worked last time").chip(Theme.ok)
                    default: Text("Had a problem last time").chip(Theme.bad)
                    }
                    Button { place = .bottle(app.bottle); appID = nil } label: {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2.5).fill(model.color(app.bottle)).frame(width: 8, height: 8)
                            Text("\(model.bottle(app.bottle)?.title ?? app.bottle) bottle")
                        }
                    }
                    .buttonStyle(ChipStyle(tint: .secondary))
                }
            }
            Spacer(minLength: 12)
            if model.isRunning(app) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) { LiveDot(); Text("Running") }.chip(Theme.ok)
                    Button { model.quit(app) } label: { Label("Quit", systemImage: "stop.fill") }.buttonStyle(PillButton())
                }
            } else {
                HStack(spacing: 0) {
                    Button { model.open(app) } label: {
                        Label("Open", systemImage: "play.fill").padding(.horizontal, 18).padding(.vertical, 9).contentShape(Rectangle())
                    }
                    Rectangle().fill(Theme.onAccent.opacity(0.25)).frame(width: 1, height: 22)
                    Button { options = true } label: {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                    }
                    .help("Open with options")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .fixedSize()
            }
        }
    }

    @ViewBuilder private var activity: some View {
        if let last = app.last {
            let errors = last.code == 0 ? [] : Model.errorLines(app.log)
            Card(title: "Activity", note: errors.isEmpty ? nil : "Crashes in graphics code often go away with a different DirectX setting below.") {
                HStack(spacing: 10) {
                    Circle().fill(last.code == 0 ? Theme.ok : Theme.bad).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last used \(Self.relative(last.time))").font(.system(size: 13, weight: .medium))
                        Text(last.code == 0 ? "Closed normally" : "Stopped with exit status \(last.code)")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("View Log") { if let log = app.log { NSWorkspace.shared.open(URL(fileURLWithPath: log)) } }
                        .buttonStyle(PillButton())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if !errors.isEmpty {
                    ScrollView(.horizontal) {
                        Text(errors.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    static func relative(_ t: Double) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }
}

struct OpenOptions: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    let app: WinApp
    @State private var args = ""
    @State private var debug = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open \(app.name) with Options").font(.headline)
            TextField("Arguments, like -windowed -nosplash", text: $args)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
            Toggle("Log everything, for a bug report", isOn: $debug)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PillButton())
                Button("Open") {
                    // shortcut: splits on spaces; quoted arguments with spaces aren't supported yet
                    model.open(app, args: args.split(separator: " ").map(String.init), debug: debug)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButton(kind: .primary))
            }
        }
        .padding(22)
        .frame(width: 420)
        .tint(Theme.accent)
    }
}

// MARK: - Bottle page

struct BottlePage: View {
    @EnvironmentObject var model: Model
    let name: String
    let select: (WinApp) -> Void
    let onDelete: () -> Void
    @State private var size = ""

    var body: some View {
        if let b = model.bottle(name) {
            let apps = model.apps(in: name)
            Page {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(model.color(name))
                        .overlay(Image(systemName: "shippingbox.fill").font(.system(size: 21)).foregroundStyle(.white))
                        .frame(width: 52, height: 52)
                        .shadow(color: model.color(name).opacity(0.35), radius: 8, y: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(.system(size: 22, weight: .semibold))
                        Text("\(apps.count) app\(apps.count == 1 ? "" : "s") · \(Self.windowsName(b.env["VINO_WINVER"]))\(size.isEmpty ? "" : " · \(size)")")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.chooseInstaller(into: name) } label: { Label("Install into \(b.title)", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PillButton(kind: .primary))
                }
                if apps.isEmpty {
                    Text("Nothing installed yet. Drop an installer here.").foregroundStyle(.secondary).padding(.vertical, 20)
                } else {
                    TileGrid(apps: apps, select: select)
                }
                BottleSettings(name: name, onDelete: onDelete)
            }
            .task(id: "\(name)|\(apps.count)") { size = ""; size = await model.size(name) }
            .id(name)  // fresh state per bottle, so one bottle's size never shows on another
        } else {
            Text("This bottle is gone.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func windowsName(_ code: String?) -> String {
        BottleSettings.windows.first { $0.1 == (code ?? "win10") }?.0 ?? "Windows 10"
    }
}

// MARK: - Settings shared by app and bottle pages

struct BottleSettings: View {
    @EnvironmentObject var model: Model
    let name: String
    let onDelete: () -> Void
    @State private var programs: [Program] = []
    @State private var confirmDelete = false
    @State private var panel: Panel?

    enum Panel: String, Identifiable {
        case controllers, tasks, components
        var id: String { rawValue }
    }

    static let windowSizes = ["1024x768", "1280x800", "1440x900", "1920x1080"]

    static let windows = [("Windows 11", "win11"), ("Windows 10", "win10"), ("Windows 8.1", "win81"), ("Windows 7", "win7"), ("Windows XP", "winxp")]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            graphicsCard
            windowsCard
            developerCard
            toolsCard
            installedCard
            bottleCard
        }
    }

    private var env: [String: String] { model.bottle(name)?.env ?? [:] }
    private var title: String { model.bottle(name)?.title ?? name }
    private var count: Int { model.apps(in: name).count }
    private var dxvk: Bool { env["VINO_DXVK"] == "1" }

    private var graphicsCard: some View {
    Card(title: "Graphics and Input",
         note: "Applies to \(count == 1 ? "the one app" : count == 0 ? "every app" : "all \(count) apps") in \(title). DXVK handles DirectX 10 and 11; Built-in handles everything older.") {
        Row(title: "DirectX", detail: "How Windows graphics are turned into Metal", busy: busy("VINO_DXVK")) {
            Seg(options: ["Built-in", "DXVK"], selected: dxvk ? 1 : 0) { model.set(name, "VINO_DXVK", $0 == 1 ? "1" : "0") }
        }
        Row(title: "Retina resolution", detail: "Sharper text and images. Games may run slower.", busy: busy("VINO_RETINA")) {
            toggle("VINO_RETINA", on: "1", off: "0", env)
        }
        Row(title: "Show frame rate", detail: dxvk ? "An FPS counter in DirectX 10 and 11 games" : "Needs DirectX set to DXVK", busy: busy("DXVK_HUD")) {
            toggle("DXVK_HUD", on: "fps", off: "", env).disabled(!dxvk)
        }
        Row(title: "Use ⌘ as Ctrl", detail: "So ⌘C and ⌘V copy and paste in Windows apps", busy: busy("VINO_CMDCTRL")) {
            toggle("VINO_CMDCTRL", on: "1", off: "0", env)
        }
        Row(title: "AVX support", detail: "Lets games that need AVX start. Needs macOS 15 or later.", busy: busy("ROSETTA_ADVERTISE_AVX")) {
            toggle("ROSETTA_ADVERTISE_AVX", on: "1", off: "", env)
        }
    }
    }

    private var windowsCard: some View {
    Card(title: "Windows") {
        Row(title: "Windows version", busy: busy("VINO_WINVER")) {
            Picker("Windows version", selection: Binding(get: { env["VINO_WINVER"] ?? "win10" }, set: { model.set(name, "VINO_WINVER", $0) })) {
                ForEach(Self.windows, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden().fixedSize()
        }
        Row(title: "Wine", busy: busy("VINO_WINE")) {
            Picker("Wine", selection: Binding(get: { env["VINO_WINE"] ?? "" }, set: { model.set(name, "VINO_WINE", $0) })) {
                Text("Automatic").tag("")
                ForEach(model.wines, id: \.path) { Text($0.name).tag($0.path) }
            }
            .labelsHidden().fixedSize()
        }
        windowRow
        Row(title: "C: drive", detail: model.bottle(name)?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), mono: true) {
            Button { model.showFiles(name) } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(PillButton())
        }
    }
    }

    private var toolsCard: some View {
    Card(title: "Tools") {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 0) {
            ToolButton(title: "Windows Components", icon: "shippingbox") { panel = .components }
            ToolButton(title: "Controllers", icon: "gamecontroller") { panel = .controllers }
            ToolButton(title: "Task Manager", icon: "chart.bar.xaxis") { panel = .tasks }
            tool("Command Prompt", "terminal", ["start", "cmd"])
            ToolButton(title: "Install into Bottle", icon: "square.and.arrow.down") { model.chooseInstaller(into: name) }
            tool("Simulate Reboot", "arrow.clockwise", ["wineboot", "-r"])
            tool("Wine Settings", "gearshape", ["winecfg"], advanced: true)
            tool("Registry Editor", "cylinder.split.1x2", ["regedit"], advanced: true)
        }
        .padding(4)
    }
    .sheet(item: $panel) { p in
        switch p {
        case .controllers: ControllersPanel(bottle: name)
        case .tasks: TaskManagerPanel(bottle: name)
        case .components: ComponentsPanel(bottle: name)
        }
    }
    }

    private var installedCard: some View {
    Card(title: "Installed in This Bottle") {
        if programs.isEmpty {
            Row(title: "Nothing listed yet") { EmptyView() }
        }
        ForEach(programs, id: \.self) { p in
            Row(title: p.name) {
                Text(p.version).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
    .task(id: "\(name)|\(count)") { programs = await model.installed(name) }
    }

    private var bottleCard: some View {
    Card(title: "Bottle") {
        Row(title: "Quit all apps", detail: "Closes everything running in \(title), like shutting down Windows") {
            Button("Quit All") { model.quitAll(name) }.buttonStyle(PillButton())
        }
        Row(title: "Delete bottle", detail: "Moves \(title) and everything installed in it to the Trash") {
            Button("Delete…") { confirmDelete = true }.buttonStyle(PillButton(kind: .danger))
        }
        if confirmDelete {
            VStack(alignment: .leading, spacing: 10) {
                Text("Move **\(title)** and everything in it to the Trash? It stays there until you empty the Trash.")
                    .font(.system(size: 12.5))
                HStack {
                    Spacer()
                    Button("Cancel") { confirmDelete = false }.buttonStyle(PillButton())
                    Button("Move to Trash") { confirmDelete = false; model.delete(name); onDelete() }.buttonStyle(PillButton(kind: .solidDanger))
                }
            }
            .padding(14)
            .background(Theme.bad.opacity(0.06))
        }
    }
    }

    private var developerCard: some View {
        Card(title: "Developer", note: "Every run is logged in the bottle's logs folder and in the Console app (search for app.vino).") {
            Row(title: "Metal performance HUD", detail: "Frame rate, GPU time and memory over games that draw with Metal, like DXVK games",
                busy: busy("MTL_HUD_ENABLED")) {
                toggle("MTL_HUD_ENABLED", on: "1", off: "", env)
            }
            Row(title: "Allow GPU captures", detail: "Lets Xcode capture a frame: Debug ▸ Attach to Process, then Capture GPU Workload",
                busy: busy("MTL_CAPTURE_ENABLED")) {
                toggle("MTL_CAPTURE_ENABLED", on: "1", off: "", env)
            }
            Row(title: "Logs", detail: "One file per app, plus the run before it") {
                Button {
                    if let path = model.bottle(name)?.path { NSWorkspace.shared.open(URL(fileURLWithPath: path).appendingPathComponent("logs")) }
                } label: { Label("Open Logs", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(PillButton())
            }
        }
    }

    private var windowRow: some View {
        Row(title: "Run in a window",
            detail: env["VINO_DESKTOP"] == nil ? "Apps use the whole screen when they ask for it"
                : "Windows' desktop appears in one Mac window, so full-screen games can't take over",
            busy: busy("VINO_DESKTOP")) {
            HStack(spacing: 10) {
                if let size = env["VINO_DESKTOP"] {
                    Picker("Window size", selection: Binding(get: { size }, set: { model.set(name, "VINO_DESKTOP", $0) })) {
                        ForEach(Self.sizes(including: size), id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Toggle("Run in a window", isOn: Binding(get: { env["VINO_DESKTOP"] != nil },
                                                        set: { model.set(name, "VINO_DESKTOP", $0 ? "1280x800" : "") }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    /// The usual window sizes, plus the bottle's own if it's something else, smallest first.
    static func sizes(including size: String) -> [String] {
        let width = { (s: String) in Int(s.split(separator: "x").first ?? "") ?? 0 }
        return Array(Set(windowSizes + [size])).sorted { width($0) < width($1) }
    }

    private func busy(_ key: String) -> Bool { model.busy.contains(name + "|" + key) }

    private func toggle(_ key: String, on: String, off: String, _ env: [String: String]) -> some View {
        Toggle(key, isOn: Binding(get: { env[key] == on }, set: { model.set(name, key, $0 ? on : off) }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private func tool(_ title: String, _ icon: String, _ args: [String], advanced: Bool = false) -> some View {
        ToolButton(title: title, icon: icon, note: advanced ? "Wine's window" : nil) { model.tool(name, title, args) }
    }
}

struct ToolButton: View {
    let title: String
    let icon: String
    var note: String? = nil  // marks Wine's own windows, which look like Windows, not Vino
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Theme.accent).frame(height: 22)
                Text(title).font(.system(size: 11.5, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(hover ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct NewBottleSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    let created: (String) -> Void
    @State private var name = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Bottle").font(.headline)
            Text("A bottle is a separate Windows setup. Use one to keep an app's settings away from everything else.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name, like Games", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                if working { ProgressView().controlSize(.small); Text("Setting up Windows…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PillButton()).disabled(working)
                Button("Create") {
                    working = true
                    Task {
                        let n = name.trimmed
                        if await model.newBottle(n) { created(n) }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButton(kind: .primary))
                .disabled(name.trimmed.isEmpty || name.contains("/") || name.hasPrefix(".") || name.hasPrefix("-") || working)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

// MARK: - Setup, failure, pill

struct SetupView: View {
    @EnvironmentObject var model: Model
    let fixes: [Fix]
    @State private var working: UUID?

    /// Rosetta and Wine are handled by one Set Up button; anything else gets its own row.
    private var oneClick: Bool { fixes.contains { $0.command == CLI.setupCommand || $0.command.contains("--install-rosetta") } }
    private var others: [Fix] { fixes.filter { $0.command != CLI.setupCommand && !$0.command.contains("--install-rosetta") } }

    var body: some View {
        VStack(spacing: 22) {
            if oneClick {
                welcome
            } else {
                VStack(spacing: 6) {
                    Text("Almost ready").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("vino needs a little setup before it can run Windows apps.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 10) {
                ForEach(others) { fix in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fix.problem).font(.system(size: 13, weight: .medium))
                            Text(fix.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(fix.canRun ? 2 : 8)
                        }
                        Spacer(minLength: 8)
                        if !fix.canRun {
                            EmptyView()
                        } else if working == fix.id {
                            ProgressView().controlSize(.small).frame(width: 52)
                        } else {
                            Button("Fix") {
                                working = fix.id
                                Task { await model.apply(fix); working = nil }
                            }
                            .buttonStyle(PillButton(kind: .primary))
                            .disabled(working != nil)
                        }
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                }
            }
            .frame(maxWidth: 480)
            if model.setupStatus == nil {
                Button("Check Again") { Task { await model.refresh() } }.buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(hue: 0.74, saturation: 0.5, brightness: 0.98), Color(hue: 0.71, saturation: 0.75, brightness: 0.82)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: "wineglass").font(.system(size: 40, weight: .medium)).foregroundStyle(.white))
                .frame(width: 88, height: 88)
                .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
            VStack(spacing: 6) {
                Text("Welcome to Vino").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Vino runs Windows apps with Wine. It downloads Wine (about 185 MB) and turns on Apple's Rosetta for you.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if let status = model.setupStatus {
                VStack(spacing: 8) {
                    if let p = model.setupProgress { ProgressView(value: p).frame(width: 300) } else { ProgressView().controlSize(.small) }
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(height: 44)
            } else {
                Button { Task { await model.setUp() } } label: { Text("Set Up").frame(minWidth: 110) }
                    .buttonStyle(PillButton(kind: .primary, large: true))
                    .keyboardShortcut(.defaultAction)
                    .frame(height: 44)
            }
        }
    }
}

struct FailureView: View {
    let failure: Failure
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(failure.title).font(.system(size: 15, weight: .semibold))
            ScrollView {
                Text(failure.text.isEmpty ? "No details were reported." : failure.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                if let range = failure.text.range(of: "Full log: ") {
                    let log = String(failure.text[range.upperBound...]).trimmed
                    Button("Open Full Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }.buttonStyle(PillButton())
                }
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PillButton(kind: .primary))
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

struct Pill: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Group {
            if let text = model.activity ?? model.toast {
                HStack(spacing: 8) {
                    if model.activity != nil { ProgressView().controlSize(.small) }
                    Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: model.activity ?? model.toast)
    }
}

/// The frosted window: the desktop blurs through it, like the mockup's glass.
struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
