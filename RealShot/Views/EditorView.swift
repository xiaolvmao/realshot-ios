import SwiftUI
import UIKit

struct EditorView: View {
    @ObservedObject var model: EditorViewModel
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            bottomBar
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) { toastOverlay }
        .sheet(item: $model.shareFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack {
            Button {
                model.closeEditor()
                Haptics.tap()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 0) {
                Text(model.preset.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }

            Spacer()

            Button {
                Task { await model.saveToLibrary() }
            } label: {
                Text("保存")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .opacity(model.isBusy ? 0.55 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        let size = model.after?.pixelSize ?? model.source?.pixelSize ?? .zero
        guard size.width > 1 else { return model.preset.subtitle }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    // MARK: 预览

    private var preview: some View {
        ZStack {
            Color.black

            if let before = model.before, let after = model.after {
                CompareSlider(before: before, after: after, position: $model.compare)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else if let source = model.source {
                Image(uiImage: source)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 12)
                    .opacity(0.35)
            }

            if model.before == nil {
                ProgressView()
                    .tint(Theme.accent)
                    .scaleEffect(1.1)
            }

            if model.isBusy, model.before != nil {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView().tint(Theme.accent).scaleEffect(0.75)
                        Text("渲染中")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.subtext)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.reroll()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "dice")
                        Text("换一种随机")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    model.compare = model.compare > 0.5 ? 0.0 : 1.0
                    Haptics.select()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.split.2x1")
                        Text(model.compare > 0.5 ? "看原图" : "看成片")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await model.prepareShare() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                        Text("分享")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showHelp = true
                    Haptics.tap()
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.subtext)
                        .frame(width: 30, height: 30)
                        .background(Theme.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showHelp) {
                    HelpView()
                }
            }
            .padding(.horizontal, 16)

            PresetStrip(selected: model.preset) { preset in
                model.select(preset)
            }
            .padding(.bottom, 6)

            ParameterPanel(params: $model.params,
                           frame: $model.frame,
                           trimBars: $model.trimBars,
                           anchor: $model.anchor,
                           longEdge: $model.longEdge,
                           writeExif: $model.writeExif)
        }
        .padding(.top, 10)
    }

    // MARK: 提示

    private var toastOverlay: some View {
        Group {
            if let toast = model.toast {
                Text(toast)
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
    }
}

// MARK: - 分享

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
