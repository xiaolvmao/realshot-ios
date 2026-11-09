import Foundation

/// 预设模拟的“设备”。每个预设只定义基准值，实际渲染时还会做随机微调，
/// 所以同一预设连续处理十张图不会出现十张一模一样的颗粒分布。
enum CameraPreset: String, CaseIterable, Identifiable, Codable {
    case phone
    case telephoto
    case ccd
    case film
    case disposable
    case screenShot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone: return "手机主摄"
        case .telephoto: return "长焦人像"
        case .ccd: return "CCD 数码"
        case .film: return "35mm 胶片"
        case .disposable: return "一次性相机"
        case .screenShot: return "翻拍屏幕"
        }
    }

    var subtitle: String {
        switch self {
        case .phone: return "26mm · 干净锐利"
        case .telephoto: return "77mm · 压缩背景"
        case .ccd: return "2008 · 高对比"
        case .film: return "颗粒 · 抬黑位"
        case .disposable: return "漏光 · 偏色"
        case .screenShot: return "摩尔纹 · 反光"
        }
    }

    var symbol: String {
        switch self {
        case .phone: return "iphone"
        case .telephoto: return "camera.aperture"
        case .ccd: return "sdcard"
        case .film: return "film"
        case .disposable: return "camera.metering.center.weighted"
        case .screenShot: return "rectangle.on.rectangle"
        }
    }

    /// 该预设写入模拟 EXIF 时使用的机身信息
    var device: (make: String, model: String, lens: String, focal35: Int, fNumber: Double, focalLength: Double, iso: Int, exposure: Double) {
        switch self {
        case .phone:
            return ("Apple", "iPhone 15 Pro", "iPhone 15 Pro back camera 6.765mm f/1.78", 24, 1.78, 6.765, 125, 1.0 / 120.0)
        case .telephoto:
            return ("Apple", "iPhone 15 Pro", "iPhone 15 Pro back camera 9mm f/2.8", 77, 2.8, 9.0, 320, 1.0 / 100.0)
        case .ccd:
            return ("Canon", "Canon PowerShot SD1100 IS", "5.8-17.4 mm", 38, 2.8, 6.2, 200, 1.0 / 200.0)
        case .film:
            return ("Nikon", "Nikon FM2", "Nikkor 50mm f/1.8", 50, 1.8, 50.0, 400, 1.0 / 125.0)
        case .disposable:
            return ("Fujifilm", "QuickSnap Flash", "32mm f/10", 32, 10.0, 32.0, 800, 1.0 / 60.0)
        case .screenShot:
            return ("Apple", "iPhone 15 Pro", "iPhone 15 Pro back camera 6.765mm f/1.78", 24, 1.78, 6.765, 500, 1.0 / 60.0)
        }
    }

    /// 基准参数
    var baseParameters: RealismParameters {
        var p = RealismParameters()
        p.seed = UInt64.random(in: 1...UInt64.max)

        switch self {
        case .phone:
            p.grain = 0.36
            p.chromaNoise = 0.20
            p.softness = 0.42
            p.chromaAberration = 0.24
            p.vignette = 0.30
            p.bloom = 0.32
            p.jpegQuality = 0.84
            p.warmth = 0.51
            p.contrast = 1.03
            p.blackLift = 0.18

        case .telephoto:
            p.grain = 0.28
            p.chromaNoise = 0.18
            p.softness = 0.58
            p.chromaAberration = 0.34
            p.vignette = 0.44
            p.bloom = 0.46
            p.jpegQuality = 0.86
            p.warmth = 0.545
            p.contrast = 1.05
            p.saturation = 1.04
            p.blackLift = 0.14
            p.perspective = 0.2

        case .ccd:
            p.grain = 0.22
            p.chromaNoise = 0.42
            p.softness = 0.5
            p.chromaAberration = 0.4
            p.vignette = 0.34
            p.bloom = 0.52
            p.sharpen = 0.55
            p.jpegQuality = 0.7
            p.jpegPasses = 2
            p.warmth = 0.46
            p.contrast = 1.09
            p.saturation = 1.12
            p.vibrance = 0.12
            p.blackLift = 0.06

        case .film:
            p.grain = 0.56
            p.grainSize = 1.7
            p.chromaNoise = 0.26
            p.softness = 0.52
            p.chromaAberration = 0.3
            p.vignette = 0.42
            p.bloom = 0.4
            p.jpegQuality = 0.87
            p.warmth = 0.555
            p.contrast = 0.98
            p.saturation = 0.96
            p.blackLift = 0.46
            p.highlightRolloff = 0.6
            p.lightLeak = 0.22

        case .disposable:
            p.grain = 0.7
            p.grainSize = 2.1
            p.chromaNoise = 0.34
            p.softness = 0.72
            p.chromaAberration = 0.5
            p.vignette = 0.55
            p.bloom = 0.5
            p.jpegQuality = 0.72
            p.warmth = 0.58
            p.contrast = 0.95
            p.saturation = 1.06
            p.blackLift = 0.34
            p.lightLeak = 0.6

        case .screenShot:
            p.grain = 0.3
            p.chromaNoise = 0.16
            p.softness = 0.55
            p.chromaAberration = 0.36
            p.vignette = 0.25
            p.bloom = 0.52
            p.jpegQuality = 0.8
            p.warmth = 0.475
            p.contrast = 1.05
            p.screenTexture = 0.5
            p.lightLeak = 0.14
            p.perspective = 0.5
        }

        return p
    }
}
