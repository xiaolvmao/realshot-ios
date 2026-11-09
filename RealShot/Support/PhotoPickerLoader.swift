import SwiftUI
import PhotosUI
import UIKit

/// 把相册选择器选中的项统一读成「原始数据 + 一张小缩略图」。
///
/// 批量页和全屏查看器都能往队列里加图，读取方式必须一致：
/// 缩略图尺寸、解码上限只要有一处不同，同一张图在两个地方就会显示成不同大小。
enum PhotoPickerLoader {

    struct Payload {
        let data: Data
        let thumb: UIImage
    }

    /// 按顺序读，读不出来的跳过并在 skipped 里计数。
    static func load(_ selection: [PhotosPickerItem],
                     limit: Int) async -> (payloads: [Payload], skipped: Int) {
        var payloads: [Payload] = []
        var skipped = 0

        for item in selection.prefix(limit) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let thumb = ImageLoader.image(from: data, maxPixel: ImageLoader.thumbnailPixel) else {
                skipped += 1
                continue
            }
            payloads.append(Payload(data: data, thumb: thumb))
        }
        return (payloads, skipped)
    }
}
