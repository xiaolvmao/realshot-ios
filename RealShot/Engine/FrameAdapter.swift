import CoreImage
import CoreGraphics
import Foundation

/// 把任意比例的图裁成“相机画幅”，并可选地去掉状态栏/底部条。
enum FrameAdapter {

    /// - Parameters:
    ///   - anchor: 垂直构图位置，0 = 偏上，1 = 偏下（裁上下时用）
    ///   - cropX: 水平构图位置，0 = 偏左，1 = 偏右（裁左右、缩放时用）
    ///   - cropScale: 向内放大的倍数，1.0 = 不裁，2.0 = 只保留中间四分之一
    static func apply(_ image: CIImage,
                      frame: FrameMode,
                      trimBars: Bool,
                      anchor: Double,
                      cropX: Double = 0.5,
                      cropScale: Double = 1.0) -> CIImage {
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

        let cx = CGFloat(min(max(cropX, 0), 1))
        let cy = CGFloat(min(max(anchor, 0), 1))

        if let ratio = frame.longShortRatio {
            let e = img.extent
            if e.width > 8, e.height > 8 {
                let isPortrait = e.height >= e.width
                // 目标宽高比
                let targetWH = isPortrait ? CGFloat(1.0 / ratio) : CGFloat(ratio)

                if e.width / e.height > targetWH {
                    // 太宽，裁左右：水平位置决定留哪边
                    let w = (e.height * targetWH).rounded()
                    let available = e.width - w
                    let x = e.minX + (available * cx).rounded()
                    img = img.cropped(to: CGRect(x: x, y: e.minY, width: w, height: e.height))
                } else {
                    // 太高，裁上下：垂直位置决定留哪边
                    let h = (e.width / targetWH).rounded()
                    let available = e.height - h
                    let y = e.minY + (available * cy).rounded()
                    img = img.cropped(to: CGRect(x: e.minX, y: y, width: e.width, height: h))
                }
            }
        }

        // 再向内放大一把，构图更紧。1.0 时整段跳过。
        let zoom = CGFloat(min(max(cropScale, 1.0), 2.0))
        if zoom > 1.001 {
            let e = img.extent
            if e.width > 16, e.height > 16 {
                let w = (e.width / zoom).rounded()
                let h = (e.height / zoom).rounded()
                let x = e.minX + ((e.width - w) * cx).rounded()
                let y = e.minY + ((e.height - h) * cy).rounded()
                img = img.cropped(to: CGRect(x: x, y: y, width: w, height: h))
            }
        }

        return img
    }
}
