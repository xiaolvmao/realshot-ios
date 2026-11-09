import CoreImage
import CoreGraphics
import Foundation

/// 把任意比例的图裁成“相机画幅”，并可选地去掉状态栏/底部条。
enum FrameAdapter {

    static func apply(_ image: CIImage, frame: FrameMode, trimBars: Bool, anchor: Double) -> CIImage {
        var img = image

        if trimBars {
            let e = img.extent
            // 状态栏约占 5.8%，底部 home indicator 区约占 2.8%
            let top = e.height * 0.058
            let bottom = e.height * 0.028
            if e.height - top - bottom > 32 {
                let rect = CGRect(x: e.minX,
                                  y: e.minY + bottom,
                                  width: e.width,
                                  height: e.height - top - bottom)
                img = img.cropped(to: rect)
            }
        }

        guard let ratio = frame.longShortRatio else { return img }

        let e = img.extent
        guard e.width > 8, e.height > 8 else { return img }

        let isPortrait = e.height >= e.width
        // 目标宽高比
        let targetWH = isPortrait ? CGFloat(1.0 / ratio) : CGFloat(ratio)

        if e.width / e.height > targetWH {
            // 太宽，裁左右
            let w = (e.height * targetWH).rounded()
            let rect = CGRect(x: (e.midX - w / 2).rounded(), y: e.minY, width: w, height: e.height)
            return img.cropped(to: rect)
        } else {
            // 太高，裁上下
            let h = (e.width / targetWH).rounded()
            let available = e.height - h
            let clamped = min(max(anchor, 0), 1)
            let y = e.minY + (available * CGFloat(clamped)).rounded()
            let rect = CGRect(x: e.minX, y: y, width: e.width, height: h)
            return img.cropped(to: rect)
        }
    }
}
