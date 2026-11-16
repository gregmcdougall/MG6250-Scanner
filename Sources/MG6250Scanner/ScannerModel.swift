import AppKit
import PixmaKit
import SwiftUI

struct Page: Identifiable {
    let id = UUID()
    var image: CGImage      // full resolution, used for export
    var display: CGImage    // reduced copy for the screen
    let dpi: Int
}

struct PaperSize: Identifiable, Hashable {
    let name: String
    let widthMM: Double
    let heightMM: Double
    var id: String { name }

    static let all = [
        PaperSize(name: "Whole glass", widthMM: PixmaScanner.platenWidth * 25.4, heightMM: PixmaScanner.platenHeight * 25.4),
        PaperSize(name: "A4", widthMM: 210, heightMM: 297),
        PaperSize(name: "US Letter", widthMM: 215.9, heightMM: 279.4),
        PaperSize(name: "A5", widthMM: 148, heightMM: 210),
        PaperSize(name: "A6", widthMM: 105, heightMM: 148),
        PaperSize(name: "Photo 10 × 15 cm", widthMM: 102, heightMM: 152),
        PaperSize(name: "Photo 13 × 18 cm", widthMM: 127, heightMM: 178),
    ]
}

@MainActor
final class ScannerModel: ObservableObject {
    static let platen = CGRect(x: 0, y: 0, width: PixmaScanner.platenWidth, height: PixmaScanner.platenHeight)

