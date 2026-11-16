import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, png, jpeg, tiff
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }
    var utType: UTType {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

struct ExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Imaging {
    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let gray = image.colorSpace?.model == .monochrome
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// A smaller copy for on-screen display; full-resolution scans can be
    /// hundreds of megabytes.
    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = makeContext(width: w, height: h, like: image) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(width: h, height: w, like: image) else { return nil }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func encode(_ image: CGImage, dpi: Int, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if type == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }  // LZW
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func writeImage(_ image: CGImage, dpi: Int, format: ExportFormat, to url: URL) throws {
        guard let data = encode(image, dpi: dpi, type: format.utType, quality: 0.9) else {
            throw ExportError(message: "Could not encode the image as \(format.title).")
        }
        try data.write(to: url, options: .atomic)
    }

    /// Multi-page PDF, each page at its physical size with the scan stored
    /// as JPEG so files stay a sensible size.
    static func writePDF(_ pages: [(image: CGImage, dpi: Int)], to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard let pdf = CGContext(temp as CFURL, mediaBox: nil, nil) else {
            throw ExportError(message: "Could not create the PDF file.")
        }
        for page in pages {
            var box = CGRect(x: 0, y: 0,
                             width: Double(page.image.width) / Double(page.dpi) * 72,
                             height: Double(page.image.height) / Double(page.dpi) * 72)
            var drawable = page.image
            if let jpeg = encode(page.image, dpi: page.dpi, type: .jpeg, quality: 0.85),
               let provider = CGDataProvider(data: jpeg as CFData),
               let compressed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                drawable = compressed
            }
            pdf.beginPage(mediaBox: &box)
            pdf.draw(drawable, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
