// Creating a virtual display needs BetterDisplay - macOS has no public API for it.
// We drive it through its URL scheme so the user never has to touch a command line.

import AppKit
import CoreGraphics
import Foundation

enum VirtualDisplay {

    static var betterDisplayInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "pro.betterdisplay.BetterDisplay") != nil
            || FileManager.default.fileExists(atPath: "/Applications/BetterDisplay.app")
    }

    static var betterDisplayRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "pro.betterdisplay.BetterDisplay").isEmpty
    }

    static func launchBetterDisplay() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "pro.betterdisplay.BetterDisplay")
            ?? URL(string: "file:///Applications/BetterDisplay.app") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Displays macOS currently knows about, newest last.
    static func allDisplays() -> [(id: CGDirectDisplayID, name: String, width: Int, height: Int)] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let w = mode.map { $0.pixelWidth } ?? Int(CGDisplayPixelsWide(id))
            let h = mode.map { $0.pixelHeight } ?? Int(CGDisplayPixelsHigh(id))
            let builtin = CGDisplayIsBuiltin(id) != 0
            return (id, builtin ? L.builtIn : "\(L.display) \(id)", w, h)
        }
    }

    /// Ask BetterDisplay which display is the virtual one. Guessing "the last
    /// non-builtin screen" picks the wrong one as soon as a real monitor is plugged in.
    static func likelyVirtual() -> CGDirectDisplayID? {
        let raw = run(["get", "-identifiers"], timeout: 4)
        if let data = ("[" + raw + "]").data(using: .utf8),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in items where (item["deviceType"] as? String) == "VirtualScreen" {
                let id: Int?
                if let n = item["displayID"] as? Int { id = n }
                else if let str = item["displayID"] as? String { id = Int(str) }
                else { id = nil }
                if let id, id > 0 { return CGDirectDisplayID(id) }   // 0 means "not connected"
            }
        }
        let all = allDisplays()
        return all.last(where: { CGDisplayIsBuiltin($0.id) == 0 })?.id ?? all.last?.id
    }

    /// Marks the virtual screen in the picker so the user isn't guessing either.
    static func virtualID() -> CGDirectDisplayID? { likelyVirtual() }

    private static let binary = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    /// Run BetterDisplay's own command line. Its URL scheme can be switched off in its
    /// settings, the binary always answers.
    @discardableResult
    private static func run(_ args: [String], timeout: TimeInterval = 6) -> String {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return "" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }

        // Some calls never return on their own - give them a deadline.
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        while task.isRunning && Date() < deadline {
            output.append(pipe.fileHandleForReading.availableData)
            usleep(100_000)
        }
        if task.isRunning { task.terminate() }
        output.append(pipe.fileHandleForReading.availableData)
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// tagIDs of every virtual screen BetterDisplay currently knows about.
    private static func virtualTags() -> [Int] {
        let raw = run(["get", "-identifiers"])
        guard let data = ("[" + raw + "]").data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard (item["deviceType"] as? String) == "VirtualScreen" else { return nil }
            if let tag = item["tagID"] as? Int { return tag }
            if let tag = item["tagID"] as? String { return Int(tag) }
            return nil
        }
    }

    /// Make a virtual screen and switch it on. Runs off the main thread - some of these
    /// calls take seconds.
    static func create(width: Int, height: Int, completion: @escaping (String?) -> Void) {
        guard betterDisplayInstalled else {
            completion(L.noBetterDisplay)
            return
        }
        if !betterDisplayRunning {
            launchBetterDisplay()
        }
        DispatchQueue.global().async {
            // wait for BetterDisplay to answer at all
            var ready = false
            for _ in 0..<20 where !ready {
                ready = !run(["get", "-identifiers"], timeout: 3).isEmpty
                if !ready { Thread.sleep(forTimeInterval: 0.5) }
            }
            guard ready else {
                DispatchQueue.main.async { completion(L.betterDisplaySilent) }
                return
            }

            let before = Set(virtualTags())
            run(["create", "-type=VirtualScreen"], timeout: 8)
            Thread.sleep(forTimeInterval: 1.0)

            guard let tag = virtualTags().first(where: { !before.contains($0) }) ?? virtualTags().last else {
                DispatchQueue.main.async { completion(L.notCreated) }
                return
            }

            let list = "\(width)x\(height)"
            run(["set", "-tagID=\(tag)", "-virtualScreenHiDPI=off"])
            // resolution is ignored unless the custom list is switched on first
            run(["set", "-tagID=\(tag)", "-useResolutionList=on", "-resolutionList=\(list)"])
            run(["set", "-tagID=\(tag)", "-connected=on"])
            Thread.sleep(forTimeInterval: 1.5)
            run(["set", "-tagID=\(tag)", "-resolution=\(list)"])
            Thread.sleep(forTimeInterval: 1.0)

            let connected = allDisplays().contains { CGDisplayIsBuiltin($0.id) == 0 && $0.width == width }
            DispatchQueue.main.async {
                completion(connected ? nil : L.notConnected)
            }
        }
    }

    /// Every IPv4 address this Mac has, so we can show the user where to point the tablet.
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        var ptr = first
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr
            if (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
               addr?.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr!.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254") { out.append(ip) }
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        freeifaddrs(ifaddr)
        return out
    }
}
