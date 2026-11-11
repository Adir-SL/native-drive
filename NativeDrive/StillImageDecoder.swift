import CoreGraphics
import Foundation
import ImageIO

/// A decoded still, including HEIC, with EXIF orientation already applied.
/// The CGImage keeps the source color space, so wide-gamut photos stay wide-gamut.
struct DecodedStill: @unchecked Sendable {
    let image: CGImage
}

enum StillImageDecoder {
    nonisolated static func decode(url: URL, maxPixel: CGFloat = 16_384) -> DecodedStill? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let image = orientedThumbnail(from: source, maxPixel: maxPixel) ?? CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return DecodedStill(image: image)
        }
        return nil
    }

    private nonisolated static func orientedThumbnail(from source: CGImageSource, maxPixel requested: CGFloat) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longest = max(width, height, 1.0)
        let cap = max(requested, 1)
        let maxPixel = min(longest, cap)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        var allowingFloat = options
        allowingFloat[kCGImageSourceShouldAllowFloat] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, allowingFloat as CFDictionary)
    }
}
