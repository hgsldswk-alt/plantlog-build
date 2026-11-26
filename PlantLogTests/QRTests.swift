import CoreImage
import XCTest

final class QRTests: XCTestCase {
    func testPlaceholderAndOfflineRoundTrip() throws {
        XCTAssertNil(CardQR.url(storeID: ""))
        XCTAssertNil(CardQR.url(storeID: "__APP_STORE_ID__"))
        let expected = ["https://example.com/plant-care", "https://apps.apple.com/app/id1234567890"]
        let urls = [CardQR.url(storeID: nil, example: true), CardQR.url(storeID: "1234567890")]
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for (candidate, value) in zip(urls, expected) {
            let url = try XCTUnwrap(candidate)
            let image = try XCTUnwrap(CardQR.image(url))
            let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(found.first, value)
        }
    }
}
