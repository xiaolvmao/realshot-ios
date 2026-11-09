import SwiftUI
import PhotosUI
import Photos
import UIKit

struct ImportView: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject var batch: BatchViewModel

    /// 相册选择统一走多选：选 1 张直接进编辑器，多张进批量。
    /// 系统多选面板本身就是原生的多选 UI（拖选、连续点选都支持）。
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var readDone = 0
    @State private var readTotal = 0
    @State private var showHelp = false
    @State private var confirmClear = false
    @State private var cacheBytes = 0

    /// 与相册面板的上限保持一致，也是批量队列的上限。
    private static let maxSelection = 20

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            hero
            Spacer(minLength: 26)
            actions
            Spacer(minLength: 16)
            footnote
            cacheRow
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
        .overlay(alignment: .topTrailing) { helpButton }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .onAppear { cacheBytes = CacheCleaner.footprint() }
        .confirmationDialog("清理缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清理", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除导出和分享时产生的临时图片，以及预览缓存。相册里的照片不受影响。")
        }
        .onChange(of: pickedItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            load(newValue)
        }
    }

    // MARK: 右上角说明

    private var helpButton: some View {
        Button {
            showHelp = true
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle")
                Text("使用说明")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.subtext)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
        .padding(.top, 6)
    }

    // MARK: 视觉

    private var hero: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .frame(width: 132, height: 168)
                    .rotationEffect(.degrees(-7))
                    .offset(x: -34, y: 6)
                    .overlay(
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.faint)
                            .rotationEffect(.degrees(-7))
                            .offset(x: -34, y: 6)
                    )

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(red: 0.36, green: 0.27, blue: 0.17),
                                                Color(red: 0.15, green: 0.13, blue: 0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 132, height: 168)
                    .rotationEffect(.degrees(5))
                    .offset(x: 32, y: -4)
                    .overlay(
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 42, weight: .ultraLight))
                            .foregroundStyle(Theme.accent.opacity(0.9))
                            .rotationEffect(.degrees(5))
                            .offset(x: 32, y: -4)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            }
            .frame(height: 180)

            VStack(spacing: 10) {
                Text("实拍")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("把截图和网图，还原成真实拍摄的照片")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.subtext)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: 操作

    private var actions: some View {
        VStack(spacing: 11) {
            PhotosPicker(selection: $pickedItems,
                         maxSelectionCount: Self.maxSelection,
                         matching: .images,
                         photoLibrary: .shared()) {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("从相册选择")
                    }
                    .font(.system(size: 16, weight: .semibold))

                    Text("可多选 · 1 张直接编辑，多张批量处理")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.62)
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })

            Button {
                paste()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                    Text("从剪贴板粘贴")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.subtext)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if isLoading {
                HStack(spacing: 7) {
                    ProgressView().tint(Theme.accent).scaleEffect(0.8)
                    Text(readTotal > 1 ? "正在读取 \(max(readDone, 1)) / \(readTotal)…" : "正在读取…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.subtext)
                }
                .padding(.top, 4)
            }
        }
    }

    private var footnote: some View {
        VStack(spacing: 6) {
            Text("适合：网图、渲染图、AI 生图、视频截图、UI 画面")
            Text("纯文字截图无法变成照片 —— 它本来就不是一张照片")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.faint)
        .multilineTextAlignment(.center)
    }

    /// 临时文件和预览缓存会慢慢堆积，给个看得见体积的出口。
    private var cacheRow: some View {
        Button {
            confirmClear = true
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                Text(cacheBytes > 0 ? "清理缓存 · \(CacheCleaner.formatted(cacheBytes))" : "清理缓存")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.subtext)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.surface.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    private func clearCache() {
        let freed = CacheCleaner.clear()
        batch.clearPreviews()
        cacheBytes = CacheCleaner.footprint()
        model.show(freed > 0 ? "已清理 \(CacheCleaner.formatted(freed))" : "没有可清理的内容")
        Haptics.success()
    }

    // MARK: 动作

    /// 统一的入口：一张进编辑器，多张进批量队列。
    private func load(_ selection: [PhotosPickerItem]) {
        let items = Array(selection.prefix(Self.maxSelection))
        guard !items.isEmpty else {
            pickedItems = []
            return
        }

        isLoading = true
        readTotal = items.count
        readDone = 0

        Task { @MainActor in
            defer {
                isLoading = false
                readDone = 0
                readTotal = 0
                pickedItems = []
            }

            // 单张：直接进编辑器，不必绕一步批量队列。
            if items.count == 1 {
                guard let data = try? await items[0].loadTransferable(type: Data.self),
                      let image = ImageLoader.image(from: data) else {
                    model.show("这张图片读不出来")
                    Haptics.warning()
                    return
                }
                model.load(image, sourceData: data)
                Haptics.success()
                return
            }

            // 多张：只留原始数据 + 一张小缩略图，不把 20 张全尺寸图都解进内存。
            var payloads: [(data: Data, thumb: UIImage)] = []
            var skipped = 0
            for item in items {
                defer { readDone += 1 }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let thumb = ImageLoader.image(from: data, maxPixel: 640) else {
                    skipped += 1
                    continue
                }
                payloads.append((data: data, thumb: thumb))
            }

            guard !payloads.isEmpty else {
                model.show("这些图片读不出来")
                Haptics.warning()
                return
            }
            if skipped > 0 {
                model.show("有 \(skipped) 张读不出来，已跳过")
            }
            batch.load(payloads)
            Haptics.success()
        }
    }

    private func paste() {
        guard UIPasteboard.general.hasImages,
              let image = UIPasteboard.general.image else {
            model.show("剪贴板里没有图片")
            Haptics.warning()
            return
        }
        model.load(image)
    }
}
