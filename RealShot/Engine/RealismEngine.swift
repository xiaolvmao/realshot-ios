import CoreImage
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

struct RenderRequest {
    var params: RealismParameters
    var frame: FrameMode
    var trimBars: Bool
    var anchor: Double
    /// 0 表示保持原始像素尺寸
    var longEdge: CGFloat
}

/// 真实感渲染管线。
///
/// 顺序刻意模拟光线进入相机的物理链路：
///
///   几何（倾斜/透视/重采样）
///     → 色彩（白平衡、色调曲线、暗角）
///     → 光学（色散、手抖、镜头柔化、机内锐化）
///     → 传感器（颗粒、彩噪）
///     → 场景（漏光、屏幕网格）
///     → 压缩（JPEG 往返）
///
/// 任何一步单独做都骗不过眼睛，必须叠在一起。
final class RealismEngine: @unchecked Sendable {

    private let srgb: CGColorSpace
    private let context: CIContext

    init() {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        srgb = space
        context = CIContext(options: [
            .workingColorSpace: space,
            .outputColorSpace: space,
            .cacheIntermediates: false
        ])
    }

    // MARK: - 对外接口

#if canImport(UIKit)
    /// 预览：同时返回「加效果前」和「加效果后」，两者构图完全一致，
    /// 这样对比滑块才不会错位。
    func makeComparison(_ image: CIImage,
                        request: RenderRequest,
                        maxDimension: CGFloat) -> (before: UIImage, after: UIImage)? {
        let prepared = prepare(image, request: request, maxDimension: maxDimension)
        let rect = prepared.extent.integral
        guard rect.width > 4, rect.height > 4,
              let beforeCG = context.createCGImage(prepared, from: rect, format: .RGBA8, colorSpace: srgb),
              let afterCG = render(prepared, params: request.params) else { return nil }
        return (before: UIImage(cgImage: beforeCG), after: UIImage(cgImage: afterCG))
    }
#endif

    /// 导出：全尺寸渲染，返回 CGImage，交给 ExifWriter 打包。
    func makeFinal(_ image: CIImage, request: RenderRequest) -> CGImage? {
        let prepared = prepare(image, request: request, maxDimension: request.longEdge)
        return render(prepared, params: request.params)
    }

    // MARK: - 管线自检

    /// 一次渲染中某一级的统计量。用于在 CI 上定位「成片发黑」这类问题：
    /// 逐级打印均值，掉下来的那一步就是元凶。
    struct StageMetric {
        var name: String
        var meanR: Double
        var meanG: Double
        var meanB: Double
        var meanA: Double
        var minLuma: Double
        var maxLuma: Double
    }

    /// 逐级跑一遍管线并测亮度/alpha。不参与 App 运行时逻辑，只在诊断工具里用。
    func trace(_ image: CIImage,
               request: RenderRequest,
               sampleDimension: CGFloat = 640,
               onStage: ((String, CIImage) -> Void)? = nil) -> [StageMetric] {
        var out: [StageMetric] = []

        func step(_ name: String, _ img: CIImage) {
            onStage?(name, img)
            out.append(measure(name, img))
        }

        step("0-source", image)
        let prepared = prepare(image, request: request, maxDimension: sampleDimension)
        step("1-prepared", prepared)
        var img = geometry(prepared, params: request.params)
        step("2-geometry", img)
        img = color(img, params: request.params)
        step("3-color", img)
        img = optics(img, params: request.params)
        step("4-optics", img)
        img = sensor(img, params: request.params)
        step("5-sensor", img)
        img = scene(img, params: request.params)
        step("6-scene", img)

        // 编码链单独测：光栅化一步、JPEG 往返一步
        let piped = pipelineImage(prepared, params: request.params)
        step("7-pipeline", piped)
        if let cg = makeCGImage(piped, fallbackExtent: prepared.extent) {
            step("8-cgimage", CIImage(cgImage: cg))
            let jpg = JpegDegrader.degrade(cg, quality: request.params.jpegQuality,
                                           passes: request.params.jpegPasses)
            step("9-jpeg", CIImage(cgImage: jpg))
        } else {
            out.append(StageMetric(name: "8-cgimage NIL", meanR: -1, meanG: -1, meanB: -1,
                                   meanA: -1, minLuma: -1, maxLuma: -1))
        }
        return out
    }

