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
