// The window the user actually sees: one button, a status line, and the address
// the tablet should connect to.

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct TabScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("TabScreen") {
            ContentView(model: delegate.model)
                .frame(width: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the window on the Mac's own screen - it has a habit of opening on the
        // virtual one, where only the tablet can see it.
        if let window = NSApplication.shared.windows.first,
           let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: main.frame.midX - frame.width / 2,
                y: main.frame.midY - frame.height / 2))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--create-screen") {
            model.createVirtualScreen()
        }
        if CommandLine.arguments.contains("--start")
            || UserDefaults.standard.bool(forKey: "autostart") {
            model.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

@MainActor
final class Model: ObservableObject {
    @Published var running = false
    @Published var status = L.appReady
    @Published var problem: String?
    @Published var clients = 0
    @Published var latency = 0
    @Published var fps = 0
    @Published var addresses: [String] = []
    @Published var displays: [(id: CGDirectDisplayID, name: String, width: Int, height: Int)] = []
    @Published var chosenDisplay: CGDirectDisplayID = 0
    @Published var virtualID: CGDirectDisplayID = 0
    @Published var creatingScreen = false
    @Published var autostart = UserDefaults.standard.bool(forKey: "autostart") {
        didSet { UserDefaults.standard.set(autostart, forKey: "autostart") }
    }

    private let capture = Capture()
    private let server = Server()

    init() {
        refresh()
    }

    func refresh() {
        displays = VirtualDisplay.allDisplays()
        addresses = VirtualDisplay.localAddresses()
        let virtual = VirtualDisplay.likelyVirtual()
        virtualID = virtual ?? 0
        if chosenDisplay == 0 || !displays.contains(where: { $0.id == chosenDisplay }) {
            chosenDisplay = virtual ?? displays.first?.id ?? 0
        }
    }

    func createVirtualScreen() {
        guard VirtualDisplay.betterDisplayInstalled else {
            problem = L.noBetterDisplay
            return
        }
        creatingScreen = true
        status = L.creating
        VirtualDisplay.create(width: 1280, height: 800) { [weak self] error in
            guard let self else { return }
            self.creatingScreen = false
            self.problem = error
            self.status = error == nil ? L.created : L.appReady
            self.refresh()
        }
    }

    func start() {
        guard let display = displays.first(where: { $0.id == chosenDisplay }) else {
            problem = L.noScreenChosen
            return
        }
        problem = nil
        status = L.starting

        server.onStats = { [weak self] stats in
            Task { @MainActor in
                self?.clients = stats.clients
                self?.latency = stats.latencyMs
                self?.fps = stats.fps
            }
        }
        capture.onNAL = { [weak self] nal, isKey in
            self?.server.publish(nal, isKeyframe: isKey)
        }
        capture.onError = { [weak self] message in
            Task { @MainActor in
                self?.problem = message
                self?.stop()
            }
        }

        do {
            try server.start()
            print("сервер слушает 8090")
        } catch {
            problem = "\(L.portBusy): \(error.localizedDescription)"
            print("сервер не поднялся: \(error)")
            status = L.appReady
            return
        }

        capture.start(displayID: display.id, width: display.width, height: display.height,
                      fps: 60, bitrate: 5_000_000) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.problem = error
                    print("захват не пошёл: \(error)")
                    self.server.stop()
                    self.status = L.appReady
                } else {
                    self.running = true
                    self.status = L.appRunning
                }
            }
        }
    }

    func stop() {
        capture.stop()
        server.stop()
        running = false
        status = L.appReady
        clients = 0
        latency = 0
        fps = 0
    }
}

struct ContentView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: model.running ? "display.2" : "display")
                    .font(.system(size: 26))
                    .foregroundStyle(model.running ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text("TabScreen").font(.headline)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.running ? L.turnOff : L.turnOn) {
                    model.running ? model.stop() : model.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.creatingScreen)
            }

            if let problem = model.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Text(L.screen).frame(width: 70, alignment: .leading)
                Picker("", selection: $model.chosenDisplay) {
                    ForEach(model.displays, id: \.id) { d in
                        Text(d.id == model.virtualID
                             ? "\(L.virtual) · \(d.width)×\(d.height)"
                             : "\(d.name) · \(d.width)×\(d.height)").tag(d.id)
                    }
                }
                .labelsHidden()
                .disabled(model.running)
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L.refresh)
            }

            if !model.running {
                Button {
                    model.createVirtualScreen()
                } label: {
                    Label(L.createScreen, systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(model.creatingScreen)
                .help(L.createScreenHelp)

                Toggle(L.startOnLaunch, isOn: $model.autostart)
                    .font(.callout)
            }

            if model.running {
                Divider()
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.connectFrom).font(.callout)
                        ForEach(model.addresses, id: \.self) { ip in
                            Text(ip).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                        Text(L.orFind)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let ip = model.addresses.first, let qr = qrCode(for: ip) {
                        Image(nsImage: qr).interpolation(.none).frame(width: 92, height: 92)
                    }
                }

                Divider()
                HStack(spacing: 18) {
                    stat(L.tablets, "\(model.clients)")
                    stat(L.latency, model.latency > 0 ? "\(model.latency) \(L.ms)" : "—")
                    stat(L.fps, model.fps > 0 ? "\(model.fps)" : "—")
                }
            }
        }
        .padding(18)
        .onAppear { model.refresh() }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    private func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 92, height: 92))
    }
}
