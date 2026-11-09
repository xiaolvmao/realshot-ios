import SwiftUI
import UIKit

struct BatchView: View {
    @ObservedObject var model: BatchViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    @State private var viewing: BatchItem?
    @State private var showParams = false

    var body: some View {
        VStack(spacing: 0) {
            header
            hint
            previewGrid
            controls
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) { toast }
        .animation(.easeInOut(duration: 0.2), value: model.message)
        .sheet(isPresented: $showParams) { parameterSheet }
        .fullScreenCover(item: $viewing) { item in
            BatchPreview(item: item,
                         position: position(of: item),
                         total: model.items.count,
                         canDelete: !model.isRunning) {
                model.remove(item.id)
            }
        }
    }

    private func position(of item: BatchItem) -> Int {
        (model.items.firstIndex { $0.id == item.id } ?? 0) + 1
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(alignment: .center) {
            Button {
                model.reset()
                Haptics.tap()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
            .opacity(model.isRunning ? 0.4 : 1)

            Spacer()

            VStack(spacing: 1) {
                Text("批量处理")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(model.items.count) 张 · \(model.preset.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }

            Spacer()

            Text(model.doneCount > 0 ? "\(model.doneCount)/\(model.items.count)" : "")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .monospacedDigit()
                .frame(width: 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var hint: some View {
        Text("点开看大图 · 长按删除")
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.bottom, 2)
    }

    // MARK: 缩略图

    private var previewGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.items) { item in
                    cell(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
    }

    private func cell(_ item: BatchItem) -> some View {
        Button {
            viewing = item
            Haptics.tap()
        } label: {
            Image(uiImage: item.thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    ZStack {
                        switch item.state {
                        case .pending:
                            EmptyView()
                        case .done:
                            Color.black.opacity(0.28)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        case .failed:
                            Color.black.opacity(0.45)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 19))
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                model.remove(item.id)
                Haptics.warning()
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(model.isRunning)
        }
    }

    // MARK: 控制区

    private var controls: some View {
        VStack(spacing: 12) {
            PresetStrip(selected: model.preset) { preset in
                model.select(preset)
                Haptics.select()
            }

            HStack(spacing: 8) {
                Picker("画幅", selection: $model.frame) {
                    ForEach(FrameMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)

                Button {
                    showParams = true
                    Haptics.tap()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("参数")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(Theme.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if model.isRunning {
                VStack(spacing: 8) {
                    ProgressView(value: model.progress)
                        .tint(Theme.accent)
                    Text("正在处理第 \(Int(model.progress * Double(model.items.count)).clamped(to: 1...max(model.items.count, 1))) 张 · \(Int(model.progress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.subtext)
                        .monospacedDigit()
                }
                .padding(.horizontal, 18)
                .frame(height: 52)
            } else {
                Button {
                    Task { await model.run() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: model.doneCount == model.items.count ? "checkmark" : "square.and.arrow.down")
                        Text(model.doneCount == model.items.count ? "已全部保存" : "开始处理并保存")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    // MARK: 参数抽屉

    private var parameterSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("参数")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    showParams = false
                } label: {
                    Text("完成")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            Text("参数在点「开始处理」时生效，缩略图里显示的仍是原图。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            ParameterPanel(params: $model.params,
                           frame: $model.frame,
                           trimBars: $model.trimBars,
                           anchor: $model.anchor,
                           longEdge: $model.longEdge,
                           writeExif: $model.writeExif,
                           height: nil)
        }
        .background(Theme.background)
        .presentationDetents([.height(372), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    // MARK: 提示

    private var toast: some View {
        Group {
            if let message = model.message {
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

// MARK: - 单张全屏

private struct BatchPreview: View {
    let item: BatchItem
    let position: Int
    let total: Int
    let canDelete: Bool
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 4)
            } else {
                ProgressView()
                    .tint(Theme.accent)
                    .scaleEffect(1.2)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
        }
        .statusBarHidden()
        .task {
            image = await decode()
        }
        .confirmationDialog("删除这张照片？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只是从这次的批量队列里移除，相册里的原图不受影响。")
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("第 \(position) / \(total) 张")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .monospacedDigit()

            Spacer()

            Button {
                confirmDelete = true
                Haptics.tap()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .opacity(canDelete ? 1 : 0.35)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(statusText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            Spacer()

            if let image {
                Text("\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height))")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var statusText: String {
        switch item.state {
        case .pending: return "待处理"
        case .done: return "已保存到相册"
        case .failed: return "处理失败"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .pending: return Theme.faint
        case .done: return Theme.accent
        case .failed: return Color.orange
        }
    }

    /// 缩略图只有 640px，全屏会糊，这里按屏幕尺寸重新解一张。
    private func decode() async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ImageLoader.image(from: item.data, maxPixel: 2200))
            }
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
