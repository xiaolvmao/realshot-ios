import Foundation

/// 画幅。真实相机不会输出 9:19.5 这种手机截图比例，
/// 这道裁切是“一眼假”的最大来源之一。
enum FrameMode: String, CaseIterable, Identifiable, Codable {
    case original
    case ratio4x3
    case ratio3x2
    case ratio16x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原比例"
        case .ratio4x3: return "4:3"
        case .ratio3x2: return "3:2"
        case .ratio16x9: return "16:9"
        }
    }

    /// 长边 : 短边
    var longShortRatio: Double? {
        switch self {
        case .original: return nil
        case .ratio4x3: return 4.0 / 3.0
        case .ratio3x2: return 3.0 / 2.0
        case .ratio16x9: return 16.0 / 9.0
        }
    }
}
