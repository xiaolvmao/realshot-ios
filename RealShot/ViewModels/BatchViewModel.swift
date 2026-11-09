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

/// 一次批量操作之前的完整快照，用来支撑撤回 / 恢复。
///
/// items 存的是结构体数组，里面的 Data 和缩略图都是引用计数共享的，
/// 所以记十步也不会真把十份原图拷进内存；只有被删掉的那张会多留一份。
struct BatchUndoState {
    var items: [BatchItem]
    var preset: CameraPreset
    var params: RealismParameters
    var frame: FrameMode
    var trimBars: Bool
    var anchor: Double
    var cropX: Double
    var cropScale: Double
}

@MainActor
final class BatchViewModel: ObservableObject {

    static let maxItems = 40

    @Published var items: [BatchItem] = []
    @Published var isRunning: Bool = false
    @Published var isCancelling: Bool = false
    @Published var progress: Double = 0
    @Published var message: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // 与编辑器同一套参数，批量页也能逐项微调。
    // 每个 didSet 都会让已经处理过的结果作废 —— 见 invalidateResults。
    @Published var preset: CameraPreset = .phone
    @Published var frame: FrameMode = .ratio4x3 { didSet { invalidateResults() } }
    @Published var trimBars: Bool = true { didSet { invalidateResults() } }
    @Published var params: RealismParameters = CameraPreset.phone.baseParameters {
        didSet { invalidateResults() }
    }
    @Published var anchor: Double = 0.5 { didSet { invalidateResults() } }
    @Published var cropX: Double = 0.5 { didSet { invalidateResults() } }
    @Published var cropScale: Double = 1.0 { didSet { invalidateResults() } }
    @Published var longEdge: Double = 0 { didSet { invalidateResults() } }
    /// 只影响导出，不影响预览，所以不必让预览失效
    @Published var writeExif: Bool = true { didSet { markStale() } }
    @Published var saveToAlbum: Bool = false { didSet { markStale() } }

    var isEmpty: Bool { items.isEmpty }
    var doneCount: Int { items.filter { $0.state == .done }.count }

    /// 预览失效的计数器。查看器监听它来重新渲染，
    /// 比逐个监听 params / frame / anchor 更省事。
    @Published private(set) var previewGeneration = 0

    private let engine = RealismEngine()
    private var toastTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var memoryToken: NSObjectProtocol?
    private var cancelRequested = false
    private var staleNoticeShown = false

    /// 撤回 / 恢复。换预设、换随机、增删照片都记一步。
    private var history = ReversibleHistory<BatchUndoState>(limit: 10)
    /// 正在回填快照：此时各属性的 didSet 不应该再触发「参数已改」那一套。
    private var isRestoring = false

    /// 成片预览缓存。看过的那张再切回来是瞬时的；
    /// 改参数、换画幅、重掷之后自动失效。
    private var previewCache: [UUID: (before: UIImage, after: UIImage)] = [:]
    /// 缓存上限。20 张 1100px 的对比图约 150MB，不设限会被系统杀掉。
    private var previewOrder: [UUID] = []
    private let previewCacheLimit = 8

