import Darwin
import Foundation

/// Errors surfaced by the driver.
public enum ScanError: Error, LocalizedError, Equatable {
    case network(String)
    case timeout(String)
    case busy
    case deviceFailed(String)
    case protocolError(String)
    case cancelled
    /// The OS refused to route packets to the scanner. On macOS 15+ this is
    /// almost always the Local Network privacy switch.
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "Network error: \(m)"
        case .timeout(let m): return "The scanner did not respond (\(m)). Check that it is switched on and on the same network."
        case .busy: return "The scanner is busy. Wait for it to finish what it is doing and try again."
        case .deviceFailed(let m): return "The scanner reported a failure: \(m)"
        case .protocolError(let m): return "Unexpected reply from the scanner: \(m)"
        case .cancelled: return "Scan cancelled."
        case .unreachable:
            return "Can't reach the scanner. If macOS asked whether this app may find devices on your local network, choose Allow — or switch it on in System Settings › Privacy & Security › Local Network — then try again. Otherwise check the scanner is on and the address is right."
        }
    }
}

/// Canon BJNP: the UDP/TCP wrapper Canon uses to carry its USB scanner
/// protocol over the network. Every packet starts with a 16 byte header:
///
///     "BJNP" | dev type (2 = scanner, 0x82 in replies) | command | 0 0 |
///     sequence (be16) | session id (be16) | payload length (be32)
///
/// Session setup and teardown happen over UDP; scanner commands travel over
/// a TCP connection to the same port, as "send" (0x21) and "read" (0x20)
/// requests.
enum BJNP {
    static let port: UInt16 = 8612
    static let headerLength = 16

    enum Command: UInt8 {
        case discover = 0x01
        case jobDetails = 0x10
        case close = 0x11
        case tcpRead = 0x20
        case tcpSend = 0x21
        case getID = 0x30
    }

    static func header(_ cmd: Command, seq: UInt16, session: UInt16, payloadLength: Int) -> [UInt8] {
        var h: [UInt8] = [0x42, 0x4A, 0x4E, 0x50, 0x02, cmd.rawValue, 0, 0]
        h.appendBE16(seq)
        h.appendBE16(session)
        h.appendBE32(UInt32(payloadLength))
        return h
    }

    /// Resolve a host name or dotted address to an IPv4 socket address.
    static func resolve(_ host: String) throws -> sockaddr_in {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let info = res, let sa = info.pointee.ai_addr else {
            throw ScanError.network("cannot resolve \(host)")
        }
        defer { freeaddrinfo(res) }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    static func setTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func sendDatagram(_ fd: Int32, _ bytes: [UInt8], to addr: sockaddr_in) -> Bool {
        var a = addr
        let n = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return n == bytes.count
    }

    static func receiveDatagram(_ fd: Int32) -> (bytes: [UInt8], from: sockaddr_in)? {
        var buf = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buf, buf.count, 0, sa, &len)
            }
        }
        guard n >= headerLength else { return nil }
        return (Array(buf[0..<n]), from)
    }

    /// One UDP request/response exchange, retried a few times.
    static func udpExchange(_ addr: sockaddr_in, _ cmd: Command, seq: UInt16, session: UInt16,
                            payload: [UInt8] = [], timeout: Double = 2.0, attempts: Int = 3) throws -> [UInt8] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ScanError.network("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        setTimeout(fd, seconds: timeout)
        let packet = header(cmd, seq: seq, session: session, payloadLength: payload.count) + payload
        for _ in 0..<attempts {
            guard sendDatagram(fd, packet, to: addr) else {
                if errno == EHOSTUNREACH || errno == ENETUNREACH || errno == EPERM { throw ScanError.unreachable }
                throw ScanError.network("send: \(String(cString: strerror(errno)))")
            }
            // Skip stale replies carrying another sequence number.
            while let (reply, _) = receiveDatagram(fd) {
                if reply[5] == cmd.rawValue && reply.be16(8) == seq { return reply }
            }
        }
        throw ScanError.timeout("no reply to BJNP command 0x\(String(cmd.rawValue, radix: 16))")
    }
}

