import Foundation

/// 记住上一次用的预设和参数，重启后不用重新挑一遍。
///
/// 用 JSON 存进 UserDefaults：`RealismParameters` 本身就是 Codable。
/// 以后加字段时旧数据会缺键、解不出来，这时直接退回默认值，不做迁移 ——
/// 对这个体量的 App 来说，迁移代码的维护成本比丢一次设置高得多。
enum SettingsStore {

    struct Editor: Codable {
        var preset: CameraPreset
        var params: RealismParameters
        var frame: FrameMode
        var trimBars: Bool
        var anchor: Double
        var cropX: Double
        var cropScale: Double
        var longEdge: Double
        var writeExif: Bool
        var saveToAlbum: Bool
    }

    /// 批量页那套参数单独存，和编辑器互不干扰。
    struct Batch: Codable {
        var preset: CameraPreset
        var params: RealismParameters
        var frame: FrameMode
        var trimBars: Bool
        var anchor: Double
        var cropX: Double
        var cropScale: Double
        var longEdge: Double
        var writeExif: Bool
        var saveToAlbum: Bool
    }

    private static let editorKey = "realshot.editor.v1"
    private static let batchKey = "realshot.batch.v1"

    static func loadEditor() -> Editor? {
        decode(Editor.self, from: editorKey)
    }

    static func saveEditor(_ value: Editor) {
        encode(value, to: editorKey)
    }

    static func loadBatch() -> Batch? {
        decode(Batch.self, from: batchKey)
    }

    static func saveBatch(_ value: Batch) {
        encode(value, to: batchKey)
    }

    // MARK: - 存取

    private static func decode<T: Decodable>(_ type: T.Type, from key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
