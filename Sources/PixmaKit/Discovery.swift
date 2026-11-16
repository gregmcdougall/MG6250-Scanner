import Darwin
import Foundation

public struct ScannerInfo: Identifiable, Hashable, Sendable {
    public let host: String
    public let model: String
    public let mac: String
    public var id: String { host }
    /// True for the model family this driver was written and tested for.
    public var isSupportedModel: Bool { model.uppercased().contains("MG62") }
}

extension PixmaScanner {
    /// Ask one scanner for its IEEE 1284 identity (model name etc).
    public static func identify(host: String, timeout: Double = 2.0) throws -> ScannerInfo {
        let addr = try BJNP.resolve(host)
        let reply = try BJNP.udpExchange(addr, .getID, seq: 1, session: 0, timeout: timeout, attempts: 2)
        let text = String(decoding: reply.dropFirst(BJNP.headerLength + 2), as: UTF8.self)
        var fields = [String: String]()
        for part in text.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        var mac = ""
        if let d = try? BJNP.udpExchange(addr, .discover, seq: 2, session: 0, timeout: timeout, attempts: 1),
           d.count >= BJNP.headerLength + 12 {
            mac = d[(BJNP.headerLength + 6)..<(BJNP.headerLength + 12)].map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        let model = fields["DES"] ?? fields["MDL"].map { "Canon \($0)" } ?? "Canon scanner"
        return ScannerInfo(host: host, model: model, mac: mac)
    }

    /// Find scanners on the local network. Blocks for about `timeout`
    /// seconds. Uses Bonjour (the printer advertises `_scanner._tcp`) and,
    /// as a fallback, a BJNP broadcast on every local IPv4 network.
    public static func discover(timeout: Double = 2.0) -> [ScannerInfo] {
        let bonjour = BonjourBrowser()
        bonjour.start()
        defer { bonjour.stop() }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { if fd >= 0 { close(fd) } }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        BJNP.setTimeout(fd, seconds: 0.3)

        let packet = BJNP.header(.discover, seq: 0, session: 0, payloadLength: 0)
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        var cursor: UnsafeMutablePointer<ifaddrs>? = getifaddrs(&ifaddrs) == 0 ? ifaddrs : nil
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let dst = ifa.pointee.ifa_dstaddr else { continue }
            var target = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            target.sin_port = BJNP.port.bigEndian
            _ = BJNP.sendDatagram(fd, packet, to: target)
        }
        freeifaddrs(ifaddrs)

        var hosts = [String]()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Let Bonjour callbacks run on this thread's run loop.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            guard fd >= 0, let (reply, from) = BJNP.receiveDatagram(fd), reply[4] == 0x82 else { continue }
            var a = from.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: buf)
            if !hosts.contains(host) { hosts.append(host) }
        }
        for name in bonjour.hostNames where !hosts.contains(name) { hosts.append(name) }

        // Keep only devices that answer BJNP, one entry per MAC address.
        var seen = Set<String>()
        var found = [ScannerInfo]()
        for host in hosts {
            guard let info = try? identify(host: host, timeout: 1.0) else { continue }
            if !info.mac.isEmpty && !seen.insert(info.mac).inserted { continue }
            found.append(info)
        }
        return found
    }
}

/// Browses for `_scanner._tcp` and resolves each service to a host name.
private final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services = [NetService]()
    private(set) var hostNames = [String]()

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_scanner._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port == Int(BJNP.port), var name = sender.hostName else { return }
        if name.hasSuffix(".") { name.removeLast() }
        if !hostNames.contains(name) { hostNames.append(name) }
    }
}
