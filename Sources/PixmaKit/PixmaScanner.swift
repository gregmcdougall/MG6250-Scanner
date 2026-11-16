import CoreGraphics
import Foundation

public enum ColorMode: String, CaseIterable, Sendable {
    case color, gray
    public var channels: Int { self == .color ? 3 : 1 }
}

/// A rectangle on the scanner glass, in inches from the top-left corner.
public struct ScanArea: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let fullPlaten = ScanArea(x: 0, y: 0, width: PixmaScanner.platenWidth, height: PixmaScanner.platenHeight)
}

public struct ScanSettings: Sendable {
    public var dpi: Int
    public var mode: ColorMode
    public var area: ScanArea
    public init(dpi: Int = 300, mode: ColorMode = .color, area: ScanArea = .fullPlaten) {
        self.dpi = dpi; self.mode = mode; self.area = area
    }
}

/// Finished scan: tightly packed 8-bit RGB or gray rows.
public struct ScanResult: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let dpi: Int
    public let pixels: Data

    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let space = channels == 3 ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                       bytesPerRow: width * channels, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

public enum ScanPhase: Sendable {
    case connecting
    case warmingUp
    case scanning(fraction: Double)
    case finishing
}

/// Thread-safe cancellation flag shared between the UI and a running scan.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Driver for the flatbed scanner in the Canon PIXMA MG6200 series
/// (MG6210/MG6220/MG6250…) over the network.
///
/// The scanner speaks Canon's "generation 5" PIXMA protocol: 16 byte
/// big-endian command blocks, answered with an 8 byte status header. Any
/// parameter or result data ends in a checksum byte that makes the data sum
/// to zero. A scan job is bracketed by small XML "StartJob"/"EndJob"
/// messages sent over the same channel.
public final class PixmaScanner {
    /// Glass size in inches (638 x 877 units of 1/75 inch, i.e. A4/Letter).
    public static let platenWidth = 638.0 / 75.0
    public static let platenHeight = 877.0 / 75.0
    public static let resolutions = [75, 150, 300, 600, 1200]

    public let host: String

    public init(host: String) {
        self.host = host
    }

    private enum Cmd: UInt16 {
        case startSession = 0xDB20
        case gamma = 0xEE20
        case abortSession = 0xEF20
        case readImage = 0xD420
        case scanParam = 0xD820
        case scanStart = 0xD920
        case status = 0xDA20
    }

    private static let statusOK: UInt16 = 0x0606
    private static let statusBusy: UInt16 = 0x1414
    private static let statusFailed: UInt16 = 0x1515
    private static let imageBlockSize = 512 * 1024

    private static func xml(operation: String, extraNamespace: String = "", body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\" ?>"
            + "<cmd xmlns:ivec=\"http://www.canon.com/ns/cmd/2008/07/common/\"\(extraNamespace)>"
            + "<ivec:contents><ivec:operation>\(operation)</ivec:operation>"
            + "<ivec:param_set servicetype=\"scan\"><ivec:jobID>00000001</ivec:jobID>\(body)"
            + "</ivec:param_set></ivec:contents></cmd>"
    }
    private static let xmlStartJob = xml(operation: "StartJob", body: "<ivec:bidi>1</ivec:bidi>")
    private static let xmlModeShift = xml(
        operation: "VendorCmd", extraNamespace: " xmlns:vcn=\"http://www.canon.com/ns/cmd/2008/07/canon/\"",
        body: "<vcn:ijoperation>ModeShift</vcn:ijoperation><vcn:ijmode>1</vcn:ijmode>")
    private static let xmlEndJob = xml(operation: "EndJob", body: "")

    // MARK: - Scanning

