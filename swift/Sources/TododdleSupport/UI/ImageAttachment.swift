import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image helpers for screenshots, built on ImageIO so they work the same on iOS and macOS.
public enum ScreenshotAttachment {
    /// Makes an attachment from image data, for example a screenshot your app captured or a photo.
    ///
    /// PNG, JPEG, GIF and WebP are kept when the config allows them and they fit. Anything else
    /// (for example HEIC) or anything too large is converted to JPEG, scaled down if needed.
    /// Returns `nil` when the data is not an image or cannot fit within `maxBytes`.
    public static func make(
        from data: Data,
        fileName: String = "screenshot",
        allowedContentTypes: [String] = ["image/png", "image/jpeg"],
        maxBytes: Int = 10_485_760
    ) -> ReportAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        if let typeIdentifier = CGImageSourceGetType(source) as String?,
           let type = UTType(typeIdentifier),
           let mime = type.preferredMIMEType,
           allowedContentTypes.contains(mime),
           data.count <= maxBytes {
            let ext = type.preferredFilenameExtension ?? "img"
            return ReportAttachment(fileName: "\(fileName).\(ext)", contentType: mime, data: data)
        }

        let target: UTType = allowedContentTypes.contains("image/jpeg") ? .jpeg : .png
        guard allowedContentTypes.contains(target.preferredMIMEType ?? "") else { return nil }
        for maxPixels in [4096, 2560, 1600, 1024] {
            guard let image = thumbnail(source, maxPixelSize: maxPixels),
                  let encoded = encode(image, as: target) else { continue }
            if encoded.count <= maxBytes {
                return ReportAttachment(
                    fileName: "\(fileName).\(target.preferredFilenameExtension ?? "jpg")",
                    contentType: target.preferredMIMEType ?? "image/jpeg",
                    data: encoded
                )
            }
        }
        return nil
    }

    /// A small image for the preview, or `nil` when the data is not an image.
    static func previewImage(_ data: Data, maxPixelSize: Int = 800) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