    /// 管线里的单级，用于「只跑这一步」的隔离测试。
    enum PipelineStage: String, CaseIterable {
        case geometry, color, optics, sensor, scene
    }

    /// 只对准备好的图跑预处理（裁剪 / 重采样 / 破坏像素）。
    func preparedImage(_ image: CIImage, request: RenderRequest, sampleDimension: CGFloat = 640) -> CIImage {
        prepare(image, request: request, maxDimension: sampleDimension)
    }

    /// 单独跑某一级，用来确认是哪一步把画面弄黑的。
    func isolate(_ prepared: CIImage, stage: PipelineStage, params p: RealismParameters) -> StageMetric {
        measure("only-" + stage.rawValue, applyStage(stage, to: prepared, params: p))
    }

    /// 从准备好的图开始顺序跑，停在指定级（含）。诊断时用来拿到「真实链路输入」。
    func chained(_ prepared: CIImage, upTo stage: PipelineStage, params p: RealismParameters) -> CIImage {
        var img = prepared
        for s in PipelineStage.allCases {
            img = applyStage(s, to: img, params: p)
            if s == stage { break }
        }
        return img
    }

    private func applyStage(_ stage: PipelineStage, to image: CIImage, params p: RealismParameters) -> CIImage {
        switch stage {
        case .geometry: return geometry(image, params: p)
        case .color: return color(image, params: p)
        case .optics: return optics(image, params: p)
        case .sensor: return sensor(image, params: p)
        case .scene: return scene(image, params: p)
        }
    }