    /// Run one flatbed scan. Blocks the calling thread until the image has
    /// been transferred; call it off the main thread.
    public func scan(_ settings: ScanSettings, cancel: CancelToken = CancelToken(),
                     progress: (ScanPhase) -> Void = { _ in }) throws -> ScanResult {
        let geo = try Geometry(settings)
        progress(.connecting)

        let io = try BJNPSession(host: host)
        try io.open()
        defer { io.closeSession() }

        guard try xmlDialog(io, Self.xmlStartJob) else {
            throw ScanError.deviceFailed("the scanner refused to start a job (is it in use or showing an error?)")
        }
        // From here on the job must always be closed again, or the printer
        // keeps showing "scanning" on its panel.
        var sessionStarted = false
        defer {
            if sessionStarted { _ = try? command(io, .abortSession) }
            _ = try? xmlDialog(io, Self.xmlEndJob)
        }
        guard try xmlDialog(io, Self.xmlModeShift) else {
            throw ScanError.deviceFailed("the scanner could not switch to scan mode")
        }

        // The scanner answers "busy" while it is finishing something else.
        var status = try command(io, .startSession).status
        var tries = 0
        while status == Self.statusBusy && tries < 15 {
            if cancel.isCancelled { throw ScanError.cancelled }
            Thread.sleep(forTimeInterval: 1)
            status = try command(io, .startSession).status
            tries += 1
        }
        sessionStarted = true
        try check(status, "start session")

        // The gamma table is sent three times, as Canon's own driver does.
        let gamma = Self.gammaTable(2.2)
        for _ in 0..<3 { try check(try command(io, .gamma, dataOut: gamma).status, "set gamma") }
        try check(try command(io, .scanParam, dataOut: geo.parameterBlock()).status, "set scan parameters")
        try check(try command(io, .scanStart).status, "start scan")

        // Wait for lamp warm-up / calibration.
        progress(.warmingUp)
        var waited = 0
        while true {
            if cancel.isCancelled { throw ScanError.cancelled }
            let reply = try command(io, .status, dataIn: 8)
            try check(reply.status, "query status")
            if let first = reply.data.first, first & 0x03 != 0 { break }
            waited += 1
            if waited > 120 { throw ScanError.timeout("calibration did not finish") }
            Thread.sleep(forTimeInterval: 1)
        }
        Thread.sleep(forTimeInterval: 1)

        // Pull image blocks until the scanner flags both "no more data"
        // (0x20) and "end of scan" (0x08).
        var assembler = LineAssembler(geo)
        var lastBlock: UInt8 = 0
        progress(.scanning(fraction: 0))
        while lastBlock & 0x28 != 0x28 {
            if cancel.isCancelled { throw ScanError.cancelled }
            var request = [UInt8](repeating: 0, count: 16)
            request.setBE16(Cmd.readImage.rawValue, at: 0)
            request.setBE32(UInt32((lastBlock & 0x20 == 0 ? Self.imageBlockSize : 32) + 8), at: 12)
            try io.send(request)
            var reply = try readReply(io)
            try check(reply.be16(0), "read image")
            guard reply.count >= 16 else { throw ScanError.protocolError("short image header") }
            lastBlock = reply[8] & 0x38
            let length = Int(reply.be32(12))
            // Large blocks arrive split over several BJNP read requests.
            var stalls = 0
            while reply.count < 16 + length {
                let more = try io.read()
                if more.isEmpty {
                    stalls += 1
                    if stalls > 300 { throw ScanError.timeout("image data stopped arriving") }
                    Thread.sleep(forTimeInterval: 0.05)
                } else {
                    stalls = 0
                    reply += more
                }
            }
            if length == 0 {
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                assembler.append(reply[16..<(16 + length)])
                progress(.scanning(fraction: min(1, Double(assembler.rows) / Double(geo.h))))
            }
        }
        progress(.finishing)
        guard assembler.rows > 0 else { throw ScanError.deviceFailed("no image data was returned") }
        return ScanResult(width: geo.w, height: assembler.rows, channels: geo.channels, dpi: settings.dpi,
                          pixels: assembler.finish())
    }

    // MARK: - Protocol plumbing

    private func readReply(_ io: BJNPSession) throws -> [UInt8] {
        // An empty read means "nothing yet"; poll for up to ~10 s.
        for _ in 0..<100 {
            let data = try io.read()
            if !data.isEmpty { return data }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ScanError.timeout("no reply to a scanner command")
    }

    private func xmlDialog(_ io: BJNPSession, _ message: String) throws -> Bool {
        try io.send(Array(message.utf8))
        let reply = String(decoding: try readReply(io), as: UTF8.self)
        return reply.contains("<ivec:response>OK</ivec:response>")
    }

    /// Execute one command. `dataOut` is parameter data whose last byte is
    /// reserved for the checksum; `dataIn` is the expected result length.
    private func command(_ io: BJNPSession, _ cmd: Cmd, dataOut: [UInt8] = [], dataIn: Int = 0) throws -> (status: UInt16, data: [UInt8]) {
        var packet = [UInt8](repeating: 0, count: 16)
        packet.setBE16(cmd.rawValue, at: 0)
        packet.setBE16(UInt16(dataOut.count + dataIn), at: 14)
        if !dataOut.isEmpty {
            var data = dataOut
            let sum = data.dropLast().reduce(UInt8(0)) { $0 &+ $1 }
            data[data.count - 1] = 0 &- sum
            packet += data
        }
        try io.send(packet)
        let reply = try readReply(io)
        guard reply.count >= 8 else { throw ScanError.protocolError("short reply to command 0x\(String(cmd.rawValue, radix: 16))") }
        let payload = Array(reply.dropFirst(8))
        if dataIn > 0 && payload.count == dataIn {
            guard payload.reduce(UInt8(0), { $0 &+ $1 }) == 0 else { throw ScanError.protocolError("checksum mismatch") }
        }
        return (reply.be16(0), payload)
    }

    private func check(_ status: UInt16, _ what: String) throws {
        switch status {
        case Self.statusOK: return
        case Self.statusBusy: throw ScanError.busy
        case Self.statusFailed: throw ScanError.deviceFailed("\(what) was rejected (cancelled at the printer?)")
        default: throw ScanError.deviceFailed("\(what) returned status 0x\(String(status, radix: 16))")
        }
    }

    /// 1024-entry, 16-bit little-endian gamma curve with its 4 byte header
    /// and room for padding + checksum.
    private static func gammaTable(_ gamma: Double) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 1024 * 2 + 8)
        t[0] = 0x10
        t.setBE16(0x0804, at: 2)
        for i in 0..<1024 {
            let v = UInt16(65535.0 * pow(Double(i) / 1023.0, 1.0 / gamma) + 0.5)
            t[4 + 2 * i] = UInt8(v & 0xFF)
            t[5 + 2 * i] = UInt8(v >> 8)
        }
        return t
    }
}

