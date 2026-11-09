import SwiftUI

// MARK: - 单条滑杆

struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var display: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(spacing: 1) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.subtext)
                Spacer()
                Text(display(value))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
                .tint(Theme.accent)
                .controlSize(.mini)
        }
    }
}

private func percent(_ v: Double) -> String {
    "\(Int((v * 100).rounded()))"
}

// MARK: - 参数面板

struct ParameterPanel: View {

    // 不直接依赖某个 ViewModel：编辑器和批量页各有自己的参数容器，
    // 这里只要一组 Binding 即可复用。
    @Binding var params: RealismParameters
    @Binding var frame: FrameMode
    @Binding var trimBars: Bool
    @Binding var anchor: Double
    @Binding var longEdge: Double
    @Binding var writeExif: Bool

    /// nil 表示由外部容器决定高度（例如放在 sheet 里）。
    var height: CGFloat? = 246

    enum Tab: String, CaseIterable, Identifiable {
        case texture = "质感"
        case optics = "光学"
        case color = "色彩"
        case output = "画幅"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .texture

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    switch tab {
                    case .texture: texture
                    case .optics: optics
                    case .color: color
                    case .output: output
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 22)
            }
        }
        .frame(height: height)
        .frame(maxWidth: height == nil ? CGFloat.infinity : nil,
               maxHeight: height == nil ? CGFloat.infinity : nil)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = item }
                    Haptics.select()
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12.5, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.black : Theme.subtext)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            Capsule().fill(tab == item ? Theme.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: 质感

    private var texture: some View {
        Group {
            ParameterSlider(title: "颗粒", value: $params.grain) { percent($0) }
            ParameterSlider(title: "颗粒粗细", value: $params.grainSize, range: 0.8...2.4) {
                String(format: "%.1f×", $0)
            }
            ParameterSlider(title: "彩色噪点", value: $params.chromaNoise) { percent($0) }
            ParameterSlider(title: "压缩质量", value: $params.jpegQuality, range: 0.45...0.95) {
                String(format: "%.2f", $0)
            }

            Stepper(value: $params.jpegPasses, in: 0...3) {
                HStack {
                    Text("压缩次数")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.subtext)
                    Spacer()
                    Text("\(params.jpegPasses)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                }
            }
            .tint(Theme.accent)

            ParameterSlider(title: "屏幕纹理（翻拍感）", value: $params.screenTexture) { percent($0) }
        }
    }

    // MARK: 光学

    private var optics: some View {
        Group {
            ParameterSlider(title: "镜头柔化", value: $params.softness) { percent($0) }
            ParameterSlider(title: "色散 / 紫边", value: $params.chromaAberration) { percent($0) }
            ParameterSlider(title: "暗角", value: $params.vignette) { percent($0) }
            ParameterSlider(title: "高光溢出", value: $params.bloom) { percent($0) }
            ParameterSlider(title: "手抖", value: $params.motionBlur) { percent($0) }
            ParameterSlider(title: "机内锐化", value: $params.sharpen) { percent($0) }
            ParameterSlider(title: "漏光", value: $params.lightLeak) { percent($0) }
        }
    }

    // MARK: 色彩

    private var color: some View {
        Group {
            ParameterSlider(title: "色温", value: $params.warmth) {
                $0 < 0.48 ? "偏冷" : ($0 > 0.52 ? "偏暖" : "中性")
            }
            ParameterSlider(title: "对比度", value: $params.contrast, range: 0.85...1.2) {
                String(format: "%.2f", $0)
            }
            ParameterSlider(title: "饱和度", value: $params.saturation, range: 0.7...1.35) {
                String(format: "%.2f", $0)
            }
            ParameterSlider(title: "黑位抬升", value: $params.blackLift) { percent($0) }
            ParameterSlider(title: "高光压缩", value: $params.highlightRolloff) { percent($0) }
            ParameterSlider(title: "曝光", value: $params.exposure, range: -0.4...0.4) {
                String(format: "%+.2fEV", $0)
            }
        }
    }

    // MARK: 画幅

    private var output: some View {
        Group {
            Picker("画幅", selection: $frame) {
                ForEach(FrameMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $trimBars) {
                Text("裁掉状态栏与底部条")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.accent)

            if frame != .original {
                ParameterSlider(title: "构图位置", value: $anchor) {
                    $0 < 0.45 ? "偏下" : ($0 > 0.55 ? "偏上" : "居中")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("输出尺寸")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.subtext)
                Picker("输出尺寸", selection: $longEdge) {
                    Text("原始").tag(0.0)
                    Text("2048").tag(2048.0)
                    Text("3024").tag(3024.0)
                }
                .pickerStyle(.segmented)
            }

            Toggle(isOn: $writeExif) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("写入模拟拍摄信息")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                    Text("机身、镜头、光圈、快门，仅用于风格一致")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                }
            }
            .tint(Theme.accent)

            Text("提示：截图裁 4:3 并去掉状态栏，比调任何滑杆都更有效。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }
}

// MARK: - 预设条

struct PresetStrip: View {
    let selected: CameraPreset
    let onSelect: (CameraPreset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CameraPreset.allCases) { preset in
                    let isOn = preset == selected
                    Button {
                        onSelect(preset)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 14, weight: .medium))
                            Text(preset.title)
                                .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
                        }
                        .foregroundStyle(isOn ? Color.black : Theme.subtext)
                        .frame(width: 66, height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isOn ? Theme.accent : Theme.surfaceRaised)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
