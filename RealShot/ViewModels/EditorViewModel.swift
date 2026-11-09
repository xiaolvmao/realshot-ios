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
        didSet { scheduleRender() }
    }
    @Published var frame: FrameMode = .ratio4x3 {
        didSet { scheduleRender() }
    }
    @Published var trimBars: Bool = true {
        didSet { scheduleRender() }
    }
    @Published var anchor: Double = 0.5 {
        didSet { scheduleRender() }
    }
    @Published var writeExif: Bool = true
    @Published var longEdge: Double = 0 {
        didSet { scheduleRender() }
    }

    // MARK: 对比滑块
    @Published var compare: Double = 0.5

    private let engine = RealismEngine()
    private var sourceCI: CIImage?
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    // MARK: - 输入

    func load(_ image: UIImage) {
        let normalized = image.normalizedForProcessing()
        guard let ci = CIImage(image: normalized) else {
            show("这张图片读不出来")
            Haptics.warning()
            return
        }
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
        source = nil
        before = nil
        after = nil
        isBusy = false
    }

    // MARK: - 预设

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
        RenderRequest(params: params,
                      frame: frame,
                      trimBars: trimBars,
                      anchor: anchor,
                      longEdge: preview ? 1100 : CGFloat(longEdge))
    }

    func scheduleRender() {
        renderTask?.cancel()
        guard let ci = sourceCI else { return }

        let request = currentRequest(preview: true)
        let engine = self.engine

        renderTask = Task { [weak self] in
            // 拖滑杆时合并渲染请求
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isBusy = true

            let pair = await withCheckedContinuation { (continuation: CheckedContinuation<(UIImage, UIImage)?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = engine.makeComparison(ci, request: request, maxDimension: 1100)
                    continuation.resume(returning: result.map { ($0.before, $0.after) })
                }
            }

            guard !Task.isCancelled else { return }
            if let pair {
                self.before = pair.0
                self.after = pair.1
            }
            self.isBusy = false
        }
    }

    // MARK: - 导出

    private func renderedData() async -> Data? {
        guard let ci = sourceCI else { return nil }
        let request = currentRequest(preview: false)
        let engine = self.engine
        let params = self.params
        let preset = self.preset
        let writeExif = self.writeExif

        let cg: CGImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: engine.makeFinal(ci, request: request))
            }
        }
        guard let cg else { return nil }

        if writeExif {
            let meta = CameraMetadata.make(for: preset)
            if let data = ExifWriter.write(cg, metadata: meta, quality: max(params.jpegQuality, 0.72)) {
                return data
            }
        }
        return JpegDegrader.encode(cg, quality: max(params.jpegQuality, 0.72))
    }

    func saveToLibrary() async {
        guard sourceCI != nil else { return }
        isBusy = true
        defer { isBusy = false }

        guard let data = await renderedData() else {
            show("导出失败了，换张图试试")
            Haptics.warning()
            return
        }

        let stamp = Int(Date().timeIntervalSince1970)
        do {
            try await PhotoLibrarySaver.save(data: data, filename: "RealShot-\(stamp).jpg")
            Haptics.success()
            show("已保存到相册")
        } catch {
            Haptics.warning()
            show(error.localizedDescription)
        }
    }

    func prepareShare() async {
        guard sourceCI != nil else { return }
        isBusy = true
        defer { isBusy = false }

        guard let data = await renderedData() else {
            show("导出失败了")
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealShot-\(stamp).jpg")
        do {
            try data.write(to: url, options: .atomic)
            shareFile = ShareFile(url: url)
            Haptics.tap()
        } catch {
            show("分享文件创建失败")
        }
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
