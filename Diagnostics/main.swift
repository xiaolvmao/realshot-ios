import Foundation
import CoreImage
import CoreGraphics

// 管线诊断工具。不在 App 里跑，只在 CI 的 macOS runner 上编译执行。
//
// 目的：当「成片发黑」时，逐级打印均值亮度 + alpha，掉下来的那一级就是元凶。
// 同时把每一级的中间图写成 PNG，作为 artifact 上传，可以直接看。

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "diag-out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
let pngContext = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

/// 一张有亮部、暗部、纯色块、肤色、高饱和色的测试图。
/// 用真实照片更贴近实际情况，但合成图就能定位「整体变黑」这类问题。
func makeTestImage(width: Int, height: Int) -> CIImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // 底：从左下的深灰到右上的浅灰渐变
    let gradient = CGGradient(colorsSpace: srgb, colors: [
        CGColor(colorSpace: srgb, components: [0.06, 0.06, 0.07, 1])!,
        CGColor(colorSpace: srgb, components: [0.92, 0.90, 0.86, 1])!
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                           options: [])

    let w = CGFloat(width), h = CGFloat(height)
    func box(_ x: CGFloat, _ y: CGFloat, _ bw: CGFloat, _ bh: CGFloat, _ c: [CGFloat]) {
        ctx.setFillColor(CGColor(colorSpace: srgb, components: c)!)
        ctx.fill(CGRect(x: x * w, y: y * h, width: bw * w, height: bh * h))
    }

    box(0.06, 0.58, 0.22, 0.30, [1, 1, 1, 1])                 // 纯白：最容易暴露高光裁切
    box(0.34, 0.58, 0.18, 0.30, [0.78, 0.60, 0.48, 1])        // 肤色
    box(0.58, 0.58, 0.16, 0.30, [0.82, 0.16, 0.12, 1])        // 红
    box(0.78, 0.58, 0.16, 0.30, [0.14, 0.42, 0.72, 1])        // 蓝
    box(0.34, 0.18, 0.18, 0.30, [0.20, 0.55, 0.26, 1])        // 绿
    box(0.58, 0.18, 0.36, 0.30, [0.03, 0.03, 0.04, 1])        // 近黑：看黑位抬升
    box(0.06, 0.18, 0.22, 0.30, [0.55, 0.55, 0.55, 1])        // 中灰

    // 几条细线：看色散和锐化
    ctx.setStrokeColor(CGColor(colorSpace: srgb, components: [1, 1, 1, 0.9])!)
    ctx.setLineWidth(max(1, w / 400))
    for i in 0..<12 {
        let x = 0.06 * w + CGFloat(i) * (0.88 * w / 12)
        ctx.move(to: CGPoint(x: x, y: 0.52 * h))
        ctx.addLine(to: CGPoint(x: x, y: 0.56 * h))
    }
    ctx.strokePath()

    let cg = ctx.makeImage()!
    return CIImage(cgImage: cg)
}

func writePNG(_ image: CIImage, to path: String) {
    let e = image.extent
    guard !e.isInfinite, !e.isNull, !e.isEmpty else { return }
    let url = URL(fileURLWithPath: path)
    try? pngContext.writePNGRepresentation(of: image.cropped(to: e.integral),
                                           to: url,
                                           format: .RGBA8,
                                           colorSpace: srgb)
}

let engine = RealismEngine()
let source = makeTestImage(width: 1200, height: 900)

print("sRGB working space: \(srgb.name ?? "?" as CFString)")
print("source extent: \(source.extent)")

var failures = 0

for preset in CameraPreset.allCases {
    var p = preset.baseParameters
    p = p.jittered(seed: 20261109)

    let request = RenderRequest(params: p, frame: .ratio4x3,
                                trimBars: true, anchor: 0.5, longEdge: 0)

    print("\n=== \(preset.rawValue) / \(preset.title) ===")
    print("  grain=\(String(format: "%.2f", p.grain)) soft=\(String(format: "%.2f", p.softness)) "
          + "ca=\(String(format: "%.2f", p.chromaAberration)) vig=\(String(format: "%.2f", p.vignette)) "
          + "bloom=\(String(format: "%.2f", p.bloom)) persp=\(String(format: "%.2f", p.perspective)) "
          + "leak=\(String(format: "%.2f", p.lightLeak)) screen=\(String(format: "%.2f", p.screenTexture)) "
          + "jpegP=\(p.jpegPasses) q=\(String(format: "%.2f", p.jpegQuality))")

    let metrics = engine.trace(source, request: request) { name, img in
        writePNG(img, to: "\(outDir)/\(preset.rawValue)-\(name).png")
    }

    for m in metrics {
        if m.meanR < 0 {
            print("  " + pad(m.name, 24) + "→ 无法采样 / 渲染失败")
            continue
        }
        print("  " + pad(m.name, 24)
              + String(format: "rgb=(%.3f %.3f %.3f) a=%.3f  luma %.3f…%.3f",
                       m.meanR, m.meanG, m.meanB, m.meanA, m.minLuma, m.maxLuma))
    }

    if let last = metrics.last, last.meanR >= 0, last.meanR < 0.03 {
        failures += 1
        print("  ⚠️ 成片均值亮度只有 \(String(format: "%.3f", last.meanR))，基本等于全黑")
    }
}

