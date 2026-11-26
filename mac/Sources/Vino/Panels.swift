import GameController
import SwiftUI

// Vino's own versions of Wine's tool windows. Wine's originals stay one click away under "Advanced…".

/// The frame every panel shares: an icon and title, the content, then Advanced… and Done.
struct PanelFrame<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var advanced: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            content()
            HStack {
                if let advanced {
                    Button("Advanced…") { advanced(); dismiss() }.buttonStyle(.link).font(.system(size: 12))
                        .help("Open Wine's own window")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PillButton(kind: .primary))
            }
        }
        .padding(22)
        .frame(width: 520)
        .tint(Theme.accent)
    }
}

// MARK: - Controllers

struct ControllersPanel: View {
    @EnvironmentObject var model: Model
    let bottle: String
    @State private var pads: [GCController] = GCController.controllers()

    var body: some View {
        let env = model.bottle(bottle)?.env ?? [:]
        let off = Set((env["VINO_PADS_OFF"] ?? "").split(separator: "|").map(String.init))
        PanelFrame(icon: "gamecontroller", title: "Controllers", subtitle: "Game controllers Windows apps in this bottle can use",
                   advanced: { model.tool(bottle, "Game Controllers", ["control", "joy.cpl"]) }) {
            Card(title: "Connected") {
                if pads.isEmpty {
                    Row(title: "No controllers connected", detail: "Connect one over Bluetooth or USB and it shows up here.") { EmptyView() }
                }
                ForEach(pads, id: \.self) { pad in
                    // shortcut: assumes Windows sees the same name macOS reports (true for Xbox, PlayStation and Switch pads)
                    let name = pad.vendorName ?? "Controller"
                    Row(title: name, detail: pad.productCategory, busy: model.busy.contains(bottle + "|VINO_PADS_OFF")) {
                        Toggle(name, isOn: Binding(get: { !off.contains(name) }, set: { use in
                            var next = off
                            if use { next.remove(name) } else { next.insert(name) }
                            model.set(bottle, "VINO_PADS_OFF", next.sorted().joined(separator: "|"))
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            Card(title: "Options", note: "Changes apply the next time you open an app.") {
                Row(title: "Use SDL", detail: "How Wine talks to most controllers. Turn off only if a controller acts strangely.",
                    busy: model.busy.contains(bottle + "|VINO_SDL")) {
                    Toggle("Use SDL", isOn: Binding(get: { env["VINO_SDL"] != "0" }, set: { model.set(bottle, "VINO_SDL", $0 ? "1" : "0") }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in pads = GCController.controllers() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in pads = GCController.controllers() }
    }
}

// MARK: - Task Manager

struct TaskManagerPanel: View {
    @EnvironmentObject var model: Model
    let bottle: String
    @State private var procs: [Proc]? = nil
    @State private var ending: Set<Int> = []

    var body: some View {
        let title = model.bottle(bottle)?.title ?? bottle
        PanelFrame(icon: "chart.bar.xaxis", title: "Task Manager", subtitle: "Windows programs running in \(title)",
                   advanced: { model.tool(bottle, "Task Manager", ["taskmgr"]) }) {
            Card(title: "Running", note: "End asks a program to close, like clicking its close button. Force Quit stops it at once.") {
                if procs == nil {
                    Row(title: "Checking…") { ProgressView().controlSize(.small) }
                } else if procs!.isEmpty {
                    Row(title: "Nothing is running", detail: "Programs you open in \(title) show up here.") { EmptyView() }
                }
                ForEach(procs ?? []) { p in
                    Row(title: p.name, detail: "Program number \(p.pid)") {
                        HStack(spacing: 6) {
                            if ending.contains(p.pid) {
                                Button("Force Quit") { Task { await model.end(bottle, p, force: true) } }.buttonStyle(PillButton(kind: .danger))
                            } else {
                                Button("End") {
                                    ending.insert(p.pid)
                                    Task { await model.end(bottle, p, force: false) }
                                }
                                .buttonStyle(PillButton())
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            if procs?.isEmpty == false {
                Button("Quit Everything in \(title)") { model.quitAll(bottle) }.buttonStyle(PillButton(kind: .danger))
            }
        }
        .task {
            while !Task.isCancelled {  // refresh while the panel is open
                procs = await model.processes(bottle)
                ending = ending.filter { pid in procs?.contains { $0.pid == pid } == true }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

// MARK: - This app's own settings

struct AppSettingsCard: View {
    @EnvironmentObject var model: Model
    let app: WinApp
    @State private var args = ""
    @State private var env = ""

    static let languages = [("Automatic", ""), ("English", "en_US.UTF-8"), ("Japanese", "ja_JP.UTF-8"), ("Chinese (Simplified)", "zh_CN.UTF-8"),
                            ("Chinese (Traditional)", "zh_TW.UTF-8"), ("Korean", "ko_KR.UTF-8"), ("Russian", "ru_RU.UTF-8"), ("German", "de_DE.UTF-8"),
                            ("French", "fr_FR.UTF-8"), ("Spanish", "es_ES.UTF-8"), ("Italian", "it_IT.UTF-8"), ("Portuguese (Brazil)", "pt_BR.UTF-8"),
                            ("Polish", "pl_PL.UTF-8"), ("Ukrainian", "uk_UA.UTF-8"), ("Thai", "th_TH.UTF-8")]

    private var saved: [String: String] { app.settings ?? [:] }
    private var extraEnv: [String: String] { saved.filter { $0.key != "VINO_ARGS" && $0.key != "LC_ALL" } }

    var body: some View {
        Card(title: "This App", note: "Used every time \(app.name) opens. Press Return to save a text field.") {
            Row(title: "Launch arguments", detail: "Added to how it starts, like -windowed or -nosplash") {
                TextField("None", text: $args).textFieldStyle(.roundedBorder).frame(width: 230)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.configure(app, "VINO_ARGS", args.trimmed) }
            }
            Row(title: "Language", detail: "Some games only start, or only show text, in their own language") {
                Picker("Language", selection: Binding(get: { saved["LC_ALL"] ?? "" }, set: { model.configure(app, "LC_ALL", $0) })) {
                    ForEach(Self.languages, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().fixedSize()
            }
            Row(title: "Environment", detail: "Extra settings for Wine, like DXVK_HUD=full") {
                TextField("NAME=value NAME=value", text: $env).textFieldStyle(.roundedBorder).frame(width: 230)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(saveEnv)
            }
            Row(title: "Mac shortcut", detail: "Open it from the Dock, Launchpad or Spotlight like a Mac app") {
                Button { model.makeShortcut(app) } label: { Label("Make Shortcut", systemImage: "plus.app") }.buttonStyle(PillButton())
            }
        }
        .onAppear {
            args = saved["VINO_ARGS"] ?? ""
            env = extraEnv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
    }

    private func saveEnv() {
        // shortcut: values can't contain spaces here; use `vino configure` for those
        var new: [String: String] = [:]
        for pair in env.split(whereSeparator: \.isWhitespace) {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, !kv[0].isEmpty, kv[0] != "VINO_ARGS", kv[0] != "LC_ALL" { new[kv[0]] = kv[1] }
        }
        for key in extraEnv.keys where new[key] == nil { model.configure(app, key, "") }
        for (k, v) in new where extraEnv[k] != v { model.configure(app, k, v) }
    }
}

// MARK: - Windows components

struct ComponentsPanel: View {
    @EnvironmentObject var model: Model
    let bottle: String
    @State private var items: [ComponentItem]?
    @State private var busy: String?
    @State private var other = ""

    var body: some View {
        PanelFrame(icon: "shippingbox", title: "Windows Components",
                   subtitle: "Parts many Windows apps need. Each comes from its publisher and is checked before installing.") {
            ScrollView {
                Card(title: "Common") {
                    if items == nil { Row(title: "Checking…") { ProgressView().controlSize(.small) } }
                    ForEach(items ?? []) { c in
                        Row(title: c.title, detail: c.detail) {
                            if c.installed {
                                Text("Installed").chip(Theme.ok)
                            } else if busy == c.verb {
                                ProgressView().controlSize(.small).frame(width: 60)
                            } else {
                                Button("Install") { install(c.verb, c.title) }.buttonStyle(PillButton()).disabled(busy != nil)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 390)
            HStack(spacing: 8) {
                TextField("Any other Winetricks name, like vcrun2019", text: $other)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .onSubmit { if !other.trimmed.isEmpty { install(other.trimmed, other.trimmed) } }
                Button("Install") { install(other.trimmed, other.trimmed) }
                    .buttonStyle(PillButton()).disabled(other.trimmed.isEmpty || busy != nil)
            }
            Link("Everything Winetricks can install", destination: URL(string: "https://github.com/Winetricks/winetricks/blob/master/files/verbs/all.txt")!)
                .font(.system(size: 12))
        }
        .task { items = await model.components(bottle) }
    }

    private func install(_ verb: String, _ title: String) {
        busy = verb
        Task {
            await model.installComponent(bottle, verb, title)
            items = await model.components(bottle)
            busy = nil
        }
    }
}

// MARK: - A file opened from Finder

struct OpenFileSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var bottle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIcon(name: url.deletingPathExtension().lastPathComponent, size: 44, icon: nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open \(url.lastPathComponent)").font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("Installers add their app to the bottle you pick.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Picker("Bottle", selection: $bottle) {
                ForEach(model.bottles) { Text($0.title).tag($0.name) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PillButton())
                Button("Open") { model.install(url, into: bottle); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(PillButton(kind: .primary)).disabled(bottle.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .tint(Theme.accent)
        .onAppear { bottle = model.defaultBottle }
    }
}