// MARK: - Geometry

/// Pixel geometry of a scan. The scanner wants the raw line width to be a
/// multiple of 32 pixels starting on a 32 pixel boundary, so we scan a
/// slightly wider strip (`rawWidth`, starting `leftPad` pixels early) and
/// crop each line afterwards.
struct Geometry {
    let dpi: Int
    let channels: Int
    let x: Int, y: Int, w: Int, h: Int
    let leftPad: Int
    let rawWidth: Int

    init(_ s: ScanSettings) throws {
        guard PixmaScanner.resolutions.contains(s.dpi) || s.dpi == 2400 || s.dpi == 4800 else {
            throw ScanError.protocolError("unsupported resolution \(s.dpi) dpi")
        }
        dpi = s.dpi
        channels = s.mode.channels
        let maxW = 638 * dpi / 75, maxH = 877 * dpi / 75
        let px = { (inches: Double) in Int((inches * Double(s.dpi)).rounded()) }
        let x0 = min(max(0, px(s.area.x)), maxW - 16)
        let y0 = min(max(0, px(s.area.y)), maxH - 16)
        x = x0; y = y0
        w = min(max(16, px(s.area.width)), maxW - x0)
        h = min(max(16, px(s.area.height)), maxH - y0)
        leftPad = x0 % 32
        rawWidth = (w + leftPad + 31) / 32 * 32
    }

    var rawLineBytes: Int { rawWidth * channels }

    func parameterBlock() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 0x38)
        p[0x00] = 0x01                       // source: flatbed
        p[0x01] = 0x01
        p[0x02] = 0x01
        p[0x05] = 0x01                       // calibrate before scanning
        p.setBE16(UInt16(dpi) | 0x8000, at: 0x08)
        p.setBE16(UInt16(dpi) | 0x8000, at: 0x0A)
        p.setBE32(UInt32(x - leftPad), at: 0x0C)
        p.setBE32(UInt32(y), at: 0x10)
        p.setBE32(UInt32(rawWidth), at: 0x14)
        p.setBE32(UInt32(h), at: 0x18)
        p[0x1C] = channels == 3 ? 0x08 : 0x04
        p[0x1D] = UInt8(8 * channels)        // bits per pixel
        p[0x1F] = 0x01
        p[0x20] = 0xFF
        p[0x21] = 0x81
        p[0x23] = 0x02
        p[0x24] = 0x01
        p[0x30] = 0x01
        return p                             // last byte = checksum, filled in on send
    }
}

/// Turns the raw byte stream into cropped image rows.
///
/// Above 600 dpi the sensor delivers each line as `n = dpi / 600`
/// interleaved sub-images laid side by side; pixel `i` of the raw line
/// belongs at position `n * (i mod m) + i / m`, where `m = rawWidth / n`.
struct LineAssembler {
    private let geo: Geometry
    private let subImages: Int
    private var pending = [UInt8]()
    private var output: Data
    private(set) var rows = 0
    private var scratch: [UInt8]

    init(_ geo: Geometry) {
        self.geo = geo
        subImages = geo.dpi / 600
        output = Data(capacity: geo.w * geo.channels * geo.h)
        scratch = [UInt8](repeating: 0, count: geo.rawLineBytes)
        pending.reserveCapacity(geo.rawLineBytes + 600 * 1024)
    }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        pending.append(contentsOf: bytes)
        let lineBytes = geo.rawLineBytes
        let c = geo.channels
        let cropStart = geo.leftPad * c
        let cropLength = geo.w * c
        var offset = 0
        while pending.count - offset >= lineBytes && rows < geo.h {
            pending.withUnsafeBufferPointer { src in
                let line = UnsafeBufferPointer(rebasing: src[offset..<(offset + lineBytes)])
                if subImages > 1 {
                    let n = subImages, m = geo.rawWidth / n
                    scratch.withUnsafeMutableBufferPointer { dst in
                        var i = 0
                        for sub in 0..<n {
                            for col in 0..<m {
                                let j = (n * col + sub) * c
                                for k in 0..<c { dst[j + k] = line[i * c + k] }
                                i += 1
                            }
                        }
                        output.append(UnsafeBufferPointer(rebasing: dst[cropStart..<(cropStart + cropLength)]))
                    }
                } else {
                    output.append(UnsafeBufferPointer(rebasing: line[cropStart..<(cropStart + cropLength)]))
                }
            }
            rows += 1
            offset += lineBytes
        }
        pending.removeFirst(offset)
    }

    func finish() -> Data { output }
}
