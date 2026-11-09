import SwiftUI

struct BatchView: View {
    @ObservedObject var model: BatchViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            previewGrid
            controls
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) { toast }
        .animation(.easeInOut(duration: 0.2), value: model.message)
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

    // MARK: 控制区

    private var controls: some View {
        VStack(spacing: 12) {
            PresetStrip(selected: model.preset) { preset in
                model.preset = preset
                Haptics.select()
            }

            HStack(spacing: 10) {
                Picker("画幅", selection: $model.frame) {
                    ForEach(FrameMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)

                Toggle(isOn: $model.trimBars) {
                    Text("去状态栏")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.subtext)
                }
                .labelsHidden()
                .tint(Theme.accent)
                .disabled(model.isRunning)
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

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
