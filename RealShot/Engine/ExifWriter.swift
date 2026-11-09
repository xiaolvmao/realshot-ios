import CoreGraphics
import Foundation
import ImageIO

struct CameraMetadata {
    var make: String
    var model: String
    var lens: String
    var iso: Int
    var fNumber: Double
    var exposureTime: Double
    var focalLength: Double
    var focal35: Int
    var date: Date

    static func make(for preset: CameraPreset, date: Date = Date()) -> CameraMetadata {
        let d = preset.device
        return CameraMetadata(make: d.make,
                              model: d.model,
                              lens: d.lens,
                              iso: d.iso,
                              fNumber: d.fNumber,
                              exposureTime: d.exposure,
                              focalLength: d.focalLength,
                              focal35: d.focal35,
                              date: date)
    }
}

/// 写出一张带“拍摄参数”的 JPEG。
/// 注意：这些参数是模拟出来的，只为了让成片在系统相册/Exif 工具里
/// 和它的视觉风格保持一致，不是用来伪造证据的。
enum ExifWriter {

    static func write(_ image: CGImage, metadata: CameraMetadata, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData,
                                                          "public.jpeg" as CFString,
                                                          1,
                                                          nil) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        let stamp = formatter.string(from: metadata.date)

        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp,
            kCGImagePropertyExifFNumber: metadata.fNumber,
            kCGImagePropertyExifExposureTime: metadata.exposureTime,
            kCGImagePropertyExifISOSpeedRatings: [metadata.iso],
            kCGImagePropertyExifFocalLength: metadata.focalLength,
            kCGImagePropertyExifFocalLenIn35mmFilm: metadata.focal35,
            kCGImagePropertyExifLensModel: metadata.lens,
            kCGImagePropertyExifColorSpace: 1,
            kCGImagePropertyExifPixelXDimension: image.width,
            kCGImagePropertyExifPixelYDimension: image.height
        ]

        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: metadata.make,
            kCGImagePropertyTIFFModel: metadata.model,
            kCGImagePropertyTIFFDateTime: stamp
        ]

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.2, min(0.99, quality)),
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff
        ]

        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
