import AppKit
import SwiftUI
import ImageIO

/// Text keeps normal paste/undo/selection behavior; copied images become attachments.
struct IntakeTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var attach: ([URL]) -> Void
    var failed: (String) -> Void
    @Environment(\.appFontScale) private var fontScale

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = AttachmentTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 13 * fontScale)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 5, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        view.onAttachments = { context.coordinator.parent.attach($0) }
        view.onFailure = { context.coordinator.parent.failed($0) }
        view.onFocus = { context.coordinator.parent.focused = $0 }
        scroll.documentView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        let fontSize = 13 * fontScale
        if view.font?.pointSize != fontSize { view.font = .systemFont(ofSize: fontSize) }
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IntakeTextEditor
        init(_ parent: IntakeTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class AttachmentTextView: NSTextView {
    var onAttachments: (([URL]) -> Void)?
    var onFailure: ((String) -> Void)?
    var onFocus: ((Bool) -> Void)?
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus?(false) }
        return accepted
    }
    override func paste(_ sender: Any?) {
        do {
            if let urls = try IntakeClipboard.attachments(from: .general) { onAttachments?(urls); return }
            super.paste(sender)
        } catch { onFailure?("Could not paste the image: " + error.localizedDescription) }
    }
}

enum IntakeClipboard {
    /// A nil result leaves text/HTML paste to NSTextView. PNGs use unique cache files,
    /// never research documents; each workflow copies its submitted attachments itself.
    static func attachments(from pasteboard: NSPasteboard, folder: URL? = nil) throws -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let cache = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MarkView/pasted-images", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let file = cache.appendingPathComponent("pasted-image-" + UUID().uuidString + ".png")
            try png.write(to: file, options: .withoutOverwriting)
            return [file]
        }
        return nil
    }
}

struct IntakeAttachmentThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "paperclip").foregroundColor(.secondary) }
        }
        .frame(width: 32, height: 24)
        .task(id: url) {
            let data = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 64
                      ] as CFDictionary) else { return Optional<Data>.none }
                return NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
            }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}
