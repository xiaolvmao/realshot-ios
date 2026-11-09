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

// MARK: - 曝光 EV（色彩 tab 的「曝光」滑杆）是否真的起作用
//
// 代码里 abs(exposure) <= 0.005 会整段跳过 CIExposureAdjust，
// 所以取 0 时这个节点根本不执行 —— 界面上看着像“空”的原因就在这里。
// 这里按档位扫一遍，量出平均亮度的实际变化。

func meanLuma(_ cg: CGImage) -> Double? {
    guard let b = bitmap(cg) else { return nil }
    let n = cg.width * cg.height
    var sum = 0.0
    for i in 0..<n {
        let o = i * 4
        sum += 0.2126 * Double(b[o]) + 0.7152 * Double(b[o + 1]) + 0.0722 * Double(b[o + 2])
    }
    return sum / Double(n) / 255.0
}

print("\n=== 曝光 EV（色彩 → 曝光）===")

// 先做一次 jitter，再把 exposure 钉死，避免随机量混进来
var evBase = CameraPreset.phone.baseParameters.jittered(seed: 20261109)
evBase.exposure = 0

var evTable: [(ev: Double, mean: Double)] = []
for ev in [-0.4, -0.2, 0.0, 0.2, 0.4] {
    var p = evBase
    p.exposure = ev
    let request = RenderRequest(params: p, frame: .ratio4x3,
                                trimBars: true, anchor: 0.5, longEdge: 0)
    guard let cg = engine.makeFinal(source, request: request),
          let mean = meanLuma(cg) else {
        print(String(format: "  %+.1fEV → 渲染失败", ev))
        continue
    }
    evTable.append((ev, mean))
    writePNG(CIImage(cgImage: cg), to: "\(outDir)/ev-\(ev).png")
}

if let zero = evTable.first(where: { abs($0.ev) < 0.001 })?.mean {
    for row in evTable {
        print(String(format: "  %+.1fEV → 平均亮度 %.4f  (%+.1f%%)",
                     row.ev, row.mean, (row.mean / zero - 1) * 100))
    }
    // 线性空间里 +1EV 应该正好亮一倍，这里换成等价的倍数看一眼
    for row in evTable where abs(row.ev) > 0.001 {
        let ratio = pow(2.0, row.ev)
        print(String(format: "  %+.1fEV 理论增益 ×%.2f，线性光等效 ×%.2f",
                     row.ev, ratio, row.mean / zero))
    }
}

// MARK: - 参数区间断言
//
// 参数越界在 Core Image 里不会报错，只会悄悄算出异常画面。
// 之前「成片全黑」就是这一类问题的变种，所以进渲染前必须夹一遍、
// 并且在这里用断言把口子堵住，别再靠肉眼发现。

print("\n=== 参数区间 ===")

func outOfRange(_ p: RealismParameters) -> [String] {
    var bad: [String] = []
    func check(_ name: String, _ v: Double, _ lo: Double, _ hi: Double) {
        if v < lo - 1e-9 || v > hi + 1e-9 {
            bad.append("\(name)=\(String(format: "%.3f", v)) 不在 \(lo)…\(hi)")
        }
    }
    check("grain", p.grain, 0, 1)
    check("grainSize", p.grainSize, 0.8, 2.4)
    check("chromaNoise", p.chromaNoise, 0, 0.9)
    check("jpegQuality", p.jpegQuality, 0.45, 0.95)
    check("jpegPasses", Double(p.jpegPasses), 0, 3)
    check("softness", p.softness, 0, 1)
    check("chromaAberration", p.chromaAberration, 0, 0.9)
    check("vignette", p.vignette, 0, 0.9)
    check("bloom", p.bloom, 0, 0.9)
    check("motionBlur", p.motionBlur, 0, 0.6)
    check("sharpen", p.sharpen, 0, 0.9)
    check("warmth", p.warmth, 0.2, 0.8)
    check("tint", p.tint, -0.1, 0.1)
    check("exposure", p.exposure, -0.4, 0.4)
    check("contrast", p.contrast, 0.85, 1.2)
    check("saturation", p.saturation, 0.7, 1.35)
    check("vibrance", p.vibrance, -0.1, 0.3)
    check("blackLift", p.blackLift, 0, 0.7)
    check("highlightRolloff", p.highlightRolloff, 0, 0.9)
    check("rotation", p.rotation, -1, 1)
    check("perspective", p.perspective, 0, 0.8)
    check("lightLeak", p.lightLeak, 0, 0.9)
    check("screenTexture", p.screenTexture, 0, 0.9)
    return bad
}

