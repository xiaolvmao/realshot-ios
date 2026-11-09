import SwiftUI
import CoreImage
import UIKit

@MainActor
final class EditorViewModel: ObservableObject {

    // MARK: 输出状态
    @Published private(set) var source: UIImage?
    @Published private(set) var before: UIImage?
    @Published private(set) var after: UIImage?
    @Published private(set) var isBusy = false
    @Published private(set) var toast: String?
    @Published var shareFile: ShareFile?

    // MARK: 参数
    @Published var preset: CameraPreset = .phone
    @Published var params: RealismParameters = CameraPreset.phone.baseParameters {
        didSet {
            scheduleRender()
            persistSoon()
        }
    }
    @Published var frame: FrameMode = .ratio4x3 {
        didSet { scheduleRender(); persistSoon() }
    }
    @Published var trimBars: Bool = true {
        didSet { scheduleRender(); persistSoon() }
    }
    @Published var anchor: Double = 0.5 {
        didSet { scheduleRender(); persistSoon() }
    }
    /// 水平构图位置，0 = 偏左，1 = 偏右
    @Published var cropX: Double = 0.5 {
        didSet { scheduleRender(); persistSoon() }
    }
    /// 向内放大的倍数，1 = 不裁
    @Published var cropScale: Double = 1.0 {
        didSet { scheduleRender(); persistSoon() }
    }
    @Published var writeExif: Bool = true {
        didSet { persistSoon() }
    }
    /// 保存时是否归到「RealShot」相簿（需要完整相册权限）
    @Published var saveToAlbum: Bool = false {
        didSet { persistSoon() }
    }
    @Published var longEdge: Double = 0 {
        didSet { scheduleRender(); persistSoon() }
    }

    // MARK: 对比滑块
    @Published var compare: Double = 0.5

    private let engine = RealismEngine()
    private var sourceCI: CIImage?
    private var sourceData: Data?
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?

    /// 串行渲染队列。滑杆快速拖动时只排队，不会同时起十几个 Core Image 任务
    /// 把 CPU 占满 —— 之前每拖一下都新起一个后台任务，取消只挡住了结果回写，
    /// 计算照样跑完，白白浪费。
    private let renderQueue = DispatchQueue(label: "realshot.editor.render", qos: .userInitiated)
    /// 最新一次渲染请求的编号，排队中的旧任务发现编号过期就直接放弃。
    private let generation = GenerationBox()

    init() {
        if let saved = SettingsStore.loadEditor() {
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
    }

    // MARK: - 输入

    func load(_ image: UIImage, sourceData: Data? = nil) {
        let normalized = image.normalizedForProcessing()
        guard let ci = CIImage(image: normalized) else {
            show("这张图片读不出来")
            Haptics.warning()
            return
        }
        self.sourceData = sourceData
        source = normalized
        sourceCI = ci
        before = nil
        after = nil
        compare = 0.5

        // 每次导入都换一个种子，同一张图重复导入也会得到不同的颗粒分布
        var p = preset.baseParameters
        p = p.jittered(seed: UInt64.random(in: 1...UInt64.max))
        params = p

        Haptics.tap()
        scheduleRender()
    }

    func closeEditor() {
        renderTask?.cancel()
        sourceCI = nil
        sourceData = nil
        source = nil
        before = nil
        after = nil
        isBusy = false
    }

    // MARK: - 预设与随机

    func select(_ newPreset: CameraPreset) {
        guard newPreset != preset else { return }
        preset = newPreset
        params = newPreset.baseParameters.jittered(seed: UInt64.random(in: 1...UInt64.max))
        Haptics.select()
    }

    /// 同一预设下换一组随机扰动
    func reroll() {
        params = preset.baseParameters.jittered(seed: UInt64.random(in: 1...UInt64.max))
        Haptics.tap()
    }

    // MARK: - 渲染

    private func currentRequest(preview: Bool) -> RenderRequest {
        RenderRequest(params: params.clamped(),
                      frame: frame,
                      trimBars: trimBars,
                      anchor: anchor,
                      cropX: cropX,
                      cropScale: cropScale,
                      longEdge: preview ? 1100 : CGFloat(longEdge))
    }

    func scheduleRender() {
        renderTask?.cancel()
        guard let ci = sourceCI else { return }

        let box = generation
        let gen = box.bump()
        let request = currentRequest(preview: true)
        let engine = self.engine
        let queue = renderQueue

        renderTask = Task { [weak self] in
            // 拖滑杆时合并渲染请求
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard let self else { return }
            guard !Task.isCancelled else {
                // 这次请求被更晚的值取代了，不留下一直转的忙碌状态
                if box.current() == gen { self.isBusy = false }
                return
            }
            self.isBusy = true

            let pair: (before: UIImage, after: UIImage)? = await withCheckedContinuation { continuation in
                queue.async {
                    // 在队列里再查一次：排队期间又拖了滑杆的话，这次就别渲了
                    guard box.current() == gen else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: engine.makeComparison(ci,
                                                                        request: request,
                                                                        maxDimension: 1100))
                }
            }

            // 已经有更新的一次请求在跑，忙碌状态交给它收尾
            guard box.current() == gen else { return }
            self.isBusy = false
            if !Task.isCancelled, let pair {
                self.before = pair.before
                self.after = pair.after
            }
        }
    }

    // MARK: - 导出

    private func renderedData() async -> Data? {
        guard let ci = sourceCI else { return nil }
        let request = currentRequest(preview: false)
        let engine = self.engine
        let clamped = params.clamped()
        let preset = self.preset
        let writeExif = self.writeExif
        // 沿用原图的拍摄时间：处理去年的截图，不该显示成今天拍的
        let date = sourceData.flatMap { ImageLoader.captureDate(of: $0) } ?? Date()

        let cg: CGImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: engine.makeFinal(ci, request: request))
            }
        }
        guard let cg else { return nil }

        let quality = max(clamped.jpegQuality, 0.72)
        if writeExif {
            let meta = CameraMetadata.make(for: preset, date: date)
            if let data = ExifWriter.write(cg, metadata: meta, quality: quality) {
                return data
            }
        }
        return JpegDegrader.encode(cg, quality: quality)
    }

    func saveToLibrary() async {
        guard sourceCI != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        guard let data = await renderedData() else {
            show("导出失败了，换张图试试")
            Haptics.warning()
            return
        }

        do {
            try await PhotoLibrarySaver.save(data: data,
                                             filename: OutputName.jpeg(),
                                             albumName: saveToAlbum ? "RealShot" : nil)
            Haptics.success()
            show("已保存到相册")
        } catch {
            Haptics.warning()
            show(error.localizedDescription)
        }
    }

    func prepareShare() async {
        guard sourceCI != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        guard let data = await renderedData() else {
            show("导出失败了")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(OutputName.jpeg())
        do {
            try data.write(to: url, options: .atomic)
            shareFile = ShareFile(url: url)
            Haptics.tap()
        } catch {
            show("分享文件创建失败")
        }
    }

    // MARK: - 设置持久化

    /// 拖滑杆会高频触发，攒 0.4 秒再写一次，避免每一帧都动 UserDefaults。
    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        SettingsStore.saveEditor(.init(preset: preset,
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

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.toast = nil }
        }
    }
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 给后台渲染队列用的请求编号。渲染在后台线程、编号在主线程推进，
/// 用一个带锁的小盒子比把整个 ViewModel 标成 Sendable 干净。
final class GenerationBox: @unchecked Sendable {

    private let lock = NSLock()
    private var value = 0

    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
