import SwiftUI
import PhotosUI
import Photos
import UIKit

struct ImportView: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject var batch: BatchViewModel

    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            hero
            Spacer(minLength: 26)
            actions
            Spacer(minLength: 16)
            footnote
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
        .overlay(alignment: .topTrailing) { helpButton }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .onChange(of: pickedItem) { _, newValue in
            guard let newValue else { return }
            load(newValue)
        }
        .onChange(of: pickedItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            loadBatch(newValue)
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
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("从相册选择")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })

            PhotosPicker(selection: $pickedItems,
                         maxSelectionCount: 20,
                         matching: .images,
                         photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.down.right")
                    Text("批量处理（可多选）")
                    Spacer(minLength: 0)
                    Text("最多 20 张")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
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
                    Text("正在读取…")
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

    // MARK: 动作

    private func load(_ item: PhotosPickerItem) {
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = ImageLoader.image(from: data) else {
                model.show("这张图片读不出来")
                return
            }
            model.load(image)
            pickedItem = nil
        }
    }

    /// 批量：只留原始数据 + 一张小缩略图，不把 20 张全尺寸图都解进内存。
    private func loadBatch(_ selection: [PhotosPickerItem]) {
        isLoading = true
        Task { @MainActor in
            defer {
                isLoading = false
                pickedItems = []
            }
            var payloads: [(data: Data, thumb: UIImage)] = []
            for item in selection.prefix(20) {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let thumb = ImageLoader.image(from: data, maxPixel: 640) else { continue }
                payloads.append((data: data, thumb: thumb))
            }
            guard !payloads.isEmpty else {
                model.show("这些图片读不出来")
                Haptics.warning()
                return
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
