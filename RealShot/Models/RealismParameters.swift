import Foundation
import CoreGraphics

/// 一组“真实感”参数。所有值都在 0...1 或明确的语义区间内，
/// 方便 UI 用统一的滑杆驱动。
struct RealismParameters: Equatable, Codable {

    // MARK: 质感（sensor / compression）
    /// 亮度颗粒强度
    var grain: Double = 0.38
    /// 颗粒尺度，1.0 = 单像素，越大越像高感光胶片
    var grainSize: Double = 1.0
    /// 彩色噪点（暗部色斑）
    var chromaNoise: Double = 0.22
    /// 重新压缩的 JPEG 质量
    var jpegQuality: Double = 0.82
    /// 压缩-解码循环次数
    var jpegPasses: Int = 1

    // MARK: 光学（lens）
    /// 镜头柔化
    var softness: Double = 0.45
    /// 色散 / 紫边
    var chromaAberration: Double = 0.28
    /// 暗角
    var vignette: Double = 0.35
    /// 高光溢出（真实镜头不会把高光拍成死白）
    var bloom: Double = 0.35
    /// 手抖
    var motionBlur: Double = 0.18
    var motionAngle: Double = 0.0
    /// 机内锐化
    var sharpen: Double = 0.35

    // MARK: 色彩（color science）
    /// 0.5 = 中性，>0.5 偏暖
    var warmth: Double = 0.5
    /// 绿-品红偏移
    var tint: Double = 0.0
    /// 曝光补偿（EV）
    var exposure: Double = 0.0
    var contrast: Double = 1.03
    var saturation: Double = 1.02
    var vibrance: Double = 0.05
    /// 黑位抬升，胶片感的关键
    var blackLift: Double = 0.22
    /// 高光压缩
    var highlightRolloff: Double = 0.5

    // MARK: 场景（scene）
    /// 轻微倾斜（度）
    var rotation: Double = 0.0
    /// 透视畸变
    var perspective: Double = 0.35
    /// 漏光
    var lightLeak: Double = 0.0
    /// 翻拍屏幕时的像素网格 / 摩尔纹
    var screenTexture: Double = 0.0

    /// 噪点与随机量的种子，保证同一张图多次渲染结果一致
    var seed: UInt64 = 1

    static let `default` = RealismParameters()
}

// MARK: - 随机微调

extension RealismParameters {

    /// 在基准参数附近做小幅扰动。真实照片的“不完美”每张都不一样，
    /// 这一步是让批量处理看起来不像同一个滤镜原因就在于此。
    func jittered(seed newSeed: UInt64) -> RealismParameters {
        var rng = SeededGenerator(seed: newSeed)
        var p = self

        func wobble(_ value: Double, _ amount: Double, _ limits: ClosedRange<Double>) -> Double {
            let delta = Double.random(in: -amount...amount, using: &rng)
            return min(max(value + delta, limits.lowerBound), limits.upperBound)
        }

        p.grain = wobble(p.grain, 0.10, 0.02...0.95)
        p.grainSize = wobble(p.grainSize, 0.25, 0.8...2.4)
        p.chromaNoise = wobble(p.chromaNoise, 0.08, 0...0.9)
        p.jpegQuality = wobble(p.jpegQuality, 0.05, 0.45...0.95)
        p.softness = wobble(p.softness, 0.10, 0.05...0.95)
        p.chromaAberration = wobble(p.chromaAberration, 0.08, 0...0.9)
        p.vignette = wobble(p.vignette, 0.10, 0...0.9)
        p.bloom = wobble(p.bloom, 0.08, 0...0.9)
        p.motionBlur = wobble(p.motionBlur, 0.06, 0...0.6)
        p.sharpen = wobble(p.sharpen, 0.08, 0...0.9)
        p.warmth = wobble(p.warmth, 0.04, 0.2...0.8)
        p.tint = Double.random(in: -0.03...0.03, using: &rng)
        p.exposure = wobble(p.exposure, 0.06, -0.35...0.35)
        p.contrast = wobble(p.contrast, 0.02, 0.92...1.14)
        p.saturation = wobble(p.saturation, 0.03, 0.85...1.2)
        p.vibrance = wobble(p.vibrance, 0.03, -0.05...0.2)
        p.blackLift = wobble(p.blackLift, 0.06, 0...0.7)
        p.highlightRolloff = wobble(p.highlightRolloff, 0.06, 0...0.85)
        p.perspective = wobble(p.perspective, 0.10, 0...0.8)
        p.rotation = Double.random(in: -0.5...0.5, using: &rng)
        p.motionAngle = Double.random(in: 0...360, using: &rng)
        p.seed = newSeed
        return p
    }
}

// MARK: - 可复现的随机数

/// SplitMix64，比系统随机更适合“可复现的随机”。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
