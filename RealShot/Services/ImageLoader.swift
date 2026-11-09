import UIKit
import ImageIO

enum ImageLoader {

    /// 处理时的长边上限。
    ///
    /// 单张和批量必须用同一个值：之前批量固定写成 3200、单张是 4200，
    /// 同一张图走两条路径出来的尺寸不一样，「原始」这个选项也因此名不副实。
    /// 4200 覆盖了 12MP 手机照片（4032），再往上单张解码就要 200MB 以上。
    static let workingPixel: CGFloat = 4200
    /// 网格缩略图用的小尺寸。
    static let thumbnailPixel: CGFloat = 640

    /// 从文件数据解码，顺便处理 EXIF 方向和超大图。
    static func image(from data: Data, maxPixel: CGFloat = ImageLoader.workingPixel) -> UIImage? {
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

    static func image(from url: URL, maxPixel: CGFloat = ImageLoader.workingPixel) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return image(from: data, maxPixel: maxPixel)
    }

    /// 只读文件头拿尺寸，不解码整张图 —— 用来判断「原始」输出到底有多大。
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = props[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return CGSize(width: CGFloat(truncating: w), height: CGFloat(truncating: h))
    }

    /// 原始拍摄时间。写 EXIF 时沿用它，处理去年的截图才不会显示成今天拍的。
    static func captureDate(of data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: raw)
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
