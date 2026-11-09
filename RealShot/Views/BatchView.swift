import SwiftUI
import PhotosUI
import UIKit

struct BatchView: View {
    @ObservedObject var model: BatchViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    @State private var viewerSeed: ViewerSeed?
    @State private var showParams = false
    @State private var showHelp = false
    @State private var appendItems: [PhotosPickerItem] = []
    @State private var isAppending = false

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
        .sheet(isPresented: $showHelp) { HelpView() }
        .fullScreenCover(item: $viewerSeed) { seed in
            BatchViewer(model: model, startID: seed.id)
        }
        .onChange(of: appendItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            append(newValue)
        }
    }

    private struct ViewerSeed: Identifiable {
        let id: UUID
    }

    // MARK: 顶栏

    private var header: some View {
        // 标题放在 ZStack 里绝对居中，两侧各自排布，加了右上角的按钮也不会把标题挤偏
        ZStack {
            VStack(spacing: 1) {
                Text("批量处理")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(model.items.count) 张 · \(model.preset.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }

            HStack(spacing: 8) {
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

                // 撤回 / 恢复：换预设、换随机、增删照片都能退回去
                historyButton("arrow.uturn.backward", enabled: model.canUndo && !model.isRunning, label: "撤回") {
                    model.undo()
                }
                historyButton("arrow.uturn.forward", enabled: model.canRedo && !model.isRunning, label: "恢复") {
                    model.redo()
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(model.doneCount > 0 ? "\(model.doneCount)/\(model.items.count)" : "")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                        .frame(width: 34)

                    Button {
                        showHelp = true
                        Haptics.tap()
                    } label: {
                        Image(systemName: "questionmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.subtext)
                            .frame(width: 34, height: 34)
                            .background(Theme.surfaceRaised, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func historyButton(_ symbol: String,
                               enabled: Bool,
                               label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.faint)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private var hint: some View {
        Text("点开可拖动对比原图 · 长按删除")
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
                if model.items.count < BatchViewModel.maxItems {
                    addCell
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
    }

    /// 加号跟在最后一张后面：新照片本来就是追加到队尾的，
    /// 放在头上会让人以为是从前面插进去。
    private var addCell: some View {
        // 先取成局部 Bool，避免在 PhotosPicker 的 label 闭包里碰 main actor 上的 model
        let running = model.isRunning
        let appending = isAppending

        return PhotosPicker(selection: $appendItems,
                            maxSelectionCount: 20,
                            matching: .images,
                            photoLibrary: .shared()) {
            VStack(spacing: 6) {
                Image(systemName: appending ? "ellipsis" : "plus")
                    .font(.system(size: 18, weight: .medium))
                Text(appending ? "读取中" : "添加")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(running ? Theme.faint : Theme.subtext)
            .frame(height: 104)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surfaceRaised.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
        .disabled(running || appending)
        .opacity(running ? 0.4 : 1)
    }

    private func cell(_ item: BatchItem) -> some View {
        Button {
            viewerSeed = ViewerSeed(id: item.id)
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
                VStack(spacing: 7) {
                    ProgressView(value: model.progress)
                        .tint(Theme.accent)

                    HStack(spacing: 10) {
                        Text("正在处理第 \(Int(model.progress * Double(model.items.count)).clamped(to: 1...max(model.items.count, 1))) 张 · \(Int(model.progress * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.subtext)
                            .monospacedDigit()

                        Spacer(minLength: 0)

                        // 20 张一批，中途发现选错图不用干等到底
                        Button {
                            model.cancel()
                            Haptics.warning()
                        } label: {
                            Text(model.isCancelling ? "取消中…" : "取消")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(model.isCancelling ? Theme.faint : Color.orange)
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background(Color.orange.opacity(model.isCancelling ? 0.06 : 0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isCancelling)
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
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
                           cropX: $model.cropX,
                           cropScale: $model.cropScale,
                           longEdge: $model.longEdge,
                           writeExif: $model.writeExif,
                           saveToAlbum: $model.saveToAlbum,
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

    // MARK: 追加照片

    /// 从相册补几张进来。重复的图不会被去重 —— 用户可能就是想再处理一遍。
    private func append(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else {
            appendItems = []
            return
        }

        isAppending = true
        Task { @MainActor in
            defer {
                isAppending = false
                appendItems = []
            }

            let loaded = await PhotoPickerLoader.load(selection, limit: 20)

            guard !loaded.payloads.isEmpty else {
                model.show("这些图片读不出来")
                Haptics.warning()
                return
            }

            model.append(loaded.payloads.map { (data: $0.data, thumb: $0.thumb) })
            if loaded.skipped > 0 {
                model.show("有 \(loaded.skipped) 张读不出来，已跳过")
            }
            Haptics.success()
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
