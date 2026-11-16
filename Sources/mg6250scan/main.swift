import CoreGraphics
import Foundation
import ImageIO
import PixmaKit
import UniformTypeIdentifiers

let usage = """
mg6250scan — scan from a Canon PIXMA MG6200-series (MG6250) over the network

usage: mg6250scan [options] -o <file.png|.jpg|.tiff>
       mg6250scan --discover

  --host <addr>        scanner address (default: first scanner found)
  --dpi <n>            75, 150, 300, 600 or 1200 (default 300)
  --gray               grayscale instead of colour
  --area <x,y,w,h>     region to scan in millimetres (default: whole glass)
  --discover           list scanners on the local network
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var host: String?
var settings = ScanSettings()
var output: String?
var discoverOnly = false

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) needs a value\n\n\(usage)") }
    return args.removeFirst()
}
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--host": host = value(arg)
    case "--dpi": settings.dpi = Int(value(arg)) ?? 0
    case "--gray": settings.mode = .gray
    case "--area":
        let mm = value(arg).split(separator: ",").compactMap { Double($0) }
        guard mm.count == 4 else { fail("--area wants x,y,w,h in mm") }
        settings.area = ScanArea(x: mm[0] / 25.4, y: mm[1] / 25.4, width: mm[2] / 25.4, height: mm[3] / 25.4)
    case "-o", "--output": output = value(arg)
    case "--discover": discoverOnly = true
    case "-h", "--help": print(usage); exit(0)
    default: fail("unknown option \(arg)\n\n\(usage)")
    }
}

if discoverOnly || host == nil {
    let found = PixmaScanner.discover()
    if discoverOnly {
        if found.isEmpty { print("No scanners found.") }
        for s in found { print("\(s.host)\t\(s.model)\t\(s.mac)") }
        exit(0)
    }
    guard let first = found.first else { fail("No scanner found on the network; pass --host.") }
    host = first.host
    print("Using \(first.model) at \(first.host)")
}
guard let host, let output else { fail(usage) }
guard PixmaScanner.resolutions.contains(settings.dpi) else { fail("--dpi must be one of \(PixmaScanner.resolutions)") }

let ext = (output as NSString).pathExtension.lowercased()
let types: [String: UTType] = ["png": .png, "jpg": .jpeg, "jpeg": .jpeg, "tif": .tiff, "tiff": .tiff]
guard let type = types[ext] else { fail("output must end in .png, .jpg or .tiff") }

do {
    var lastPercent = -1
    let started = Date()
    let result = try PixmaScanner(host: host).scan(settings) { phase in
        switch phase {
        case .connecting: print("Connecting…")
        case .warmingUp: print("Warming up…")
        case .scanning(let f):
            let percent = Int(f * 100)
            if percent != lastPercent {
                lastPercent = percent
                print("\rScanning \(percent)%", terminator: "")
                fflush(stdout)
            }
        case .finishing: print("")
        }
    }
    guard let image = result.makeCGImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, type.identifier as CFString, 1, nil)
    else { fail("could not create \(output)") }
    let props: [CFString: Any] = [
        kCGImagePropertyDPIWidth: result.dpi, kCGImagePropertyDPIHeight: result.dpi,
        kCGImageDestinationLossyCompressionQuality: 0.9,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("could not write \(output)") }
    print(String(format: "Saved %@ (%d × %d px, %d dpi) in %.1f s", output, result.width, result.height, result.dpi,
                 Date().timeIntervalSince(started)))
} catch {
    fail("\n" + (error.localizedDescription))
}