// 1. 极端输入过一遍 clamped()
var wild = CameraPreset.phone.baseParameters
wild.grain = 99
wild.exposure = 12
wild.jpegQuality = -3
wild.jpegPasses = 9
wild.contrast = 40
let wildBad = outOfRange(wild.clamped())
print("  极端输入 → clamped 后越界：\(wildBad.isEmpty ? "无 ✓" : wildBad.joined(separator: "；"))")

// 2. 每个预设 × 200 个种子，jitter 后的值都必须在区间内
var badSeeds = 0
var checkedSeeds = 0
for preset in CameraPreset.allCases {
    for seed in UInt64(1)...UInt64(200) {
        let p = preset.baseParameters.jittered(seed: seed)
        checkedSeeds += 1
        if !outOfRange(p).isEmpty { badSeeds += 1 }
    }
}
print("  \(checkedSeeds) 组随机扰动 → 越界 \(badSeeds) 组 \(badSeeds == 0 ? "✓" : "✗")")

// MARK: - 画幅裁切（水平位置 / 向内缩放）
//
// 这两个滑杆是这次新加的，必须验证它们真的改变了输出，
// 而不是「界面上有、实际没接进管线」。

print("\n=== 画幅裁切（水平位置 / 向内缩放）===")

// 4:3 画幅下，1600×900 的源图会被裁掉左右，正好用来测水平位置
let wideSource = makeTestImage(width: 1600, height: 900)
let cropBase = CameraPreset.phone.baseParameters.jittered(seed: 20261109)

func cropped(_ x: Double, _ scale: Double) -> CGImage? {
    let request = RenderRequest(params: cropBase,
                                frame: .ratio4x3,
                                trimBars: false,
                                anchor: 0.5,
                                cropX: x,
                                cropScale: scale,
                                longEdge: 0)
    return engine.makeFinal(wideSource, request: request)
}

let centerCrop = cropped(0.5, 1.0)
let leftCrop = cropped(0.0, 1.0)
let rightCrop = cropped(1.0, 1.0)
let zoomCrop = cropped(0.5, 2.0)

if let centerCrop {
    print("  水平居中 · 缩放 1.0 → \(centerCrop.width) × \(centerCrop.height)")
}
if let zoomCrop {
    print("  水平居中 · 缩放 2.0 → \(zoomCrop.width) × \(zoomCrop.height)")
}

if let leftCrop, let rightCrop, let st = pixelStats(leftCrop, rightCrop) {
    print(String(format: "  左对齐 vs 右对齐 → RMS %.2f%%  变化像素 %.1f%%  %@",
                 st.rms * 100, st.changed * 100,
                 (st.rms > 0.004 && st.changed > 0.15) ? "✓ 位置确实变了" : "✗ 没动"))
}

if let centerCrop, let zoomCrop {
    let ratio = Double(zoomCrop.width) / Double(centerCrop.width)
    print(String(format: "  缩放 2.0 后的宽度比 %.3f  %@", ratio,
                 abs(ratio - 0.5) < 0.04 ? "✓ 约为一半" : "✗ 不符合预期"))
}

// 把两种对齐的样张留下来，肉眼也能确认裁的是不同的一边
if let leftCrop { writePNG(CIImage(cgImage: leftCrop), to: "\(outDir)/crop-left.png") }
if let rightCrop { writePNG(CIImage(cgImage: rightCrop), to: "\(outDir)/crop-right.png") }

// MARK: - 撤回 / 恢复
//
// 两个页面共用同一个 ReversibleHistory，这里直接测它的语义：
// 记一步 → 撤回 → 恢复，状态必须回到原位；撤回之后再操作要截断 redo 分支。
// 界面上这两次点击是不是真的调到了这里，靠 CI 编译 + 下面的断言一起看。

print("\n=== 撤回 / 恢复 ===")

var hist = ReversibleHistory<Int>(limit: 3)
var state = 0
func remember() { hist.record(state) }
func stepBack() { if let s = hist.undo(current: state) { state = s } }
func stepForward() { if let s = hist.redo(current: state) { state = s } }

print("  初始：canUndo=\(hist.canUndo)  canRedo=\(hist.canRedo)  "
      + ((!hist.canUndo && !hist.canRedo) ? "✓ 两个按钮都是灰的" : "✗"))

