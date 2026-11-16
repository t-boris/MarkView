import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// End-to-End QA (feature end-to-end-qa): the one file the runner can give a page that asks for a file. A person running a test picks a file in
// the system panel; a player sits in a window nobody sees, so it has no panel and no file of its own. When the page opens its file chooser
// (a click on an `input[type=file]`, or on the label or button that opens it), the web player answers the chooser itself with this picture
// (`QAWebActor`). The picture is drawn here, so it is built in: nothing to install, no path to configure, the same pixels in every run.
// System frameworks only, so the prompt in `QAActions` can name it.

enum QATestImage {
    /// The name the page sees in `File.name` and in the field's value.
    static let fileName = "markview-test-image.png"
    static let width = 320
    static let height = 240

    /// A PNG of `width` x `height` pixels: a blue field with a lighter band, a white disc and a dark square, so a page that previews,
    /// crops or checks the picture has real content and not a blank. Nil only if the system image encoder refuses.
    static func pngData() -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.18, green: 0.42, blue: 0.87, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.36, green: 0.58, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2 - 30, width: width, height: 60))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 40, y: 60, width: 120, height: 120))
        context.setFillColor(CGColor(red: 0.07, green: 0.12, blue: 0.27, alpha: 1))
        context.fill(CGRect(x: 190, y: 70, width: 90, height: 90))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
