import UIKit
import ImageIO

enum ImageLoader {

    /// 从文件数据解码，顺便处理 EXIF 方向和超大图。
    static func image(from data: Data, maxPixel: CGFloat = 4200) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]

        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        if let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return UIImage(cgImage: cg)
        }
        return nil
    }

    static func image(from url: URL, maxPixel: CGFloat = 4200) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return image(from: data, maxPixel: maxPixel)
    }
}

extension UIImage {

    var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// 把 EXIF 方向“烧”进像素里，后面 Core Image 就不用再管方向了。
    func normalizedForProcessing() -> UIImage {
        guard imageOrientation != .up || scale != 1 else { return self }
        let px = pixelSize
        guard px.width > 1, px.height > 1 else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: px, format: format)
        let result = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: px))
        }
        return result
    }
}
