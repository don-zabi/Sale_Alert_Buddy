import Testing
import UIKit
@testable import Sale_Alert_Buddy

@Suite("PreviewImageValidator")
struct PreviewImageValidatorTests {

    @Test("solid white screenshot is treated as blank")
    func solidWhiteIsBlank() {
        let image = solidImage(color: .white)
        #expect(PreviewImageValidator.isLikelyBlank(image))
    }

    @Test("solid gray screenshot is treated as blank")
    func solidGrayIsBlank() {
        let image = solidImage(color: UIColor(white: 0.84, alpha: 1))
        #expect(PreviewImageValidator.isLikelyBlank(image))
    }

    @Test("page-like screenshot with content is not treated as blank")
    func pageLikeImageIsNotBlank() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { context in
            let cgContext = context.cgContext
            let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
            UIColor.white.setFill()
            cgContext.fill(bounds)

            UIColor(white: 0.96, alpha: 1).setFill()
            cgContext.fill(CGRect(x: 24, y: 40, width: 342, height: 220))

            UIColor(white: 0.15, alpha: 1).setFill()
            cgContext.fill(CGRect(x: 24, y: 288, width: 220, height: 18))
            cgContext.fill(CGRect(x: 24, y: 320, width: 180, height: 14))

            UIColor.systemBlue.setFill()
            cgContext.fill(CGRect(x: 254, y: 288, width: 112, height: 112))

            UIColor(red: 1, green: 0.95, blue: 0.46, alpha: 1).setFill()
            cgContext.fill(CGRect(x: 24, y: 410, width: 160, height: 40))

            UIColor.orange.setStroke()
            cgContext.setLineWidth(4)
            cgContext.stroke(CGRect(x: 24, y: 410, width: 160, height: 40))
        }

        #expect(!PreviewImageValidator.isLikelyBlank(image))
    }

    private func solidImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { context in
            let cgContext = context.cgContext
            color.setFill()
            cgContext.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
        }
    }
}