/// An open BJNP scan session: UDP job registration plus the TCP data channel.
final class BJNPSession {
    private let addr: sockaddr_in
    private var seq: UInt16 = 0
    private var session: UInt16 = 0
    private var tcp: Int32 = -1

    init(host: String) throws {
        addr = try BJNP.resolve(host)
    }

    deinit { closeSession() }

    private func nextSeq() -> UInt16 {
        seq &+= 1
        return seq
    }

    /// Announce the job (host, user, title) to get a session id, then connect.
    func open() throws {
        func utf16Field(_ s: String, _ size: Int) -> [UInt8] {
            var out = [UInt8]()
            for unit in s.utf16.prefix(size / 2 - 1) {
                out.append(UInt8(unit >> 8)); out.append(UInt8(unit & 0xFF))
            }
            return out + [UInt8](repeating: 0, count: size - out.count)
        }
        let hostName = ProcessInfo.processInfo.hostName
        let payload = [UInt8](repeating: 0, count: 8)
            + utf16Field(hostName, 64) + utf16Field(NSUserName(), 64) + utf16Field("MG6250 Scanner", 256)
        let reply = try BJNP.udpExchange(addr, .jobDetails, seq: nextSeq(), session: 0, payload: payload)
        session = reply.be16(10)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ScanError.network("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking connect so an unreachable scanner fails in seconds.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var a = addr
        let rc = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else {
                close(fd); throw ScanError.network("connect: \(String(cString: strerror(errno)))")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&pfd, 1, 6000) == 1,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0, soError == 0 else {
                close(fd); throw ScanError.timeout("could not connect to the scanner")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        BJNP.setTimeout(fd, seconds: 30)
        tcp = fd
    }

    /// Send a block of scanner-protocol bytes and wait for the length ack.
    func send(_ data: [UInt8]) throws {
        let packet = BJNP.header(.tcpSend, seq: nextSeq(), session: session, payloadLength: data.count) + data
        try writeAll(packet)
        let ack = try readPacket(expecting: .tcpSend)
        guard ack.count == 4, Int(ack.be32(0)) == data.count else {
            throw ScanError.protocolError("bad write acknowledgement")
        }
    }

    /// Ask the scanner for whatever it has queued. May legitimately be empty.
    func read() throws -> [UInt8] {
        try writeAll(BJNP.header(.tcpRead, seq: nextSeq(), session: session, payloadLength: 0))
        return try readPacket(expecting: .tcpRead)
    }

    func closeSession() {
        if tcp >= 0 {
            close(tcp)
            tcp = -1
            _ = try? BJNP.udpExchange(addr, .close, seq: nextSeq(), session: session, timeout: 1.0, attempts: 2)
        }
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(tcp, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                throw ScanError.network("connection to the scanner was lost")
            }
            sent += n
        }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { recv(tcp, $0.baseAddress! + got, count - got, 0) }
            if n == 0 { throw ScanError.network("the scanner closed the connection") }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw ScanError.timeout("data transfer stalled") }
                throw ScanError.network(String(cString: strerror(errno)))
            }
            got += n
        }
        return buf
    }

    private func readPacket(expecting cmd: BJNP.Command) throws -> [UInt8] {
        let h = try readExactly(BJNP.headerLength)
        guard h[0] == 0x42, h[1] == 0x4A, h[2] == 0x4E, h[3] == 0x50, h[5] == cmd.rawValue, h.be16(8) == seq else {
            throw ScanError.protocolError("unexpected BJNP header")
        }
        let length = Int(h.be32(12))
        return length == 0 ? [] : try readExactly(length)
    }
}

// MARK: - Byte helpers

extension Array where Element == UInt8 {
    func be16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }
    func be32(_ at: Int) -> UInt32 {
        UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3])
    }
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
    mutating func setBE16(_ v: UInt16, at i: Int) { self[i] = UInt8(v >> 8); self[i + 1] = UInt8(v & 0xFF) }
    mutating func setBE32(_ v: UInt32, at i: Int) {
        self[i] = UInt8(v >> 24); self[i + 1] = UInt8((v >> 16) & 0xFF)
        self[i + 2] = UInt8((v >> 8) & 0xFF); self[i + 3] = UInt8(v & 0xFF)
    }
}
