import CoreGraphics
import UIKit

enum PreviewImageValidator {

    private static let sampleWidth = 24
    private static let sampleHeight = 24
    private static let bytesPerPixel = 4

    static func isLikelyBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        guard let metrics = sampleMetrics(for: cgImage) else { return false }
        return metrics.isLikelyBlank
    }

    private static func sampleMetrics(for cgImage: CGImage) -> Metrics? {
        let bytesPerRow = sampleWidth * bytesPerPixel
        var rawBytes = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        guard let context = CGContext(
            data: &rawBytes,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        let pixelCount = sampleWidth * sampleHeight
        var luminances = [Double]()
        luminances.reserveCapacity(pixelCount)
        var alphaTotal = 0.0
        var saturationTotal = 0.0
        var vividPixelCount = 0
        var colorBuckets = Set<Int>()
        colorBuckets.reserveCapacity(8)

        for offset in stride(from: 0, to: rawBytes.count, by: bytesPerPixel) {
            let red = Double(rawBytes[offset]) / 255
            let green = Double(rawBytes[offset + 1]) / 255
            let blue = Double(rawBytes[offset + 2]) / 255
            let alpha = Double(rawBytes[offset + 3]) / 255

            let luminance = ((0.2126 * red) + (0.7152 * green) + (0.0722 * blue)) * alpha + (1 - alpha)
            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel

            luminances.append(luminance)
            alphaTotal += alpha
            saturationTotal += saturation
            if saturation > 0.08 { vividPixelCount += 1 }

            let redBucket = min(Int(red * 7.99), 7)
            let greenBucket = min(Int(green * 7.99), 7)
            let blueBucket = min(Int(blue * 7.99), 7)
            let bucket = (redBucket << 6) | (greenBucket << 3) | blueBucket
            colorBuckets.insert(bucket)
        }

        let averageLuminance = luminances.reduce(0, +) / Double(pixelCount)
        let averageAlpha = alphaTotal / Double(pixelCount)
        let averageSaturation = saturationTotal / Double(pixelCount)
        let vividPixelRatio = Double(vividPixelCount) / Double(pixelCount)

        var maxLuminanceDelta = 0.0
        var totalLuminanceDelta = 0.0
        var contrastPixelCount = 0

        for luminance in luminances {
            let delta = abs(luminance - averageLuminance)
            totalLuminanceDelta += delta
            maxLuminanceDelta = max(maxLuminanceDelta, delta)
            if delta > 0.08 { contrastPixelCount += 1 }
        }

        return Metrics(
            averageAlpha: averageAlpha,
            averageSaturation: averageSaturation,
            averageLuminanceDelta: totalLuminanceDelta / Double(pixelCount),
            maxLuminanceDelta: maxLuminanceDelta,
            distinctColorBucketCount: colorBuckets.count,
            contrastPixelRatio: Double(contrastPixelCount) / Double(pixelCount),
            vividPixelRatio: vividPixelRatio
        )
    }
}

private extension PreviewImageValidator {
    struct Metrics {
        let averageAlpha: Double
        let averageSaturation: Double
        let averageLuminanceDelta: Double
        let maxLuminanceDelta: Double
        let distinctColorBucketCount: Int
        let contrastPixelRatio: Double
        let vividPixelRatio: Double

        var isLikelyBlank: Bool {
            guard averageAlpha > 0.96 else { return false }

            let isSolidPlaceholder =
                maxLuminanceDelta < 0.018 &&
                distinctColorBucketCount <= 2

            let isLowInformationPlaceholder =
                averageLuminanceDelta < 0.012 &&
                contrastPixelRatio < 0.015 &&
                vividPixelRatio < 0.02 &&
                averageSaturation < 0.05 &&
                distinctColorBucketCount <= 4

            return isSolidPlaceholder || isLowInformationPlaceholder
        }
    }
}
