import SwiftUI
import CoreImage
import UIKit

/// 批量队列里的一项。
/// 只保留原始文件数据 + 一张小缩略图，不长期持有全尺寸 UIImage ——
/// 20 张 4000px 的图全部解成位图会吃掉 1GB 以上内存。
struct BatchItem: Identifiable {

    enum State {
        case pending
        case done
        case failed
    }

    let id = UUID()
    let data: Data
    let thumb: UIImage
    var state: State = .pending
}

@MainActor
final class BatchViewModel: ObservableObject {

    @Published var items: [BatchItem] = []
    @Published var preset: CameraPreset = .phone
    @Published var frame: FrameMode = .ratio4x3
    @Published var trimBars: Bool = true
    @Published var isRunning: Bool = false
    @Published var progress: Double = 0
    @Published var message: String?

    var isEmpty: Bool { items.isEmpty }
    var doneCount: Int { items.filter { $0.state == .done }.count }

    func load(_ payloads: [(data: Data, thumb: UIImage)]) {
        items = payloads.map { BatchItem(data: $0.data, thumb: $0.thumb) }
        progress = 0
        message = nil
    }

    func reset() {
        items = []
        progress = 0
        isRunning = false
        message = nil
    }

    /// 逐张处理并写入相册。
    /// 每张都用同一个预设的基准值 + 独立的随机扰动，所以批量出来的
    /// 颗粒/漏光/抖动各不相同，不会像同一个滤镜刷了 N 遍。
    func run() async {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        progress = 0
        message = nil
        for index in items.indices { items[index].state = .pending }

        let engine = RealismEngine()
        let snapshotPreset = preset
        let snapshotFrame = frame
        let trim = trimBars
        var saved = 0
        var failed = 0

        for index in items.indices {
            let data = items[index].data
            let params = snapshotPreset.baseParameters
                .jittered(seed: UInt64.random(in: 1...UInt64.max))
            let request = RenderRequest(params: params,
                                        frame: snapshotFrame,
                                        trimBars: trim,
                                        anchor: 0.5,
                                        longEdge: 0)
            let quality = max(params.jpegQuality, 0.72)

            // 解码 + 渲染 + 编码整段丢到后台，主线程只管进度条
            let output: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let ui = ImageLoader.image(from: data, maxPixel: 3200),
                          let ci = CIImage(image: ui),
                          let cg = engine.makeFinal(ci, request: request) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let meta = CameraMetadata.make(for: snapshotPreset)
                    let encoded = ExifWriter.write(cg, metadata: meta, quality: quality)
                    continuation.resume(returning: encoded ?? JpegDegrader.encode(cg, quality: quality))
                }
            }

            if let output {
                let stamp = Int(Date().timeIntervalSince1970)
                do {
                    try await PhotoLibrarySaver.save(data: output,
                                                     filename: "RealShot-\(stamp)-\(index + 1).jpg")
                    items[index].state = .done
                    saved += 1
                } catch {
                    items[index].state = .failed
                    failed += 1
                }
            } else {
                items[index].state = .failed
                failed += 1
            }

            progress = Double(index + 1) / Double(items.count)
        }

        isRunning = false
        message = failed == 0 ? "已保存 \(saved) 张到相册" : "成功 \(saved) 张，失败 \(failed) 张"
        Haptics.success()
    }
}
