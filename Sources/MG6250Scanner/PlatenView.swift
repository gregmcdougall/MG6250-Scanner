import SwiftUI

/// The scanner glass: shows the preview scan and lets you drag out the area
/// to scan. Drag a corner to resize, inside the box to move it, or anywhere
/// else to draw a new box.
struct PlatenView: View {
    @EnvironmentObject private var model: ScannerModel
    @State private var drag: DragMode?

    private enum DragMode {
        case move(original: CGRect)
        case draw(anchor: CGPoint)   // anchor in inches
    }

    private let handle: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let platen = ScannerModel.platen
            let scale = max(0.001, min(geo.size.width / platen.width, geo.size.height / platen.height))
            let size = CGSize(width: platen.width * scale, height: platen.height * scale)
            let sel = CGRect(x: model.selection.minX * scale, y: model.selection.minY * scale,
                             width: model.selection.width * scale, height: model.selection.height * scale)

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.16))
                if let preview = model.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: size.width, height: size.height)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "scanner").font(.system(size: 44, weight: .light))
                        Text("Press Preview to see what is on the glass")
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: size.width, height: size.height)
                }

                // Dim everything outside the selection.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(sel)
                }
                .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))

                Path { $0.addRect(sel) }
                    .stroke(Color.white, lineWidth: 1)
                Path { $0.addRect(sel) }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

                ForEach(0..<4, id: \.self) { i in
                    let corner = CGPoint(x: i % 2 == 0 ? sel.minX : sel.maxX, y: i < 2 ? sel.minY : sel.maxY)
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                        .frame(width: handle, height: handle)
                        .offset(x: corner.x - handle / 2, y: corner.y - handle / 2)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .shadow(radius: 6, y: 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                        let now = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                        if drag == nil { drag = beginDrag(at: start, grab: Double(handle + 4) / scale) }
                        switch drag {
                        case .move(let original):
                            var r = original.offsetBy(dx: now.x - start.x, dy: now.y - start.y)
                            r.origin.x = min(max(0, r.origin.x), platen.width - r.width)
                            r.origin.y = min(max(0, r.origin.y), platen.height - r.height)
                            model.selection = r
                        case .draw(let anchor):
                            let p = CGPoint(x: min(max(0, now.x), platen.width), y: min(max(0, now.y), platen.height))
                            model.selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                                     width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
                        case nil: break
                        }
                    }
                    .onEnded { _ in
                        drag = nil
                        // A stray click or sliver selects the whole glass again.
                        if model.selection.width < 0.25 || model.selection.height < 0.25 {
                            model.selection = platen
                        }
                    }
            )
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private func beginDrag(at p: CGPoint, grab: Double) -> DragMode {
        let s = model.selection
        let corners = [CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.maxX, y: s.minY),
                       CGPoint(x: s.minX, y: s.maxY), CGPoint(x: s.maxX, y: s.maxY)]
        for (i, c) in corners.enumerated() where abs(c.x - p.x) <= grab && abs(c.y - p.y) <= grab {
            return .draw(anchor: corners[3 - i])   // resize against the opposite corner
        }
        if s.contains(p) && s != ScannerModel.platen { return .move(original: s) }
        let platen = ScannerModel.platen
        return .draw(anchor: CGPoint(x: min(max(0, p.x), platen.width), y: min(max(0, p.y), platen.height)))
    }
}
