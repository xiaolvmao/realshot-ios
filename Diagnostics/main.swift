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

// 注意：这里写出的 PNG 只用来“看大致画面”，不能用来判断真实亮度。
// 中间阶段的 CIImage 处在扩展线性工作空间，writePNGRepresentation(colorSpace: srgb)
// 不会做线性→sRGB 编码，于是 4-optics ~ 7-pipeline 的图看起来偏暗（实测 YAVG 0.125，
// 而同一份像素经 makeCGImage 编码后是 0.369）。判断真实亮度请看 *-8-cgimage.png
// 与 *-9-jpeg.png，那才是用户拿到的成片。
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
    print("  grain=\(String(format: "%.2f", p.grain)) size=\(String(format: "%.2f", p.grainSize)) "
          + "soft=\(String(format: "%.2f", p.softness)) "
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

// MARK: - JPEG 往返
//
// 单独验一次：一张 50% 灰编码成 JPEG 再解码，应该还是 0.5。
// 如果掉到 0.25 或 0.17，说明问题不在滤镜，而在编码/色彩空间。

func grayImage(_ v: CGFloat, width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(colorSpace: srgb, components: [v, v, v, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

print("\n=== JPEG 往返 ===")
for v in [0.25, 0.5, 0.75] {
    guard let gray = grayImage(CGFloat(v), width: 256, height: 256) else { continue }
    show(engine.debugMeasure("gray-in \(v)", CIImage(cgImage: gray)))
    if let enc = JpegDegrader.encode(gray, quality: 0.85),
       let dec = JpegDegrader.decode(enc) {
        show(engine.debugMeasure("gray-after-jpeg \(v)", CIImage(cgImage: dec)))
        print("     colorspace=\(String(describing: dec.colorSpace?.name)) "
              + "bits=\(dec.bitsPerComponent) alpha=\(dec.alphaInfo.rawValue)")
    }
}
//
// 上面已经定位到 sensor 这一级。这里把「真实链路输入 + 各种参数组合」逐一测一遍，
// 确认是颗粒、色噪，还是 grainSize 触发的模糊路径。

let phoneParams = CameraPreset.phone.baseParameters.jittered(seed: 20261109)
let fixRequest = RenderRequest(params: phoneParams, frame: .ratio4x3,
                               trimBars: true, anchor: 0.5, longEdge: 0)
let fixPrepared = engine.preparedImage(source, request: fixRequest)
let opticsOut = engine.chained(fixPrepared, upTo: .optics, params: phoneParams)

print("\n=== 定点排查：phone 真实链路 ===")
print("  grain=\(String(format: "%.3f", phoneParams.grain)) "
      + "grainSize=\(String(format: "%.3f", phoneParams.grainSize)) "
      + "chromaNoise=\(String(format: "%.3f", phoneParams.chromaNoise))")

var m0 = engine.isolate(opticsOut, stage: .sensor, params: phoneParams)
m0.name = "sensor(原参数)"
show(m0)

print("  -- 噪点图层本身（加性图层：均值应接近 0，alpha 1）--")
for m in engine.debugNoiseLayers(opticsOut, params: phoneParams) { show(m) }

print("  -- 变量控制 --")
var v1 = phoneParams; v1.grainSize = 1.0
var v2 = phoneParams; v2.grain = 0
var v3 = phoneParams; v3.chromaNoise = 0
var v4 = phoneParams; v4.grainSize = 1.0; v4.chromaNoise = 0
var v5 = phoneParams; v5.grainSize = 1.0; v5.grain = 0

let variants: [(String, RealismParameters)] = [
    ("grainSize=1.0", v1),
    ("只颗粒 grain=0", v2),
    ("只色噪 chroma=0", v3),
    ("grainSize=1 & chroma=0", v4),
    ("grainSize=1 & grain=0", v5)
]
for (label, pp) in variants {
    var m = engine.isolate(opticsOut, stage: .sensor, params: pp)
    m.name = label
    show(m)
}

func constant(_ v: CGFloat, like image: CIImage) -> CIImage {
    CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1)).cropped(to: image.extent)
}

print("  -- 混合语义（源图层为纯色，背景为 optics 输出）--")
var bm = engine.debugBlend("CISoftLightBlendMode", source: constant(0.5, like: opticsOut), background: opticsOut)
bm.name = "softlight 中灰 0.50"
show(bm)
bm = engine.debugBlend("CIOverlayBlendMode", source: constant(0.5, like: opticsOut), background: opticsOut)
bm.name = "overlay 中灰 0.50"
show(bm)
bm = engine.debugBlend("CISoftLightBlendMode", source: constant(0.0, like: opticsOut), background: opticsOut)
bm.name = "softlight 黑 0.00"
show(bm)
bm = engine.debugBlend("CIOverlayBlendMode", source: constant(0.0, like: opticsOut), background: opticsOut)
bm.name = "overlay 黑 0.00"
show(bm)

// 用真实的噪点图层做一次混合，看是不是图层本身的问题
print("  -- 真实噪点图层 --")
for (kind, layer) in engine.noiseLayerImages(opticsOut, params: phoneParams) {
    var lm = engine.debugMeasure("layer-" + kind, layer)
    show(lm)
    let mode = kind == "grain" ? "CISoftLightBlendMode" : "CIOverlayBlendMode"
    var bm2 = engine.debugBlend(mode, source: layer, background: opticsOut)
    bm2.name = kind + " over optics"
    show(bm2)
}

// MARK: - 随机种子（批量页「单张随机 / 全部随机」是否生效）
//
// 两个重掷按钮本质上只做一件事：把该张的 seed 换成一个随机数。
// 能不能“生效”取决于两件事，各测一次：
//   1. 不同 seed → 参数不同 → 渲染结果不同（RMS 应明显 > 0）
//   2. 同一 seed 重复渲染 → 结果完全一致（RMS 应为 0，预览才代表最终保存的那张）
// 这里直接用真机上的调用路径 engine.makeFinal，不另写一条渲染链。

func bitmap(_ cg: CGImage) -> [UInt8]? {
    let w = cg.width, h = cg.height
    guard w > 1, h > 1 else { return nil }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = buf.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? buf : nil
}

/// 两张同尺寸成片的像素差：RMS（0…1）、单通道最大差、有变化的像素占比。
func pixelStats(_ a: CGImage, _ b: CGImage) -> (rms: Double, maxDelta: Int, changed: Double)? {
    guard a.width == b.width, a.height == b.height,
          let A = bitmap(a), let B = bitmap(b) else { return nil }
    let n = a.width * a.height
    var sum = 0.0
    var maxDelta = 0
    var changed = 0
    for i in 0..<n {
        let o = i * 4
        var local = 0
        for c in 0..<3 {
            let d = abs(Int(A[o + c]) - Int(B[o + c]))
            sum += Double(d * d)
            if d > local { local = d }
        }
        if local > 0 { changed += 1 }
        if local > maxDelta { maxDelta = local }
    }
    return (rms: (sum / Double(n * 3)).squareRoot() / 255.0,
            maxDelta: maxDelta,
            changed: Double(changed) / Double(n))
}

print("\n=== 随机种子（批量页「单张随机 / 全部随机」）===")

let jitterBase = CameraPreset.phone.baseParameters
print("  基准参数 grain=\(String(format: "%.2f", jitterBase.grain)) "
      + "size=\(String(format: "%.2f", jitterBase.grainSize)) "
      + "chroma=\(String(format: "%.2f", jitterBase.chromaNoise)) "
      + "vig=\(String(format: "%.2f", jitterBase.vignette)) "
      + "exposure=\(String(format: "%+.2f", jitterBase.exposure))")

func seededRequest(_ seed: UInt64) -> RenderRequest {
    RenderRequest(params: jitterBase.jittered(seed: seed),
                  frame: .ratio4x3, trimBars: true, anchor: 0.5, longEdge: 0)
}

var seededRenders: [(seed: UInt64, image: CGImage)] = []
for seed in [UInt64(2026), UInt64(2027), UInt64(2028)] {
    let p = jitterBase.jittered(seed: seed)
    print(String(format: "  seed %llu  grain=%.3f size=%.2f chroma=%.3f vig=%.3f "
                 + "bloom=%.3f exposure=%+.3f warmth=%.3f rot=%+.2f",
                 seed, p.grain, p.grainSize, p.chromaNoise, p.vignette,
                 p.bloom, p.exposure, p.warmth, p.rotation))

    if let cg = engine.makeFinal(source, request: seededRequest(seed)) {
        seededRenders.append((seed, cg))
        writePNG(CIImage(cgImage: cg), to: "\(outDir)/seed-\(seed).png")
    } else {
        print("  ⚠️ seed \(seed) 渲染失败")
    }
}

var rerollOK = 0
var rerollChecked = 0
if seededRenders.count >= 2 {
    let first = seededRenders[0]
    for other in seededRenders.dropFirst() {
        guard let st = pixelStats(first.image, other.image) else { continue }
        rerollChecked += 1
        let changed = st.rms > 0.004 && st.changed > 0.15
        if changed { rerollOK += 1 }
        print(String(format: "  seed %llu vs %llu → RMS %.2f%%  maxΔ %3d  变化像素 %.1f%%  %@",
                     first.seed, other.seed, st.rms * 100, st.maxDelta, st.changed * 100,
                     changed ? "✓ 画面确实变了" : "✗ 几乎一模一样"))
    }

    // 同种子重渲染：必须逐像素一致，否则「预览 = 保存」这个承诺就不成立
    if let again = engine.makeFinal(source, request: seededRequest(first.seed)),
       let st = pixelStats(first.image, again) {
        print(String(format: "  同种子重复渲染 → RMS %.2f%%  maxΔ %d  %@",
                     st.rms * 100, st.maxDelta,
                     st.maxDelta == 0 ? "✓ 完全一致（可复现）" : "✗ 不一致（预览与最终保存会不同）"))
    }
}

print("  小结：\(rerollOK) / \(rerollChecked) 组不同种子产生了可见差异")
