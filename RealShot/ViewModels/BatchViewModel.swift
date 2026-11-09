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

    // 与编辑器同一套参数，批量页也能逐项微调
    @Published var params: RealismParameters = CameraPreset.phone.baseParameters
    @Published var anchor: Double = 0.5
    @Published var longEdge: Double = 0
    @Published var writeExif: Bool = true

    var isEmpty: Bool { items.isEmpty }
    var doneCount: Int { items.filter { $0.state == .done }.count }

    private var toastTask: Task<Void, Never>?

    func load(_ payloads: [(data: Data, thumb: UIImage)]) {
        items = payloads.map { BatchItem(data: $0.data, thumb: $0.thumb) }
        progress = 0
        message = nil
    }

    /// 换预设时同步刷新整套参数，和编辑器的行为保持一致。
    func select(_ newPreset: CameraPreset) {
        guard newPreset != preset else { return }
        preset = newPreset
        params = newPreset.baseParameters.jittered(seed: UInt64.random(in: 1...UInt64.max))
    }

    /// 处理中不允许改动队列，避免索引错位。
    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        progress = 0
        show("已移除 1 张")
    }

    func reset() {
        items = []
        progress = 0
        isRunning = false
        message = nil
    }

    /// 逐张处理并写入相册。
    /// 每张都用同一套参数 + 独立的随机扰动，所以批量出来的
    /// 颗粒/漏光/抖动各不相同，不会像同一个滤镜刷了 N 遍。
    func run() async {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        progress = 0
        toastTask?.cancel()
        message = nil
        for index in items.indices { items[index].state = .pending }

        let engine = RealismEngine()
        let base = params
        let snapshotPreset = preset
        let snapshotFrame = frame
        let trim = trimBars
        let snapshotAnchor = anchor
        let snapshotLongEdge = CGFloat(longEdge)
        let writeExif = self.writeExif
        var saved = 0
        var failed = 0

        for index in items.indices {
            let data = items[index].data
            let itemParams = base.jittered(seed: UInt64.random(in: 1...UInt64.max))
            let request = RenderRequest(params: itemParams,
                                        frame: snapshotFrame,
                                        trimBars: trim,
                                        anchor: snapshotAnchor,
                                        longEdge: snapshotLongEdge)
            let quality = max(itemParams.jpegQuality, 0.72)

            // 解码 + 渲染 + 编码整段丢到后台，主线程只管进度条
            let output: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let ui = ImageLoader.image(from: data, maxPixel: 3200),
                          let ci = CIImage(image: ui),
                          let cg = engine.makeFinal(ci, request: request) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if writeExif {
                        let meta = CameraMetadata.make(for: snapshotPreset)
                        if let encoded = ExifWriter.write(cg, metadata: meta, quality: quality) {
                            continuation.resume(returning: encoded)
                            return
                        }
                    }
                    continuation.resume(returning: JpegDegrader.encode(cg, quality: quality))
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
        show(failed == 0 ? "已保存 \(saved) 张到相册" : "成功 \(saved) 张，失败 \(failed) 张")
        Haptics.success()
    }

    // MARK: - 提示

    /// 自动消失的短提示，避免上一轮的结果一直挂在屏幕顶上。
    func show(_ text: String) {
        message = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
