import SwiftUI
import UIKit

/// 批量队列里的单张查看器。
/// 交互向编辑器看齐：拖动分割线比对「原图 / 成片」，底部缩略图换张，
/// 顺手能重掷随机、分享、看说明、删除。
struct BatchViewer: View {
    @ObservedObject var model: BatchViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: UUID
    /// 分割线位置，0 = 全原图，1 = 全成片。默认停在正中间，左右各一半。
    @State private var compare: Double = 0.5
    @State private var showDragHint = true
    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var isLoading = true
    @State private var confirmDelete = false
    @State private var shareFile: ShareFile?

    init(model: BatchViewModel, startID: UUID) {
        self.model = model
        _currentID = State(initialValue: startID)
    }

    private var current: BatchItem? {
        model.items.first { $0.id == currentID }
    }

    private var position: Int {
        (model.items.firstIndex { $0.id == currentID } ?? 0) + 1
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                imageArea
                thumbStrip
                actionBar
            }
        }
        .statusBarHidden()
        .overlay(alignment: .top) { toast }
        .task(id: currentID) { await reload() }
        .task {
            // 拖过一次或等几秒就收起来，别一直挡着画面
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            showDragHint = false
        }
        .onChange(of: model.previewGeneration) { _, _ in
            Task { await reload() }
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog("删除这张照片？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteCurrent() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只是从这次的批量队列里移除，相册里的原图不受影响。")
        }
    }

    // MARK: 顶栏

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

            VStack(spacing: 1) {
                Text(model.preset.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("第 \(position) / \(model.items.count) 张")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .monospacedDigit()
            }

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
            .disabled(model.isRunning)
            .opacity(model.isRunning ? 0.35 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: 图

    private var imageArea: some View {
        ZStack {
            if let before = before, let after = after {
                CompareSlider(before: before, after: after, position: $compare)
                    .padding(.horizontal, 4)
            } else if isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .scaleEffect(1.2)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .light))
                    Text("这一张预览不出来")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.faint)
            }

            if isLoading, after != nil {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView().tint(Theme.accent).scaleEffect(0.7)
                        Text("渲染中")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 10)
                }
                .allowsHitTesting(false)
            }

            if before != nil, after != nil, showDragHint {
                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 10))
                        Text("拖动中间圆点对比")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 12)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: showDragHint)
        .animation(.easeInOut(duration: 0.18), value: isLoading)
        .onChange(of: compare) { _, _ in showDragHint = false }
    }

    // MARK: 缩略图条

    private var thumbStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(model.items) { item in
                        Button {
                            guard item.id != currentID else { return }
                            currentID = item.id
                            Haptics.tap()
                        } label: {
                            Image(uiImage: item.thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(item.id == currentID ? Theme.accent : Color.white.opacity(0.12),
                                                lineWidth: item.id == currentID ? 2 : 1)
                                )
                                .opacity(item.id == currentID ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 66)
    }

    // MARK: 操作

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("dice", "单张随机") {
                    model.reroll(currentID)
                    Haptics.tap()
                }

                pill("dice.fill", "全部随机") {
                    model.rerollAll()
                    Haptics.tap()
                }

                pill("square.split.2x1", compare > 0.5 ? "看原图" : "看成片") {
                    compare = compare > 0.5 ? 0.0 : 1.0
                    Haptics.select()
                }

                pill("square.and.arrow.up", "分享") {
                    Task { await share() }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 2)
        .padding(.bottom, 16)
    }

    private func pill(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .opacity(model.isRunning ? 0.4 : 1)
    }

    // MARK: 提示
    //
    // 重掷之后画面会变，但只靠画面变化还不够明确，
    // 这里给一句和批量页一致的短提示。

    private var toast: some View {
        Group {
            if let text = model.message {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .padding(.top, 58)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.message)
    }

    // MARK: 动作

    private func reload() async {
        guard let item = current else { return }

        // 看过的图直接上屏，不闪一下加载圈
        if let hit = model.cachedPreview(for: item.id) {
            before = hit.before
            after = hit.after
            isLoading = false
            return
        }

        before = nil
        after = nil
        isLoading = true
        let pair = await model.preview(for: item)
        guard currentID == item.id else { return }
        before = pair?.before
        after = pair?.after
        isLoading = false
    }

    private func deleteCurrent() {
        guard let index = model.items.firstIndex(where: { $0.id == currentID }) else { return }
        model.remove(currentID)
        Haptics.warning()
        if model.items.isEmpty {
            dismiss()
        } else {
            let next = Swift.min(index, model.items.count - 1)
            currentID = model.items[next].id
        }
    }

    private func share() async {
        guard let item = current else { return }
        guard let data = await model.renderFinal(for: item) else {
            model.show("导出失败了")
            Haptics.warning()
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(OutputName.jpeg())
        do {
            try data.write(to: url, options: .atomic)
            shareFile = ShareFile(url: url)
            Haptics.tap()
        } catch {
            model.show("分享文件创建失败")
        }
    }
}
