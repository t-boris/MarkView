import Foundation

/// The images next to an open image, for stepping through a folder in the image viewer.
enum ImageSiblings {
    /// The folder's images in Finder order (1, 2, 10), hidden files left out.
    static func list(in directory: URL, isImage: (URL) -> Bool) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter(isImage).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// The image `step` places after `url` (negative: before). Past either end it stops (nil), or
    /// with `wrap` continues from the other end. Nil too when there is no other image.
    static func neighbour(of url: URL, in list: [URL], step: Int, wrap: Bool) -> URL? {
        guard list.count > 1, let index = list.firstIndex(where: { $0.lastPathComponent == url.lastPathComponent }) else { return nil }
        let target = index + step
        if list.indices.contains(target) { return list[target] }
        guard wrap else { return nil }
        return list[((target % list.count) + list.count) % list.count]
    }

    /// "3 / 12" for the header, nil when the image is alone.
    static func position(of url: URL, in list: [URL]) -> String? {
        guard list.count > 1, let index = list.firstIndex(where: { $0.lastPathComponent == url.lastPathComponent }) else { return nil }
        return "\(index + 1) / \(list.count)"
    }
}
