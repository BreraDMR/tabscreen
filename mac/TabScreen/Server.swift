// Serves the encoded screen to tablets, and announces itself on the network so a
// client can find the Mac without anyone typing an IP address.

import Foundation
import Network

final class Server: @unchecked Sendable {

    struct Stats {
        var clients = 0
        var latencyMs = 0
        var fps = 0
    }

    var onStats: ((Stats) -> Void)?
    private(set) var stats = Stats() { didSet { onStats?(stats) } }

    /// A connected tablet. Keeps a short queue: a long one is just hidden latency.
    private final class Client {
        let connection: NWConnection
        var queue: [Data] = []
        var waitingForKeyframe = false
        var sending = false
        let lock = NSLock()

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var announcing = false
    private var clients: [ObjectIdentifier: Client] = [:]
    private let lock = NSLock()
    private var seq: UInt32 = 0
    private var sentAt: [UInt32: CFAbsoluteTime] = [:]
    private var header = Data()          // latest SPS + PPS, framed and ready
    private var sps: Data?
    private var pps: Data?
    private var framesThisSecond = 0
    private var lastTick = CFAbsoluteTimeGetCurrent()

    var hasClients: Bool {
        lock.lock(); defer { lock.unlock() }
        return !clients.isEmpty
    }

    init(port: UInt16 = 8090) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true                     // Nagle would sit on our small writes
            tcp.connectionTimeout = 5
        }
        // Listen on IPv4: by default this ends up IPv6-only and the tablet gets
        // "connection refused" while the port looks open in lsof.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            print("listener: \(state)")
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        startAnnouncing()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        announcing = false
        lock.lock()
        clients.values.forEach { $0.connection.cancel() }
        clients.removeAll()
        lock.unlock()
        stats.clients = 0
    }

    // MARK: - clients

    private func accept(_ conn: NWConnection) {
        let client = Client(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.clients[ObjectIdentifier(client)] = client
                let count = self.clients.count
                self.lock.unlock()
                self.stats.clients = count
                if !self.header.isEmpty { self.send(self.header, to: client) }
            case .failed, .cancelled:
                self.drop(client)
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        readRequest(client)
    }

    /// The client speaks a tiny protocol: "GET /h264" to receive, "ACK <n>" to report
    /// that frame n reached the screen - that's how latency is measured on our clock.
    private func readRequest(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, done, _ in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                    if parts.count == 2, parts[0] == "ACK", let n = UInt32(parts[1]) {
                        self.noteAck(n)
                    }
                }
            }
            if done { self.drop(client) } else { self.readRequest(client) }
        }
    }

    private func drop(_ client: Client) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(client))
        let count = clients.count
        lock.unlock()
        client.connection.cancel()
        stats.clients = count
    }

    private func noteAck(_ n: UInt32) {
        lock.lock()
        let sent = sentAt.removeValue(forKey: n)
        lock.unlock()
        if let sent {
            stats.latencyMs = Int((CFAbsoluteTimeGetCurrent() - sent) * 1000)
        }
    }

    // MARK: - sending

    /// Frames go out as [4-byte length][4-byte sequence][NAL]. Doing the framing here
    /// means the tablet never has to scan the byte stream for start codes.
    func publish(_ nal: Data, isKeyframe: Bool) {
        let type = nal[nal.startIndex] & 0x1f
        if type == 7 { sps = nal }
        if type == 8 { pps = nal }
        if let sps, let pps, type == 7 || type == 8 {
            header = frame(sps, seq: 0) + frame(pps, seq: 0)
        }

        seq &+= 1
        if seq % 30 == 0 {
            lock.lock()
            sentAt[seq] = CFAbsoluteTimeGetCurrent()
            if sentAt.count > 200 { sentAt.removeValue(forKey: sentAt.keys.first!) }
            lock.unlock()
        }

        framesThisSecond += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTick >= 1 {
            stats.fps = framesThisSecond
            framesThisSecond = 0
            lastTick = now
        }

        let packet = frame(nal, seq: seq)
        lock.lock()
        let all = Array(clients.values)
        lock.unlock()
        for client in all { send(packet, to: client, isKeyframe: isKeyframe) }
    }

    private func frame(_ nal: Data, seq: UInt32) -> Data {
        var out = Data(capacity: nal.count + 8)
        var len = UInt32(nal.count).bigEndian
        var s = seq.bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &s) { out.append(contentsOf: $0) }
        out.append(nal)
        return out
    }

    private func send(_ data: Data, to client: Client, isKeyframe: Bool = false) {
        client.lock.lock()
        if client.waitingForKeyframe {
            if !isKeyframe {
                client.lock.unlock()
                return
            }
            client.waitingForKeyframe = false
            client.queue.removeAll()
        }
        if client.queue.count > 5 {
            // Behind: drop the backlog and resume at the next keyframe rather than
            // letting the delay grow.
            client.queue.removeAll()
            client.waitingForKeyframe = true
            client.lock.unlock()
            return
        }
        client.queue.append(data)
        let shouldStart = !client.sending
        if shouldStart { client.sending = true }
        client.lock.unlock()
        if shouldStart { pump(client) }
    }

    private func pump(_ client: Client) {
        client.lock.lock()
        guard !client.queue.isEmpty else {
            client.sending = false
            client.lock.unlock()
            return
        }
        let next = client.queue.removeFirst()
        client.lock.unlock()

        client.connection.send(content: next, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.drop(client)
                client.lock.lock(); client.sending = false; client.lock.unlock()
                return
            }
            self?.pump(client)
        })
    }

    // MARK: - discovery

    /// Shouts "I'm here" on the local network once a second so the tablet can find the
    /// Mac by itself - nobody should have to type an IP address. Plain BSD sockets here:
    /// Network.framework quietly refuses to broadcast.
    /// Broadcast address of every network this Mac is on (192.168.0.255 and friends).
    private static func subnetBroadcasts() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
               (flags & IFF_BROADCAST) == IFF_BROADCAST,
               let broadcast = current.pointee.ifa_dstaddr,
               broadcast.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(broadcast, socklen_t(broadcast.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty, ip != "0.0.0.0" { out.append(ip) }
                }
            }
            ptr = current.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return out
    }

    private func startAnnouncing() {
        announcing = true
        let name = Host.current().localizedName ?? "Mac"
        DispatchQueue.global(qos: .background).async { [weak self] in
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

            let message = Array("TABSCREEN \(name)".utf8)
            while self?.announcing == true {
                var targets = ["255.255.255.255"]
                targets.append(contentsOf: Server.subnetBroadcasts())
                for target in targets {
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = UInt16(8089).bigEndian
                    addr.sin_addr.s_addr = inet_addr(target)
                    _ = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, message, message.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
            close(fd)
        }
    }
}
