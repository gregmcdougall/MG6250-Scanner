import PixmaKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ScannerModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 270)
            Divider()
            VStack(spacing: 0) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let page = model.selectedPage {
                        PageView(page: page)
                    } else {
                        PlatenView().padding(20)
                    }
                }
                if !model.pages.isEmpty {
                    Divider()
                    PageStrip()
                }
            }
        }
        .onAppear { model.findScanners() }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: ScannerModel
    private static let customArea = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Scanner") {
                HStack {
                    TextField("Address, e.g. 192.168.1.249", text: $model.host)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.findScanners()
                    } label: {
                        if model.searching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .help("Find scanners on the network")
                    .disabled(model.searching)
                }
                if model.scanners.isEmpty {
                    Text(model.searching ? "Searching the network…" : "No scanner found automatically. Type its address above.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.scanners) { scanner in
                        Button {
                            model.host = scanner.host
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: model.host == scanner.host ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.host == scanner.host ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(scanner.model)
                                    Text(scanner.host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        if !scanner.isSupportedModel {
                            Text("Untested model — this driver was written for the MG6200 series.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }

            section("Settings") {
                Picker("Colour", selection: $model.mode) {
                    Text("Colour").tag(ColorMode.color)
                    Text("Grey").tag(ColorMode.gray)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Resolution", selection: $model.dpi) {
                    ForEach(PixmaScanner.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }

                Picker("Area", selection: Binding(
                    get: { model.currentPaper?.id ?? Self.customArea },
                    set: { id in
                        if let paper = PaperSize.all.first(where: { $0.id == id }) { model.applyPaper(paper) }
                    })) {
                    ForEach(PaperSize.all) { Text($0.name).tag($0.id) }
                    // Shown only while the area has been drawn by hand.
                    if model.currentPaper == nil {
                        Divider()
                        Text("Custom").tag(Self.customArea)
                    }
                }
                Text(model.selectionSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Scan") {
                HStack {
                    Button("Preview") { model.scanPreview() }
                        .keyboardShortcut("p")
                    Button("Scan") { model.scan() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .disabled(model.busy)

                if model.busy {
                    VStack(alignment: .leading, spacing: 6) {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        HStack {
                            Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { model.cancel() }.controlSize(.small)
                        }
                    }
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            section(model.pages.isEmpty ? "Save" : "Save \(model.pages.count) page\(model.pages.count == 1 ? "" : "s")") {
                HStack {
                    Picker("Format", selection: $model.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    Button("Save…") { model.save() }
                        .keyboardShortcut("s")
                        .disabled(model.pages.isEmpty || model.busy)
                }
                if model.pages.count > 1 && model.format != .pdf {
                    Text("Each page is saved as its own numbered file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

// MARK: - Scanned pages

private struct PageView: View {
    @EnvironmentObject private var model: ScannerModel
    let page: Page

    var body: some View {
        VStack(spacing: 0) {
            Image(decorative: page.display, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .shadow(radius: 6, y: 2)
                .padding(20)
            HStack(spacing: 12) {
                Button { model.rotateSelected(clockwise: false) } label: { Label("Rotate left", systemImage: "rotate.left") }
                Button { model.rotateSelected(clockwise: true) } label: { Label("Rotate right", systemImage: "rotate.right") }
                Button(role: .destructive) { model.deleteSelected() } label: { Label("Delete page", systemImage: "trash") }
                Spacer()
                Text("\(page.image.width) × \(page.image.height) px  ·  \(page.dpi) dpi")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .disabled(model.busy)
        }
    }
}

private struct PageStrip: View {
    @EnvironmentObject private var model: ScannerModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                thumbnail(selected: model.selectedPageID == nil, caption: "Glass") {
                    Image(systemName: "scanner").font(.title2).foregroundStyle(.secondary)
                        .frame(width: 52, height: 72)
                } action: {
                    model.selectedPageID = nil
                }
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    thumbnail(selected: model.selectedPageID == page.id, caption: "Page \(index + 1)") {
                        Image(decorative: page.display, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 72)
                    } action: {
                        model.selectedPageID = page.id
                    }
                }
            }
            .padding(10)
        }
        .frame(height: 122)
        .background(.bar)
    }

    private func thumbnail<Content: View>(selected: Bool, caption: String, @ViewBuilder content: () -> Content,
                                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content()
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(caption).font(.caption2).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
