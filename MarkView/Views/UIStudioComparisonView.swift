import SwiftUI
import AppKit

/// The comparison of two captures at the size of the whole UI Studio tab (BUG-094): the Evidence panel is too narrow
/// to see a change in a page. Four views of the same pair (side by side, the pixel difference, and each capture alone,
/// so that flipping between "Before" and "After" shows what moved) and a zoom from "fit to the room" to 400 %.
struct StudioComparisonView: View {
    /// Where a capture's picture is stored.
    let url: (StudioCapture) -> URL
    let comparison: StudioSession.Comparison
    var close: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by side", difference = "Difference", before = "Before", after = "After"
        var id: String { rawValue }
    }

    @State private var mode: Mode
    /// nil fits the picture(s) into the room; otherwise a fraction of the capture's own pixels.
    @State private var zoom: Double?

    init(url: @escaping (StudioCapture) -> URL, comparison: StudioSession.Comparison, close: @escaping () -> Void,
         mode: Mode = .sideBySide, zoom: Double? = nil) {
        self.url = url
        self.comparison = comparison
        self.close = close
        _mode = State(initialValue: mode)
        _zoom = State(initialValue: zoom)
    }

    private static let steps: [Double] = [0.25, 0.5, 1, 2, 4]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(VSDark.border)
            if !comparison.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(comparison.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.triangle").uiFont(size: 11).foregroundColor(VSDark.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6).background(VSDark.bgBanner)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VSDark.bg)
        .overlay(
            // Esc closes the view, wherever the focus is.
            Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Comparison").uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text)
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if let ratio = comparison.changedRatio {
                Text(String(format: "%.2f %% of the pixels changed", ratio * 100)).uiFont(size: 11).foregroundColor(VSDark.textDim)
            }
            Spacer()
            zoomControls
            Button(action: close) { Label("Close", systemImage: "xmark") }
                .controlSize(.small).help("Close the large comparison (Esc); the Evidence panel keeps it")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(VSDark.bgSidebar)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "minus") }
                .help("Zoom out").disabled(zoom != nil && zoom! <= Self.steps.first!)
            Text(zoom.map { "\(Int(($0 * 100).rounded())) %" } ?? "Fit")
                .uiFont(size: 11).foregroundColor(VSDark.textDim).frame(minWidth: 38)
            Button { step(1) } label: { Image(systemName: "plus") }
                .help("Zoom in").disabled(zoom != nil && zoom! >= Self.steps.last!)
            if zoom != nil { Button("Fit") { zoom = nil }.help("Fit the pictures into the room") }
            if zoom != 1 { Button("100 %") { zoom = 1 }.help("One pixel of the capture per pixel on the screen") }
        }
        .controlSize(.small)
    }

    /// From "fit" the first zoom-in is 100 % and the first zoom-out 50 %.
    private func step(_ direction: Int) {
        guard let current = zoom else { zoom = direction > 0 ? 1 : 0.5; return }
        let index = Self.steps.firstIndex(where: { $0 >= current }) ?? Self.steps.count - 1
        zoom = Self.steps[min(max(index + direction, 0), Self.steps.count - 1)]
    }

    // MARK: Pictures

    @ViewBuilder private var content: some View {
        if let zoom {
            ScrollView([.horizontal, .vertical]) { pictures(zoom: zoom).padding(12) }
        } else {
            pictures(zoom: nil).padding(12)
        }
    }

    @ViewBuilder private func pictures(zoom: Double?) -> some View {
        switch mode {
        case .sideBySide:
            HStack(alignment: .top, spacing: 12) {
                picture(title: "Before · " + comparison.before.label, url: url(comparison.before), zoom: zoom)
                picture(title: "After · " + comparison.after.label, url: url(comparison.after), zoom: zoom)
            }
        case .difference:
            if let diff = comparison.diffFile {
                picture(title: "Difference", url: diff, zoom: zoom)
            } else {
                Text("These captures have different sizes, so there is no pixel difference.").uiFont(size: 12).foregroundColor(VSDark.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .before:
            picture(title: "Before · " + comparison.before.label, url: url(comparison.before), zoom: zoom)
        case .after:
            picture(title: "After · " + comparison.after.label, url: url(comparison.after), zoom: zoom)
        }
    }

    private func picture(title: String, url: URL, zoom: Double?) -> some View {
        VStack(spacing: 4) {
            Text(title).uiFont(size: 11).foregroundColor(VSDark.textDim).lineLimit(1)
            StudioZoomImage(url: url, zoom: zoom)
        }
    }
}

/// A capture at "fit to the room" or at a fraction of its pixel size, read off the main thread.
private struct StudioZoomImage: View {
    let url: URL
    let zoom: Double?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                if let zoom {
                    Image(nsImage: image).resizable().interpolation(zoom >= 2 ? .none : .high)
                        .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                } else {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
            } else {
                Rectangle().fill(VSDark.bg).overlay(ProgressView().controlSize(.small)).frame(minWidth: 120, minHeight: 80)
            }
        }
        .overlay(Rectangle().stroke(VSDark.border, lineWidth: 1))
        .task(id: url) {
            let file = url
            let loaded = await Task.detached { StudioImageDiff.load(file) }.value
            image = loaded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }
}