print("\n总结：\(failures) / \(CameraPreset.allCases.count) 个预设的成片接近全黑")

// MARK: - 单级隔离
//
// 上面那张表已经能看出哪一级掉下来；这里再把每一级单独跑一遍，
// 排除「前一级的坏数据污染后一级」的可能。

func zeroed() -> RealismParameters {
    var p = RealismParameters()
    p.grain = 0
    p.grainSize = 1
    p.chromaNoise = 0
    p.softness = 0
    p.chromaAberration = 0
    p.vignette = 0
    p.bloom = 0
    p.motionBlur = 0
    p.sharpen = 0
    p.vibrance = 0
    p.blackLift = 0
    p.highlightRolloff = 0
    p.perspective = 0
    p.rotation = 0
    p.lightLeak = 0
    p.screenTexture = 0
    p.exposure = 0
    p.contrast = 1
    p.saturation = 1
    p.warmth = 0.5
    p.tint = 0
    p.seed = 777
    return p
}

func show(_ m: RealismEngine.StageMetric) {
    if m.meanR < 0 {
        print("  " + pad(m.name, 26) + "→ 无法采样")
        return
    }
    print("  " + pad(m.name, 26)
          + String(format: "rgb=(%.3f %.3f %.3f) a=%.3f  luma %.3f…%.3f",
                   m.meanR, m.meanG, m.meanB, m.meanA, m.minLuma, m.maxLuma))
}

var cases: [(String, RealismParameters)] = []

cases.append(("baseline 全关", zeroed()))

var c1 = zeroed(); c1.perspective = 0.35; c1.rotation = 0.4
cases.append(("perspective + rotation", c1))

var c2 = zeroed(); c2.bloom = 0.35
cases.append(("bloom", c2))

var c3 = zeroed(); c3.vignette = 0.35
cases.append(("vignette", c3))

var c4 = zeroed(); c4.blackLift = 0.22; c4.highlightRolloff = 0.5
cases.append(("tone curve", c4))

var c5 = zeroed(); c5.chromaAberration = 0.28
cases.append(("chroma aberration", c5))

var c6 = zeroed(); c6.softness = 0.45
cases.append(("gaussian softness", c6))

var c7 = zeroed(); c7.motionBlur = 0.18; c7.motionAngle = 40
cases.append(("motion blur", c7))

var c8 = zeroed(); c8.sharpen = 0.35
cases.append(("sharpen", c8))

var c9 = zeroed(); c9.grain = 0.38
cases.append(("grain only", c9))

var c10 = zeroed(); c10.chromaNoise = 0.22
cases.append(("chroma noise only", c10))

var c11 = zeroed(); c11.grain = 0.38; c11.chromaNoise = 0.22
cases.append(("grain + chroma noise", c11))

var c12 = zeroed(); c12.lightLeak = 0.3
cases.append(("light leak", c12))

var c13 = zeroed(); c13.screenTexture = 0.5
cases.append(("screen texture", c13))

let isoRequest = RenderRequest(params: zeroed(), frame: .ratio4x3,
                               trimBars: true, anchor: 0.5, longEdge: 0)
let isoPrepared = engine.preparedImage(source, request: isoRequest)
print("\n=== 单级隔离（源图均值亮度见 0-source）===")
show(engine.isolate(isoPrepared, stage: .color, params: zeroed()))

for stage in RealismEngine.PipelineStage.allCases {
    print("\n-- \(stage.rawValue) --")
    for (label, params) in cases {
        var m = engine.isolate(isoPrepared, stage: stage, params: params)
        m.name = label
        show(m)
    }
}

print("\n中间图已写入 \(outDir)")