    // Scanner
    @Published var scanners: [ScannerInfo] = []
    @Published var searching = false
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }

    // Settings
    @Published var dpi: Int { didSet { UserDefaults.standard.set(dpi, forKey: "dpi") } }
    @Published var mode: ColorMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") } }
    @Published var format: ExportFormat { didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") } }
    /// Area to scan, in inches on the glass.
    @Published var selection = ScannerModel.platen {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set([selection.minX, selection.minY, selection.width, selection.height], forKey: "selection")
        }
    }

    // Results
    @Published var preview: CGImage?
    @Published var pages: [Page] = []
    @Published var selectedPageID: UUID?

    // Activity
    @Published var busy = false
    @Published var statusText = ""
    @Published var progress: Double?
    @Published var errorMessage: String?

    private var cancelToken: CancelToken?

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        let savedDPI = d.integer(forKey: "dpi")
        dpi = PixmaScanner.resolutions.contains(savedDPI) ? savedDPI : 300
        mode = ColorMode(rawValue: d.string(forKey: "mode") ?? "") ?? .color
        format = ExportFormat(rawValue: d.string(forKey: "format") ?? "") ?? .pdf
        // Restore the last scan area, if it still fits on the glass.
        if let saved = d.array(forKey: "selection") as? [Double], saved.count == 4 {
            let rect = CGRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
            if rect.width >= 0.25, rect.height >= 0.25, Self.platen.insetBy(dx: -0.001, dy: -0.001).contains(rect) {
                selection = rect
            }
        }
    }

    var selectedPage: Page? { pages.first { $0.id == selectedPageID } }

    var selectionSummary: String {
        let w = Int((selection.width * Double(dpi)).rounded()), h = Int((selection.height * Double(dpi)).rounded())
        let megabytes = Double(w * h * mode.channels) / 1_048_576
        return String(format: "%.0f × %.0f mm  ·  %d × %d px  ·  %.0f MB", selection.width * 25.4, selection.height * 25.4, w, h, megabytes)
    }

    // MARK: Discovery

    func findScanners() {
        guard !searching else { return }
        searching = true
        // Bonjour browsing needs a thread with its own run loop.
        Thread.detachNewThread {
            let found = PixmaScanner.discover()
            Task { @MainActor in
                self.scanners = found
                self.searching = false
                if self.host.isEmpty, let first = found.first { self.host = first.host }
            }
        }
    }

    // MARK: Scanning

    func scanPreview() {
        run(ScanSettings(dpi: 75, mode: .color, area: .fullPlaten), label: "Preview") { image, _ in
            self.preview = image
            self.selectedPageID = nil
        }
    }

    func scan() {
        let area = ScanArea(x: selection.minX, y: selection.minY, width: selection.width, height: selection.height)
        run(ScanSettings(dpi: dpi, mode: mode, area: area), label: "Scan") { image, dpi in
            let page = Page(image: image, display: Imaging.downscaled(image, maxSide: 2400), dpi: dpi)
            self.pages.append(page)
            self.selectedPageID = page.id
        }
    }

    func cancel() {
        cancelToken?.cancel()
        statusText = "Cancelling…"
    }

    private func run(_ settings: ScanSettings, label: String, completion: @escaping @MainActor (CGImage, Int) -> Void) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !busy else { return }
        guard !host.isEmpty else {
            errorMessage = "Enter the scanner's address, or use Find to search the network."
            return
        }
        let token = CancelToken()
        cancelToken = token
        busy = true
        errorMessage = nil
        progress = nil
        statusText = "Connecting…"

        Task.detached(priority: .userInitiated) {
            do {
                var lastStep = -1
                let result = try PixmaScanner(host: host).scan(settings, cancel: token) { phase in
                    if case .scanning(let fraction) = phase {
                        let step = Int(fraction * 200)
                        if step == lastStep { return }
                        lastStep = step
                    }
                    Task { @MainActor in self.show(phase, label: label) }
                }
                guard let image = result.makeCGImage() else { throw ScanError.protocolError("could not build the image") }
                await MainActor.run {
                    completion(image, result.dpi)
                    self.finish(error: nil)
                }
            } catch {
                await MainActor.run { self.finish(error: error) }
            }
        }
    }

    private func show(_ phase: ScanPhase, label: String) {
        guard busy else { return }
        switch phase {
        case .connecting: statusText = "Connecting…"
        case .warmingUp: statusText = "Warming up…"
        case .scanning(let fraction):
            progress = fraction
            statusText = "\(label): \(Int(fraction * 100))%"
        case .finishing: statusText = "Finishing…"
        }
    }

    private func finish(error: Error?) {
        busy = false
        progress = nil
        statusText = ""
        cancelToken = nil
        if let error, (error as? ScanError) != .cancelled {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Pages

    func rotateSelected(clockwise: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == selectedPageID }),
              let image = Imaging.rotated(pages[index].image, clockwise: clockwise) else { return }
        pages[index].image = image
        pages[index].display = Imaging.downscaled(image, maxSide: 2400)
    }

    func deleteSelected() {
        guard let index = pages.firstIndex(where: { $0.id == selectedPageID }) else { return }
        pages.remove(at: index)
        selectedPageID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
    }

    private func rect(for paper: PaperSize) -> CGRect {
        CGRect(x: 0, y: 0,
               width: min(paper.widthMM / 25.4, Self.platen.width),
               height: min(paper.heightMM / 25.4, Self.platen.height))
    }

    /// The paper size the current area corresponds to, or nil for a
    /// hand-drawn (custom) area.
    var currentPaper: PaperSize? {
        PaperSize.all.first { paper in
            let r = rect(for: paper)
            return abs(r.minX - selection.minX) < 0.005 && abs(r.minY - selection.minY) < 0.005
                && abs(r.width - selection.width) < 0.005 && abs(r.height - selection.height) < 0.005
        }
    }

    func applyPaper(_ paper: PaperSize) {
        selection = rect(for: paper)
        selectedPageID = nil
    }

    // MARK: Saving

    func save() {
        guard !pages.isEmpty, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Scan \(stamp.string(from: Date())).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format = format
        let items = pages.map { (image: $0.image, dpi: $0.dpi) }
        busy = true
        statusText = "Saving…"
        Task.detached(priority: .userInitiated) {
            var failure: Error?
            var written = [URL]()
            do {
                if format == .pdf {
                    try Imaging.writePDF(items, to: url)
                    written = [url]
                } else if items.count == 1 {
                    try Imaging.writeImage(items[0].image, dpi: items[0].dpi, format: format, to: url)
                    written = [url]
                } else {
                    // One numbered file per page: "Scan 1.png", "Scan 2.png", …
                    let base = url.deletingPathExtension()
                    for (n, item) in items.enumerated() {
                        let pageURL = URL(fileURLWithPath: "\(base.path) \(n + 1).\(format.fileExtension)")
                        try Imaging.writeImage(item.image, dpi: item.dpi, format: format, to: pageURL)
                        written.append(pageURL)
                    }
                }
            } catch {
                failure = error
            }
            let urls = written
            let err = failure
            await MainActor.run {
                self.finish(error: err)
                if err == nil { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
        }
    }
}