    init() {
        if let saved = SettingsStore.loadBatch() {
            preset = saved.preset
            params = saved.params.clamped()
            frame = saved.frame
            trimBars = saved.trimBars
            anchor = saved.anchor
            cropX = saved.cropX
            cropScale = saved.cropScale
            longEdge = saved.longEdge
            writeExif = saved.writeExif
            saveToAlbum = saved.saveToAlbum
        }

        // 收到内存警告就把预览缓存放掉：重新渲染一次只要几百毫秒，
        // 但被系统以内存为由杀掉就没有第二次机会了。
        memoryToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dropPreviews() }
        }
    }

    deinit {
        if let memoryToken {
            NotificationCenter.default.removeObserver(memoryToken)
        }
    }

    // MARK: - 队列

    func load(_ payloads: [(data: Data, thumb: UIImage)]) {
        items = payloads.prefix(Self.maxItems).map { BatchItem(data: $0.data, thumb: $0.thumb) }
        dropPreviews()
        history.clear()
        syncHistory()
        progress = 0
        message = nil
        staleNoticeShown = false
    }

    /// 从相册追加几张，不用退出去重选整批。返回新加入那几张的 id，
    /// 全屏查看器靠它把画面切到刚加的第一张上。
    @discardableResult
    func append(_ payloads: [(data: Data, thumb: UIImage)]) -> [UUID] {
        guard !isRunning, !payloads.isEmpty else { return [] }

        let room = Self.maxItems - items.count
        guard room > 0 else {
            show("队列最多 \(Self.maxItems) 张")
            return []
        }

        recordUndo()
        let slice = Array(payloads.prefix(room))
        let added = slice.map { BatchItem(data: $0.data, thumb: $0.thumb) }
        items.append(contentsOf: added)

        // 参数没变，老照片的预览依然有效，不必整片丢掉重渲；
        // 新加的那几张本来就没有缓存，第一次打开时现算。
        progress = 0
        staleNoticeShown = false
        show(slice.count < payloads.count ? "已添加 \(slice.count) 张，超出上限的已忽略" : "已添加 \(slice.count) 张")
        return added.map(\.id)
    }

    /// 换预设时同步刷新整套参数，和编辑器的行为保持一致。
    func select(_ newPreset: CameraPreset) {
        guard newPreset != preset else { return }
        recordUndo()
        preset = newPreset
        params = newPreset.baseParameters.jittered(seed: UInt64.random(in: 1...UInt64.max))
    }

    /// 处理中不允许改动队列，避免索引错位。
    func remove(_ id: UUID) {
        guard !isRunning else { return }
        recordUndo()
        items.removeAll { $0.id == id }
        evictPreview(id)
        progress = 0
        show("已移除 1 张")
    }

    func reset() {
        items = []
        dropPreviews()
        history.clear()
        syncHistory()
        progress = 0
        isRunning = false
        isCancelling = false
        message = nil
    }

    // MARK: - 重掷随机

    /// 只重掷这一张。已处理的会退回未处理 —— 预览变了，之前存的那张就不再对得上。
    func reroll(_ id: UUID) {
        guard !isRunning, let index = items.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
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
        recordUndo()
        for index in items.indices {
            items[index].seed = UInt64.random(in: 1...UInt64.max)
            items[index].state = .pending
        }
        dropPreviews()
        progress = 0
        show("全部换了一种随机")
    }

    // MARK: - 撤回 / 恢复
    //
    // 批量页的「上一次改动」既可能是换随机，也可能是换预设、删掉一张、
    // 或者刚追加了几张 —— 所以记的是整份快照，而不是单个参数。

    @discardableResult
    func undo() -> Bool {
        guard !isRunning, let state = history.undo(current: currentState()) else { return false }
        restore(state)
        show("已撤回上一次改动")
        Haptics.tap()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard !isRunning, let state = history.redo(current: currentState()) else { return false }
        restore(state)
        show("已恢复")
        Haptics.tap()
        return true
    }

    private func recordUndo() {
        guard !isRunning else { return }
        history.record(currentState())
        syncHistory()
    }

    private func currentState() -> BatchUndoState {
        BatchUndoState(items: items,
                       preset: preset,
                       params: params,
                       frame: frame,
                       trimBars: trimBars,
                       anchor: anchor,
                       cropX: cropX,
                       cropScale: cropScale)
    }

    private func restore(_ state: BatchUndoState) {
        isRestoring = true
        items = state.items
        preset = state.preset
        frame = state.frame
        trimBars = state.trimBars
        anchor = state.anchor
        cropX = state.cropX
        cropScale = state.cropScale
        params = state.params
        isRestoring = false

        // 画面回到了旧参数，之前打的勾不再成立；但提示语是「已撤回」，
        // 不该再叠一句「参数已改，需要重新处理」。
        dropPreviews()
        markStale(announce: false)
        progress = 0
        persistNow()
        syncHistory()
    }

    private func syncHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: - 结果失效

    /// 参数一变，之前存进相册的那批就不再对应当前画面：
    /// 预览要重算，已经打勾的条目也要退回待处理。
    /// 否则界面会一直显示「12/12 已完成」，而实际存进去的是另一套参数。
    private func invalidateResults() {
        // 撤回 / 恢复时属性会连续赋值，这时候由 restore 自己统一收尾。
        guard !isRestoring else { return }
        // 手动改参数之后，再按「恢复」会把这一点改动一起吃掉，先把 redo 丢掉。
        if history.canRedo {
            history.clearRedo()
            syncHistory()
        }
        dropPreviews()
        markStale()
        persistSoon()
    }

    private func markStale(announce: Bool = true) {
        guard !isRunning else { return }
        var changed = false
        for index in items.indices where items[index].state != .pending {
            items[index].state = .pending
            changed = true
        }
        guard changed || progress > 0 else { return }
        progress = 0
        if announce, !staleNoticeShown {
            staleNoticeShown = true
            show("参数已改，需要重新处理")
        }
    }

    // MARK: - 预览

    private func dropPreviews() {
        previewCache.removeAll()
        previewOrder.removeAll()
        previewGeneration += 1
    }

    /// 供「清理缓存」用。
    func clearPreviews() {
        dropPreviews()
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

        let request = RenderRequest(params: params.clamped().jittered(seed: item.seed),
                                    frame: frame,
                                    trimBars: trimBars,
                                    anchor: anchor,
                                    cropX: cropX,
                                    cropScale: cropScale,
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
                     params: params.clamped().jittered(seed: item.seed),
                     frame: frame,
                     trimBars: trimBars,
                     anchor: anchor,
                     cropX: cropX,
                     cropScale: cropScale,
                     longEdge: CGFloat(longEdge),
                     preset: preset,
                     writeExif: writeExif)
    }

    private func encode(data: Data,
                        params: RealismParameters,
                        frame: FrameMode,
                        trimBars: Bool,
                        anchor: Double,
                        cropX: Double,
                        cropScale: Double,
                        longEdge: CGFloat,
                        preset: CameraPreset,
                        writeExif: Bool) async -> Data? {
        let request = RenderRequest(params: params,
                                    frame: frame,
                                    trimBars: trimBars,
                                    anchor: anchor,
                                    cropX: cropX,
                                    cropScale: cropScale,
                                    longEdge: longEdge)
        let quality = max(params.jpegQuality, 0.72)
        // 解码上限要和单张编辑一致，否则同一张图两条路径出来的尺寸不同。
        // 选了更小的目标长边时，先按工作尺寸解码，再在管线里缩下去。
        let decodePixel = max(ImageLoader.workingPixel, longEdge > 1 ? longEdge : 0)
        let date = ImageLoader.captureDate(of: data) ?? Date()

        // 解码 + 渲染 + 编码整段丢到后台，主线程只管进度条
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [engine] in
                guard let ui = ImageLoader.image(from: data, maxPixel: decodePixel),
                      let ci = CIImage(image: ui),
                      let cg = engine.makeFinal(ci, request: request) else {
                    continuation.resume(returning: nil)
                    return
                }
                if writeExif,
                   let encoded = ExifWriter.write(cg,
                                                  metadata: CameraMetadata.make(for: preset, date: date),
                                                  quality: quality) {
                    continuation.resume(returning: encoded)
                    return
                }
                continuation.resume(returning: JpegDegrader.encode(cg, quality: quality))
            }
        }
    }

    // MARK: - 批处理

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        cancelRequested = true
        show("正在取消…")
    }

    /// 逐张处理并写入相册。
    /// 每张都用同一套参数 + 自己的随机种子，所以批量出来的
    /// 颗粒/漏光/抖动各不相同，不会像同一个滤镜刷了 N 遍。
    func run() async {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        isCancelling = false
        cancelRequested = false
        staleNoticeShown = false
        progress = 0
        toastTask?.cancel()
        message = nil
        for index in items.indices { items[index].state = .pending }

        let base = params.clamped()
        let snapshotPreset = preset
        let snapshotFrame = frame
        let trim = trimBars
        let snapshotAnchor = anchor
        let snapshotCropX = cropX
        let snapshotCropScale = cropScale
        let snapshotLongEdge = CGFloat(longEdge)
        let snapshotExif = writeExif
        let album = saveToAlbum ? "RealShot" : nil

        var saved = 0
        var failed = 0
        var processed = 0
        var cancelled = false

        // 每 5 张合并成一次相册事务：20 张各开一次 performChanges 在高负载下会很拖，
        // 分块又能把一批 JPEG 的内存控制在 20MB 上下。
        let chunkSize = 5
        var cursor = 0

        while cursor < items.count {
            if cancelRequested {
                cancelled = true
                break
            }

            let end = min(cursor + chunkSize, items.count)
            var pending: [(index: Int, file: PhotoLibrarySaver.File)] = []

            for index in cursor..<end {
                if cancelRequested {
                    cancelled = true
                    break
                }

                let output = await encode(data: items[index].data,
                                          params: base.jittered(seed: items[index].seed),
                                          frame: snapshotFrame,
                                          trimBars: trim,
                                          anchor: snapshotAnchor,
                                          cropX: snapshotCropX,
                                          cropScale: snapshotCropScale,
                                          longEdge: snapshotLongEdge,
                                          preset: snapshotPreset,
                                          writeExif: snapshotExif)

                if let output {
                    pending.append((index: index,
                                    file: PhotoLibrarySaver.File(data: output,
                                                                 filename: OutputName.jpeg())))
                } else {
                    items[index].state = .failed
                    failed += 1
                    processed += 1
                    progress = Double(processed) / Double(items.count)
                }
            }

            if !pending.isEmpty {
                let results = await PhotoLibrarySaver.saveAll(pending.map { $0.file }, albumName: album)
                for (offset, entry) in pending.enumerated() {
                    let ok = offset < results.count && results[offset]
                    items[entry.index].state = ok ? .done : .failed
                    if ok { saved += 1 } else { failed += 1 }
                    processed += 1
                    progress = Double(processed) / Double(items.count)
                }
            }

            cursor = end
        }

        isRunning = false
        isCancelling = false
        cancelRequested = false

        // 跑完一轮之后，「处理前」的快照已经对不上了：这时候再撤回，
        // 会把刚打上的勾一起清掉，看起来像出错。直接清空历史更符合直觉 ——
        // 已经写进相册的照片本来也撤不回来。
        history.clear()
        syncHistory()

        if cancelled {
            show(saved > 0 ? "已取消 · 已保存 \(saved) 张" : "已取消，没有保存")
            Haptics.warning()
        } else {
            show(failed == 0 ? "已保存 \(saved) 张到相册" : "成功 \(saved) 张，失败 \(failed) 张")
            if failed == 0 { Haptics.success() } else { Haptics.warning() }
        }
    }

    // MARK: - 设置持久化

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        SettingsStore.saveBatch(.init(preset: preset,
                                      params: params,
                                      frame: frame,
                                      trimBars: trimBars,
                                      anchor: anchor,
                                      cropX: cropX,
                                      cropScale: cropScale,
                                      longEdge: longEdge,
                                      writeExif: writeExif,
                                      saveToAlbum: saveToAlbum))
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
