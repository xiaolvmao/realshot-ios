import CoreGraphics
import Foundation
import ImageIO

/// JPEG 损坏器。
///
/// 截图和网络图往往是 PNG / 无损 WebP / 高质量 JPEG，边缘干净得像矢量图。
/// 真实照片一定经历过一次有损压缩：8×8 块、振铃、色度下采样。
/// 这里做的是真正的「编码 → 解码」往返，不是加一层噪点假装修。
enum JpegDegrader {

    static func degrade(_ image: CGImage, quality: Double, passes: Int) -> CGImage {
        var current = image
        let q = max(0.35, min(0.98, quality))
        for _ in 0..<max(0, min(3, passes)) {
            guard let data = encode(current, quality: q),
                  let decoded = decode(data) else { return current }
            current = decoded
        }
        return current
    }

    static func encode(_ image: CGImage, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData,
                                                          "public.jpeg" as CFString,
                                                          1,
                                                          nil) else { return nil }
        let props = [kCGImageDestinationLossyCompressionQuality: max(0.2, min(0.99, quality))] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
