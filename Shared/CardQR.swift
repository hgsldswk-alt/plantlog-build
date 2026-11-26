import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum CardQR {
    static func url(storeID: String?, example: Bool = false) -> URL? {
        if example { return URL(string: "https://example.com/plant-care") }
        guard let id = storeID, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)")
    }

    static func image(_ url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        let scale: CGFloat = 8
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let bounds = output.extent.insetBy(dx: -4 * scale, dy: -4 * scale)
        let padded = output.composited(over: CIImage(color: .white).cropped(to: bounds))
        return CIContext().createCGImage(padded, from: bounds)
    }
}