remember(); state = 1
remember(); state = 2
print("  记两步后 state=\(state)  canUndo=\(hist.canUndo)  canRedo=\(hist.canRedo)  "
      + ((state == 2 && hist.canUndo && !hist.canRedo) ? "✓ 只能撤回" : "✗"))

stepBack()
print("  撤回一次 → state=\(state)  "
      + ((state == 1 && hist.canUndo && hist.canRedo) ? "✓ 撤回后恢复可用" : "✗"))

stepBack()
print("  再撤回一次 → state=\(state)  "
      + ((state == 0 && !hist.canUndo && hist.canRedo) ? "✓ 退到头了" : "✗"))

stepForward()
stepForward()
print("  连续恢复两次 → state=\(state)  "
      + ((state == 2 && hist.canUndo && !hist.canRedo) ? "✓ 回到原处" : "✗"))

stepForward()
print("  没有可恢复的再点恢复 → state=\(state)  "
      + (state == 2 ? "✓ 不越界" : "✗ 状态被改坏了"))

stepBack()          // 现在 state 应该是 1
remember(); state = 9
print("  撤回后做新操作 → canRedo=\(hist.canRedo)  "
      + (hist.canRedo ? "✗ redo 分支没被截断" : "✓ redo 分支已清空"))

// 深度上限：limit=3，连记 5 步后 past 只留最近 3 步
var deep = ReversibleHistory<Int>(limit: 3)
for i in 0..<5 { deep.record(i) }
print("  上限 3 连记 5 步 → 可撤回 \(deep.undoDepth) 步  "
      + (deep.undoDepth == 3 ? "✓ 按上限截断" : "✗ 没截断"))

// 编辑器 / 批量页的参数快照是可拷贝的值类型：撤回后继续改参数不会污染历史里的那份
let snapBase = CameraPreset.phone.baseParameters
let snapHistory = snapBase
var live = snapHistory
live.grain = 0.05
print("  快照与实时参数互不影响  "
      + (snapBase.grain > 0.2 && live.grain == 0.05 ? "✓ 值类型语义正常" : "✗ 快照被改动了"))

// MARK: - 追加照片吃的是「当前参数 + 自己的种子」
//
// 全屏查看器里的加号把新图追加到队尾，预览 / 导出都会重新取当前 params
// 再按该张自己的 seed 扰动。这里把这条链路的三个前提各测一遍。

print("\n=== 追加照片的参数 ===")

let addBase = CameraPreset.phone.baseParameters.clamped()
let seedNew: UInt64 = 20261109

let firstTry = addBase.jittered(seed: seedNew)
let again = addBase.jittered(seed: seedNew)
print("  同一张同一种子两次 → \(firstTry == again ? "✓ 完全一致（预览 = 保存）" : "✗ 不一致")")
print("  种子写进了参数 → 参数 seed=\(firstTry.seed)  \(firstTry.seed == seedNew ? "✓" : "✗")")

// 换了基准参数（模拟用户刚拖过滑杆），同一种子必须跟着变
var brighter = addBase
brighter.exposure = 0.30
brighter.grain = 0.90
let afterEdit = brighter.clamped().jittered(seed: seedNew)
let moved = abs(afterEdit.grain - firstTry.grain) > 0.2 && afterEdit.exposure > firstTry.exposure
print(String(format: "  基准 grain %.2f→%.2f  曝光 %+.2f→%+.2f  %@",
             firstTry.grain, afterEdit.grain,
             firstTry.exposure, afterEdit.exposure,
             moved ? "✓ 新参数确实生效" : "✗ 还在用旧参数"))

// 队伍里每张的种子不同 → 同一套参数也不会刷出 N 份一模一样的颗粒
var distinctSeeds = Set<UInt64>()
var distinctGrain = Set<Int>()
for i in 0..<20 {
    let p = addBase.jittered(seed: seedNew &+ UInt64(i))
    distinctSeeds.insert(p.seed)
    distinctGrain.insert(Int((p.grain * 1000).rounded()))
}
print("  20 张不同种子 → 参数种子 \(distinctSeeds.count) 种、颗粒 \(distinctGrain.count) 档  "
      + ((distinctSeeds.count == 20 && distinctGrain.count >= 15) ? "✓ 各不相同" : "✗ 撞车太多"))