    private func measure(_ name: String, _ image: CIImage) -> StageMetric {
        let e = image.extent
        let rect = (e.isInfinite || e.isNull || e.isEmpty)
            ? CGRect(x: 0, y: 0, width: 640, height: 480)
            : e.integral

        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
        guard w > 0, h > 0, w * h <= 4_000_000 else {
            return StageMetric(name: name + " (extent \(Int(rect.width))x\(Int(rect.height)) skip)",
                               meanR: -1, meanG: -1, meanB: -1, meanA: -1, minLuma: -1, maxLuma: -1)
        }

        var bitmap = [UInt8](repeating: 0, count: w * h * 4)
        bitmap.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: w * 4,
                           bounds: rect, format: .RGBA8, colorSpace: srgb)
        }

        var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0
        var minL = 1.0, maxL = 0.0
        let n = Double(w * h)
        var i = 0
        while i < bitmap.count {
            let r = Double(bitmap[i]) / 255.0
            let g = Double(bitmap[i + 1]) / 255.0
            let b = Double(bitmap[i + 2]) / 255.0
            let a = Double(bitmap[i + 3]) / 255.0
            sr += r; sg += g; sb += b; sa += a
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if l < minL { minL = l }
            if l > maxL { maxL = l }
            i += 4
        }
        return StageMetric(name: name, meanR: sr / n, meanG: sg / n, meanB: sb / n,
                           meanA: sa / n, minLuma: minL, maxLuma: maxL)
    }

    // MARK: - 预处理

    private func prepare(_ image: CIImage, request: RenderRequest, maxDimension: CGFloat) -> CIImage {
        var img = FrameAdapter.apply(image,
                                     frame: request.frame,
                                     trimBars: request.trimBars,
                                     anchor: request.anchor)

        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))

        var extent = img.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 1 else { return img }

        if maxDimension > 1 {
            // 上采样上限 2 倍：再高只会把图放大成一团糊
            let scale = min(maxDimension / longEdge, 2.0)
            if abs(scale - 1) > 0.01 {
                img = resample(img, scale: scale)
                extent = img.extent
            }
        }

        // 降采样再升采样，专门用来破坏截图那种“像素级绝对锐利”的边。
        let breakFactor: CGFloat = longEdge > 1600 ? 0.72 : 0.84
        img = breakPixels(img, factor: breakFactor, extent: extent)
        return img
    }

    private func resample(_ image: CIImage, scale: CGFloat) -> CIImage {
        guard abs(scale - 1) > 0.001,
              let f = CIFilter(name: "CILanczosScaleTransform") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let out = f.outputImage else { return image }
        let e = image.extent
        let rect = CGRect(x: e.minX * scale,
                          y: e.minY * scale,
                          width: e.width * scale,
                          height: e.height * scale).integral
        return out.cropped(to: rect)
    }

    private func breakPixels(_ image: CIImage, factor: CGFloat, extent: CGRect) -> CIImage {
        guard extent.width > 320, factor < 0.98, factor > 0.3 else { return image }
        let down = resample(image, scale: factor)
        let up = resample(down, scale: 1 / factor)
        return up.cropped(to: extent)
    }

    // MARK: - 主链路

    private func render(_ input: CIImage, params p: RealismParameters) -> CGImage? {
        let img = pipelineImage(input, params: p)
        guard let cg = makeCGImage(img, fallbackExtent: input.extent) else { return nil }
        // 最后一步：真实的有损压缩
        return JpegDegrader.degrade(cg, quality: p.jpegQuality, passes: p.jpegPasses)
    }

    /// 几何 → 色彩 → 光学 → 传感器 → 场景，不含编码。
    func pipelineImage(_ input: CIImage, params p: RealismParameters) -> CIImage {
        var img = input
        img = geometry(img, params: p)
        img = color(img, params: p)
        img = optics(img, params: p)

        // 混噪点前先记下亮度。混合环节一旦出问题（图层半透明、设备上语义差异），
        // 整幅图会被压成黑图。宁可这一张少点颗粒，也不能给用户一张全黑的照片。
        let preSensor = img
        let sensorOut = sensor(img, params: p)
        if p.grain > 0.005 || p.chromaNoise > 0.005 {
            let before = meanLuma(preSensor)
            let after = meanLuma(sensorOut)
            img = (before > 0.02 && after < before * 0.45) ? preSensor : sensorOut
        } else {
            img = sensorOut
        }

        return scene(img, params: p)
    }

    /// 光栅化。抽出来是为了能单独测「CGImage 这一步」有没有掉亮度。
    func makeCGImage(_ image: CIImage, fallbackExtent: CGRect) -> CGImage? {
        var rect = image.extent
        if !rect.isInfinite && !rect.isNull {
            rect = rect.integral
        } else {
            rect = fallbackExtent.integral
        }
        guard rect.width > 4, rect.height > 4 else { return nil }
        return context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: srgb)
    }

    // MARK: - 几何

    private func geometry(_ input: CIImage, params p: RealismParameters) -> CIImage {
        var img = input
        let extent = img.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)

        guard p.rotation != 0 || p.perspective > 0.001 else { return img }

        var rng = SeededGenerator(seed: p.seed &+ 7)

        if abs(p.rotation) > 0.001 {
            let angle = p.rotation * .pi / 180
            let toOrigin = CGAffineTransform(translationX: -center.x, y: -center.y)
            let back = CGAffineTransform(translationX: center.x, y: center.y)
            let t = toOrigin
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(back)
            img = img.clampedToExtent().transformed(by: t).cropped(to: extent)
        }

        if p.perspective > 0.001 {
            let unit = min(extent.width, extent.height)
            let maxShift = unit * 0.018 * CGFloat(p.perspective)
            func shift() -> CGFloat { CGFloat.random(in: -maxShift...maxShift, using: &rng) }
            let rect = CGRect(x: extent.minX + shift(),
                              y: extent.minY + shift(),
                              width: extent.width + shift(),
                              height: extent.height + shift())
            let corners: [String: Any] = [
                "inputTopLeft": CIVector(x: rect.minX, y: rect.maxY),
                "inputTopRight": CIVector(x: rect.maxX, y: rect.maxY),
                "inputBottomLeft": CIVector(x: rect.minX, y: rect.minY),
                "inputBottomRight": CIVector(x: rect.maxX, y: rect.minY)
            ]
            img = apply("CIPerspectiveTransform", img.clampedToExtent(), corners).cropped(to: extent)
        }

        return img
    }

    // MARK: - 色彩

    private func color(_ input: CIImage, params p: RealismParameters) -> CIImage {
        var img = input
        let extent = img.extent
        let unit = max(extent.width, extent.height) / 1200.0

        // 白平衡漂移。真实相机永远有几百 K 的偏差。
        // 目标色温低于 6500K 时会向暖端偏。
        let tempShift = (p.warmth - 0.5) * 2200.0
        let tintShift = p.tint * 45.0
        img = apply("CITemperatureAndTint", img, [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: CGFloat(6500 - tempShift), y: CGFloat(tintShift))
        ])

        if abs(p.exposure) > 0.005 {
            img = apply("CIExposureAdjust", img, [kCIInputEVKey: p.exposure])
        }

        // 高光溢出：把死白的纯色块变得有“溢流感”
        if p.bloom > 0.01 {
            img = apply("CIBloom", img, [
                kCIInputRadiusKey: 9.0 * unit,
                kCIInputIntensityKey: p.bloom * 0.85
            ]).cropped(to: extent)
        }

        img = apply("CIColorControls", img, [
            kCIInputSaturationKey: p.saturation,
            kCIInputContrastKey: p.contrast,
            kCIInputBrightnessKey: 0.0
        ])

        if abs(p.vibrance) > 0.005 {
            img = apply("CIVibrance", img, [kCIInputAmountKey: p.vibrance])
        }

        // 色调曲线：抬黑位 + 压高光。这是胶片感和“非数码味”的核心。
        let lift = CGFloat(p.blackLift * 0.10)
        let roll = CGFloat(p.highlightRolloff * 0.05)
        img = apply("CIToneCurve", img, [
            "inputPoint0": CIVector(x: 0.0, y: lift),
            "inputPoint1": CIVector(x: 0.25, y: 0.25 + lift * 0.55),
            "inputPoint2": CIVector(x: 0.5, y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: 0.75 - roll * 0.18),
            "inputPoint4": CIVector(x: 1.0, y: 1.0 - roll)
        ])

        // 暗角：光学缺陷，压在噪点之前
        if p.vignette > 0.01 {
            img = apply("CIVignetteEffect", img, [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius": min(extent.width, extent.height) * 0.70,
                "inputIntensity": min(p.vignette * 0.9, 0.85),
                "inputFalloff": 0.45
            ]).cropped(to: extent)
        }

        return img
    }

    // MARK: - 光学

    private func optics(_ input: CIImage, params p: RealismParameters) -> CIImage {
        var img = input
        let extent = img.extent
        let unit = max(extent.width, extent.height) / 1200.0

        // 色散：红蓝通道以画面中心为原点做微小错位
        if p.chromaAberration > 0.005 {
            img = chromaSplit(img, amount: p.chromaAberration * 0.0028, extent: extent)
        }

        // 手抖
        if p.motionBlur > 0.005 {
            img = apply("CIMotionBlur", img.clampedToExtent(), [
                kCIInputRadiusKey: CGFloat(p.motionBlur * 2.4) * unit,
                kCIInputAngleKey: p.motionAngle * .pi / 180
            ]).cropped(to: extent)
        }

        // 镜头柔化
        if p.softness > 0.005 {
            img = apply("CIGaussianBlur", img.clampedToExtent(), [
                kCIInputRadiusKey: CGFloat(p.softness * 1.7) * unit
            ]).cropped(to: extent)
        }

        // 机内锐化：柔化之后再拉回来一点，这才是相机出片的手感
        if p.sharpen > 0.005 {
            img = apply("CISharpenLuminance", img, [
                kCIInputSharpnessKey: p.sharpen * 0.5
            ]).cropped(to: extent)
        }

        return img
    }

    private func chromaSplit(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let center = CGPoint(x: extent.midX, y: extent.midY)

        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, scale: CGFloat) -> CIImage {
            guard let sep = CIFilter(name: "CIColorMatrix") else { return image }
            sep.setValue(image, forKey: kCIInputImageKey)
            sep.setValue(CIVector(x: r, y: 0, z: 0, w: 0), forKey: "inputRVector")
            sep.setValue(CIVector(x: 0, y: g, z: 0, w: 0), forKey: "inputGVector")
            sep.setValue(CIVector(x: 0, y: 0, z: b, w: 0), forKey: "inputBVector")
            sep.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            var out = sep.outputImage ?? image

            if abs(scale - 1) > 0.000_001 {
                let toOrigin = CGAffineTransform(translationX: -center.x, y: -center.y)
                let back = CGAffineTransform(translationX: center.x, y: center.y)
                let t = toOrigin
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(back)
                out = out.clampedToExtent().transformed(by: t)
            }
            return out.cropped(to: extent)
        }

        let red = channel(1, 0, 0, scale: 1 + CGFloat(amount))
        let green = channel(0, 1, 0, scale: 1)
        let blue = channel(0, 0, 1, scale: 1 - CGFloat(amount))

        var sum = image
        if let add = CIFilter(name: "CIAdditionCompositing") {
            add.setValue(red, forKey: kCIInputImageKey)
            add.setValue(green, forKey: kCIInputBackgroundImageKey)
            sum = add.outputImage ?? image
        }
        if let add = CIFilter(name: "CIAdditionCompositing") {
            add.setValue(blue, forKey: kCIInputImageKey)
            add.setValue(sum, forKey: kCIInputBackgroundImageKey)
            sum = add.outputImage ?? sum
        }
        return sum.cropped(to: extent)
    }

    // MARK: - 传感器噪点

    private func sensor(_ input: CIImage, params p: RealismParameters) -> CIImage {
        guard p.grain > 0.005 || p.chromaNoise > 0.005 else { return input }
        var img = input
        let extent = img.extent
        var rng = SeededGenerator(seed: p.seed &+ 31)

        let ox = CGFloat.random(in: -500...500, using: &rng)
        let oy = CGFloat.random(in: -500...500, using: &rng)

        // 亮度颗粒
        if let grain = grainLayer(offsetX: ox, offsetY: oy, extent: extent, params: p) {
            img = multiply(grain, over: img)
        }

        // 彩色噪点：先糊成大色斑，再叠回去，才像高感的暗部色噪
        if let chroma = chromaLayer(offsetX: ox + 217, offsetY: oy + 149, extent: extent, params: p) {
            img = multiply(chroma, over: img)
        }

        return img
    }

    /// 噪声增益图层：取值 [1−a/2, 1+a/2]、alpha 恒为 1。
    ///
    /// 注意：这里刻意不用 soft light / overlay 这类混合模式。
    /// Core Image 的 blend 滤镜在本工程的配置下会把整幅图算成 0
    /// （实测：中灰 0.5 叠上去成片全黑），加性叠加是唯一可控的做法。
    private func gainLayer(_ shape: CIImage, amplitude: Double, monochrome: Bool) -> CIImage {
        let a = CGFloat(min(max(amplitude, 0), 1))
        let source = monochrome ? grayscale(shape) : shape
        // rgb = a·x + (1 − a/2)：以 1.0 为中心，乘法叠加时整体亮度不变。
        let base = 1 - a / 2
        return apply("CIColorMatrix", source, [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: base, y: base, z: base, w: 1)
        ])
    }

    /// 乘法叠加。增益图层以 1.0 为中心，x·1 = x，所以整体亮度天然不变 ——
    /// 加性叠加在 CI 的工作空间里会有不成比例的整体偏移，乘法没有这个问题。
    private func multiply(_ gain: CIImage, over image: CIImage) -> CIImage {
        apply("CIMultiplyCompositing", gain, [kCIInputBackgroundImageKey: image])
            .cropped(to: image.extent)
    }

    /// 亮度颗粒层。均值 0，幅度 ±(grain·0.10)/2。
    private func grainLayer(offsetX: CGFloat, offsetY: CGFloat,
                            extent: CGRect, params p: RealismParameters) -> CIImage? {
        guard p.grain > 0.005,
              let noise = opaqueNoise(offsetX: offsetX, offsetY: offsetY, extent: extent) else { return nil }
        var shape = grayscale(noise)
        if p.grainSize > 1.05 {
            let unit = max(extent.width, extent.height) / 1200.0
            let radius = CGFloat((p.grainSize - 1.0) * 1.15) * unit
            shape = apply("CIGaussianBlur", shape.clampedToExtent(), [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        }
        return gainLayer(shape, amplitude: p.grain * 0.18, monochrome: true)
    }

    /// 彩色噪点层：低频色斑，RGB 三通道各自独立。
    private func chromaLayer(offsetX: CGFloat, offsetY: CGFloat,
                             extent: CGRect, params p: RealismParameters) -> CIImage? {
        guard p.chromaNoise > 0.005,
              let noise = opaqueNoise(offsetX: offsetX, offsetY: offsetY, extent: extent) else { return nil }
        let unit = max(extent.width, extent.height) / 1200.0
        let blobs = apply("CIGaussianBlur", noise.clampedToExtent(), [
            kCIInputRadiusKey: max(1.6 * unit, 0.6)
        ]).cropped(to: extent)
        return gainLayer(blobs, amplitude: p.chromaNoise * 0.30, monochrome: false)
    }

    /// 诊断用：拿到真实的噪点图层。
    func noiseLayerImages(_ image: CIImage, params p: RealismParameters) -> [(String, CIImage)] {
        let extent = image.extent
        var rng = SeededGenerator(seed: p.seed &+ 31)
        let ox = CGFloat.random(in: -500...500, using: &rng)
        let oy = CGFloat.random(in: -500...500, using: &rng)

        var out: [(String, CIImage)] = []
        if let g = grainLayer(offsetX: ox, offsetY: oy, extent: extent, params: p) {
            out.append(("grain", g))
        }
        if let c = chromaLayer(offsetX: ox + 217, offsetY: oy + 149, extent: extent, params: p) {
            out.append(("chroma", c))
        }
        return out
    }

    /// 诊断用：测任意 CIImage。
    func debugMeasure(_ name: String, _ image: CIImage) -> StageMetric {
        measure(name, image)
    }

    /// 诊断用：把一张纯中灰以指定混合模式叠到图上，检查混合语义是否符合预期。
    func debugBlend(_ mode: String, source: CIImage, background: CIImage) -> StageMetric {
        let out = apply(mode, source, [kCIInputBackgroundImageKey: background])
        return measure("blend-" + mode + "/" + String(format: "%.2f", source.extent.width), out)
    }

    /// 诊断用：把两个噪点图层本身测出来（均值应该是 0.5 附近、alpha 1）。
    func debugNoiseLayers(_ image: CIImage, params p: RealismParameters) -> [StageMetric] {
        let extent = image.extent
        var rng = SeededGenerator(seed: p.seed &+ 31)
        let ox = CGFloat.random(in: -500...500, using: &rng)
        let oy = CGFloat.random(in: -500...500, using: &rng)

        var out: [StageMetric] = []
        if let g = grainLayer(offsetX: ox, offsetY: oy, extent: extent, params: p) {
            out.append(measure("grain-layer", g))
        }
        if let c = chromaLayer(offsetX: ox + 217, offsetY: oy + 149, extent: extent, params: p) {
            out.append(measure("chroma-layer", c))
        }
        return out
    }

    private func randomNoise(offsetX: CGFloat, offsetY: CGFloat, extent: CGRect) -> CIImage? {
        guard let generator = CIFilter(name: "CIRandomGenerator"),
              let base = generator.outputImage else { return nil }
        let moved = base.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        return moved.cropped(to: extent)
    }

    /// CIRandomGenerator 的 alpha 通道也是随机的（实测均值 0.5）。
    /// 直接拿它去做 soft light / overlay，得到的是一张半透明图层：
    /// 混合后整幅图会被压暗到几乎全黑。所以先把它盖在一张不透明中灰上，
    /// alpha 恒为 1，颜色回到中灰附近，混合语义才是对的。
    private func opaqueNoise(offsetX: CGFloat, offsetY: CGFloat, extent: CGRect) -> CIImage? {
        guard let noise = randomNoise(offsetX: offsetX, offsetY: offsetY, extent: extent) else { return nil }
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)).cropped(to: extent)
        return apply("CISourceOverCompositing", noise, [kCIInputBackgroundImageKey: base])
            .cropped(to: extent)
    }

    private func grayscale(_ image: CIImage) -> CIImage {
        apply("CIColorMatrix", image, [
            "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    /// 整图平均亮度。用于兜底检查：渲染结果不能突然塌成黑图。
    private func meanLuma(_ image: CIImage) -> Double {
        let e = image.extent
        guard !e.isInfinite, !e.isNull, e.width > 1, e.height > 1,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image,
                  kCIInputExtentKey: CIVector(cgRect: e)
              ]),
              let out = filter.outputImage else { return -1 }

        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(out, toBitmap: base, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: srgb)
        }
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255.0
    }

    // MARK: - 场景叠加

    private func scene(_ input: CIImage, params p: RealismParameters) -> CIImage {
        var img = input
        let extent = img.extent

        if p.screenTexture > 0.01 {
            img = screenGrid(img, strength: p.screenTexture, extent: extent)
        }

        if p.lightLeak > 0.01 {
            img = lightLeak(img, strength: p.lightLeak, extent: extent, seed: p.seed)
        }

        return img
    }

    /// 翻拍屏幕时的像素网格。用软光叠加，而不是画线。
    private func screenGrid(_ image: CIImage, strength: Double, extent: CGRect) -> CIImage {
        let unit = max(extent.width, extent.height) / 1200.0
        guard let generator = CIFilter(name: "CICheckerboardGenerator") else { return image }
        generator.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        generator.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(strength) * 0.28), forKey: "inputColor0")
        generator.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
        generator.setValue(1.7 * unit, forKey: "inputWidth")
        generator.setValue(1.0, forKey: "inputSharpness")
        guard let grid = generator.outputImage else { return image }

        let rotated = grid.transformed(by: CGAffineTransform(rotationAngle: 0.09)).cropped(to: extent)
        // 加性叠加（屏幕反光就是往画面里加光），不用 blend 滤镜
        return apply("CIAdditionCompositing", rotated, [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    private func lightLeak(_ image: CIImage, strength: Double, extent: CGRect, seed: UInt64) -> CIImage {
        var rng = SeededGenerator(seed: seed &+ 991)
        let corner = Int.random(in: 0...3, using: &rng)
        let inset = CGFloat.random(in: 0...0.18, using: &rng) * min(extent.width, extent.height)

        let start: CGPoint
        switch corner {
        case 0: start = CGPoint(x: extent.minX - inset, y: extent.maxY + inset)
        case 1: start = CGPoint(x: extent.maxX + inset, y: extent.maxY + inset)
        case 2: start = CGPoint(x: extent.minX - inset, y: extent.minY - inset)
        default: start = CGPoint(x: extent.maxX + inset, y: extent.minY - inset)
        }
        let end = CGPoint(x: extent.midX, y: extent.midY)

        guard let gradient = CIFilter(name: "CILinearGradient") else { return image }
        gradient.setValue(CIVector(x: start.x, y: start.y), forKey: "inputPoint0")
        gradient.setValue(CIVector(x: end.x, y: end.y), forKey: "inputPoint1")

        let tint = corner % 2 == 0
            ? CIColor(red: 1.0, green: 0.62, blue: 0.28, alpha: CGFloat(strength) * 0.55)
            : CIColor(red: 1.0, green: 0.42, blue: 0.52, alpha: CGFloat(strength) * 0.45)
        gradient.setValue(tint, forKey: "inputColor0")
        gradient.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")

        guard let leak = gradient.outputImage?.cropped(to: extent) else { return image }
        // 漏光是“往画面里加光”，用加性叠加；屏幕混合在这套配置下会算出全黑
        return apply("CIAdditionCompositing", leak, [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    // MARK: - 小工具

    @discardableResult
    private func apply(_ name: String, _ image: CIImage, _ params: [String: Any] = [:]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in params {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage ?? image
    }
}
