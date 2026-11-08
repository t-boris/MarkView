import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The images of a request box, as Prototype Studio and UI Studio show them (REQ-005): a row of thumbnails, each with a
/// button that removes it, and the line saying which images were not added and why.
struct ImageAttachmentStrip: View {
    @Environment(\.palette) private var palette
    @Binding var attachments: ImageAttachmentList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments.items) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: attachment.image).resizable().scaledToFill().frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Button { attachments.remove(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.white).shadow(radius: 1)
                                }
                                .buttonStyle(.plain).padding(2)
                                .help("Remove this image")
                                .accessibilityLabel("Remove this image")
                            }
                        }
                    }
                }
            }
            if let notice = attachments.notice {
                Text(notice).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The paperclip beside a request box: choose image files, or take the image on the clipboard.
struct ImageAttachmentMenu: View {
    @Environment(\.palette) private var palette
    @Binding var attachments: ImageAttachmentList

    var body: some View {
        Menu {
            Button("Choose image…") { chooseImages() }
            Button("Paste image from clipboard") { attachments.addFromPasteboard() }
        } label: {
            Image(systemName: "paperclip").uiFont(size: 13).foregroundColor(palette.textDim)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Send an image with your request: paste it (⌘V), drop it here, or choose a file")
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        attachments.add(panel.urls.compactMap { ImageAttachments.image(at: $0) })
    }
}

extension View {
    /// Makes a request box take images: an image on the clipboard or a dropped image file or picture becomes an
    /// attachment, and a paste of text is inserted at the caret (the box takes the paste command itself, so that
    /// the editor's own text paste does not run).
    func takesImageAttachments(_ attachments: Binding<ImageAttachmentList>, text: Binding<String>) -> some View {
        self
            .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { _ in
                if !attachments.wrappedValue.addFromPasteboard() { ImageAttachments.pasteText { text.wrappedValue += $0 } }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                ImageAttachments.load(from: providers) { png in
                    Task { @MainActor in attachments.wrappedValue.add([png]) }
                }
            }
    }
}
