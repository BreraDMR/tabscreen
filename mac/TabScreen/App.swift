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
    private var wasRunningBeforeSleep = false

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
        watchForSleep()

        if CommandLine.arguments.contains("--create-screen") {
            model.createVirtualScreen()
        }
        if CommandLine.arguments.contains("--start")
            || UserDefaults.standard.bool(forKey: "autostart") {
            model.start()
        }
    }

    /// Stop cleanly when the Mac sleeps: the tablet then knows the link is gone and can
    /// let its own screen go dark, instead of sitting awake all night retrying.
    private func watchForSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self, self.model.running else { return }
            self.wasRunningBeforeSleep = true
            self.model.stop()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self, self.wasRunningBeforeSleep else { return }
            self.wasRunningBeforeSleep = false
            // displays take a moment to come back after waking
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.model.refresh()
                self.model.start()
            }
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
    /// 0, 90, 180 or 270 - how the tablet should turn the picture. Turning it there
    /// costs nothing: the tablet's compositor does it while drawing.
    @Published var rotation = UserDefaults.standard.integer(forKey: "rotation") {
        didSet {
            UserDefaults.standard.set(rotation, forKey: "rotation")
            // The picture is turned before it is encoded, so the capture has to be
            // rebuilt at the new size. The server and the tablet don't notice.
            guard running, rotation != oldValue else { return }
            capture.stop()
            startCapture()
        }
    }

    private let capture = Capture()
    private let server = Server()

    /// What the user asked for, as opposed to what is happening right now: the stream
    /// can drop on its own and we want to bring it back without them clicking anything.
    private var wantsRunning = false
    private var retryDelay = 2.0
    /// Set only when we switched the virtual screen on ourselves - then it's ours to
    /// switch off again. A screen the user had up already stays up.
    private var ourScreenTag: Int?

    init() {
        refresh()
    }

    func refresh() {
        displays = VirtualDisplay.allDisplays()
        addresses = VirtualDisplay.localAddresses()
        let virtual = VirtualDisplay.likelyVirtual()
        virtualID = virtual ?? 0
        if chosenDisplay == 0 || !displays.contains(where: { $0.id == chosenDisplay }) {
            // Leave it at 0 rather than falling back to some other screen: sending the
            // wrong picture is worse than sending none, and the user can pick by hand.
            chosenDisplay = virtual ?? 0
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
            // No screen to capture. BetterDisplay usually still has the virtual one,
            // just switched off - turn it on rather than making the user do it.
            wantsRunning = true
            problem = nil
            status = L.wakingScreen
            DispatchQueue.global().async { [weak self] in
                let tag = VirtualDisplay.disconnectedVirtualTag()
                if let tag { VirtualDisplay.setConnected(tag: tag, on: true) }
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if let tag { self.ourScreenTag = tag }
                    self.refresh()
                    if self.displays.contains(where: { $0.id == self.chosenDisplay }) {
                        self.start()
                    } else {
                        self.problem = L.screenGone
                        self.status = L.reconnecting
                        self.scheduleRecovery()
                    }
                }
            }
            return
        }
        problem = nil
        status = L.starting
        wantsRunning = true

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
                self?.captureLost(message)
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

        startCapture()
    }

    private func startCapture() {
        guard let display = displays.first(where: { $0.id == chosenDisplay }) else { return }
        capture.start(displayID: display.id, width: display.width, height: display.height,
                      fps: 60, bitrate: 5_000_000, rotation: rotation) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    print("захват не пошёл: \(error)")
                    // Same treatment as a stream that dies later: the screen may just not
                    // be there yet (BetterDisplay still starting up), so keep trying.
                    self.captureLost(error)
                } else {
                    self.running = true
                    self.retryDelay = 2
                    self.status = L.appRunning
                }
            }
        }
    }

    /// The virtual screen can disappear under us - BetterDisplay hands out a fresh
    /// displayID every time it recreates one, and the old stream just dies. Don't make
    /// the user notice and click things: find the screen again and pick up where we left.
    private func captureLost(_ message: String) {
        capture.stop()
        running = false
        clients = 0
        latency = 0
        fps = 0
        guard wantsRunning else {
            problem = message
            status = L.appReady
            return
        }
        status = L.reconnecting
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsRunning else { return }
            // refresh() re-points chosenDisplay at the virtual screen when the old id is gone
            self.refresh()
            guard self.displays.contains(where: { $0.id == self.chosenDisplay }) else {
                self.problem = L.screenGone
                self.scheduleRecovery()
                return
            }
            self.problem = nil
            self.start()
        }
    }

    func stop() {
        wantsRunning = false
        capture.stop()
        server.stop()
        running = false
        status = L.appReady
        clients = 0
        latency = 0
        fps = 0
        // Put the screen back the way we found it: nobody needs a virtual display
        // hanging around collecting windows once the tablet is done.
        if let tag = ourScreenTag {
            ourScreenTag = nil
            DispatchQueue.global().async { VirtualDisplay.setConnected(tag: tag, on: false) }
        }
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

            HStack {
                Text(L.rotation).frame(width: 70, alignment: .leading)
                Picker("", selection: $model.rotation) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
