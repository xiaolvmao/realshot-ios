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

    /// 这一张自己的随机种子。预览和最终处理共用同一个种子，
    /// 所以「看到的那张」就是「保存下来的那张」。
    var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
}

@MainActor
final class BatchViewModel: ObservableObject {

    @Published var items: [BatchItem] = []
    @Published var preset: CameraPreset = .phone
    @Published var frame: FrameMode = .ratio4x3 { didSet { dropPreviews() } }
    @Published var trimBars: Bool = true { didSet { dropPreviews() } }
    @Published var isRunning: Bool = false
    @Published var progress: Double = 0
    @Published var message: String?

    // 与编辑器同一套参数，批量页也能逐项微调
    @Published var params: RealismParameters = CameraPreset.phone.baseParameters { didSet { dropPreviews() } }
    @Published var anchor: Double = 0.5 { didSet { dropPreviews() } }
    @Published var longEdge: Double = 0 { didSet { dropPreviews() } }
    @Published var writeExif: Bool = true

    var isEmpty: Bool { items.isEmpty }
    var doneCount: Int { items.filter { $0.state == .done }.count }

    /// 预览失效的计数器。查看器监听它来重新渲染，
    /// 比逐个监听 params / frame / anchor 更省事。
    @Published private(set) var previewGeneration = 0

    private let engine = RealismEngine()
    private var toastTask: Task<Void, Never>?

    /// 成片预览缓存。看过的那张再切回来是瞬时的；
    /// 改参数、换画幅、重掷之后自动失效。
    private var previewCache: [UUID: (before: UIImage, after: UIImage)] = [:]
    /// 缓存上限。20 张 1100px 的对比图约 150MB，不设限会被系统杀掉。
    private var previewOrder: [UUID] = []
    private let previewCacheLimit = 8

    // MARK: - 队列

    func load(_ payloads: [(data: Data, thumb: UIImage)]) {
        items = payloads.map { BatchItem(data: $0.data, thumb: $0.thumb) }
        dropPreviews()
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
        evictPreview(id)
        progress = 0
        show("已移除 1 张")
    }

    func reset() {
        items = []
        dropPreviews()
        progress = 0
        isRunning = false
        message = nil
    }

    // MARK: - 重掷随机

    /// 只重掷这一张。已处理的会退回未处理 —— 预览变了，之前存的那张就不再对得上。
    func reroll(_ id: UUID) {
        guard !isRunning, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].seed = UInt64.random(in: 1...UInt64.max)
        items[index].state = .pending
        evictPreview(id)
        // 只清缓存不够：查看器靠 previewGeneration 触发重渲染，
        // 不自增这一下，画面上还是旧的那张。
        previewGeneration += 1
        progress = 0
        show("这一张换了一种随机")
    }

    func rerollAll() {
        guard !isRunning else { return }
        for index in items.indices {
            items[index].seed = UInt64.random(in: 1...UInt64.max)
            items[index].state = .pending
        }
        dropPreviews()
        progress = 0
        show("全部换了一种随机")
    }

    // MARK: - 预览

    private func dropPreviews() {
        previewCache.removeAll()
        previewOrder.removeAll()
        previewGeneration += 1
    }

    private func evictPreview(_ id: UUID) {
        previewCache[id] = nil
        previewOrder.removeAll { $0 == id }
    }

    /// 命中缓存就不用再等一次渲染，切换图片可以瞬时完成。
    func cachedPreview(for id: UUID) -> (before: UIImage, after: UIImage)? {
        guard let hit = previewCache[id] else { return nil }
        // 命中即视为最近使用，挪到队尾
        previewOrder.removeAll { $0 == id }
        previewOrder.append(id)
        return hit
    }

    private func storePreview(_ pair: (before: UIImage, after: UIImage), for id: UUID) {
        previewCache[id] = pair
        previewOrder.removeAll { $0 == id }
        previewOrder.append(id)
        while previewOrder.count > previewCacheLimit, let evicted = previewOrder.first {
            previewOrder.removeFirst()
            previewCache[evicted] = nil
        }
    }

    /// 当前参数下的「原图 / 成片」对比，用于全屏查看。
    func preview(for item: BatchItem,
                 maxDimension: CGFloat = 1100) async -> (before: UIImage, after: UIImage)? {
        if let hit = cachedPreview(for: item.id) { return hit }

        let request = RenderRequest(params: params.jittered(seed: item.seed),
                                    frame: frame,
                                    trimBars: trimBars,
                                    anchor: anchor,
                                    longEdge: 0)
        let data = item.data

        let pair: (before: UIImage, after: UIImage)? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [engine] in
                guard let ui = ImageLoader.image(from: data, maxPixel: maxDimension * 2),
                      let ci = CIImage(image: ui) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: engine.makeComparison(ci,
                                                                   request: request,
                                                                   maxDimension: maxDimension))
            }
        }
        if let pair { storePreview(pair, for: item.id) }
        return pair
    }

    // MARK: - 导出

    /// 全尺寸渲染 + 编码，用于分享。
    func renderFinal(for item: BatchItem) async -> Data? {
        await encode(data: item.data,
                     params: params.jittered(seed: item.seed),
                     frame: frame,
                     trimBars: trimBars,
                     anchor: anchor,
                     longEdge: CGFloat(longEdge),
                     preset: preset,
                     writeExif: writeExif)
    }

    private func encode(data: Data,
                        params: RealismParameters,
                        frame: FrameMode,
                        trimBars: Bool,
                        anchor: Double,
                        longEdge: CGFloat,
                        preset: CameraPreset,
                        writeExif: Bool) async -> Data? {
        let request = RenderRequest(params: params,
                                    frame: frame,
                                    trimBars: trimBars,
                                    anchor: anchor,
                                    longEdge: longEdge)
        let quality = max(params.jpegQuality, 0.72)

        // 解码 + 渲染 + 编码整段丢到后台，主线程只管进度条
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [engine] in
                guard let ui = ImageLoader.image(from: data, maxPixel: 3200),
                      let ci = CIImage(image: ui),
                      let cg = engine.makeFinal(ci, request: request) else {
                    continuation.resume(returning: nil)
                    return
                }
                if writeExif,
                   let encoded = ExifWriter.write(cg,
                                                  metadata: CameraMetadata.make(for: preset),
                                                  quality: quality) {
                    continuation.resume(returning: encoded)
                    return
                }
                continuation.resume(returning: JpegDegrader.encode(cg, quality: quality))
            }
        }
    }

    // MARK: - 批处理

    /// 逐张处理并写入相册。
    /// 每张都用同一套参数 + 自己的随机种子，所以批量出来的
    /// 颗粒/漏光/抖动各不相同，不会像同一个滤镜刷了 N 遍。
    func run() async {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        progress = 0
        toastTask?.cancel()
        message = nil
        for index in items.indices { items[index].state = .pending }

        let base = params
        let snapshotPreset = preset
        let snapshotFrame = frame
        let trim = trimBars
        let snapshotAnchor = anchor
        let snapshotLongEdge = CGFloat(longEdge)
        let snapshotExif = writeExif
        var saved = 0
        var failed = 0

        for index in items.indices {
            let output = await encode(data: items[index].data,
                                      params: base.jittered(seed: items[index].seed),
                                      frame: snapshotFrame,
                                      trimBars: trim,
                                      anchor: snapshotAnchor,
                                      longEdge: snapshotLongEdge,
                                      preset: snapshotPreset,
                                      writeExif: snapshotExif)

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
