import Foundation

/// 清理本 App 自己写出来的临时文件。
///
/// 只认 `RealShot-` 前缀，不去碰系统临时目录里的其它东西 ——
/// 在别人的目录里做通配删除是很容易出事的一类操作。
enum CacheCleaner {

    private static let prefix = "RealShot-"

    /// 当前可清理的体积（字节）。
    static func footprint() -> Int {
        files().reduce(0) { $0 + size(of: $1) }
    }

    /// 删掉临时文件，返回释放的字节数。
    @discardableResult
    static func clear() -> Int {
        var freed = 0
        for url in files() {
            let bytes = size(of: url)
            do {
                try FileManager.default.removeItem(at: url)
                freed += bytes
            } catch {
                // 正在被分享面板占用时会删不掉，跳过即可，下次再清。
            }
        }
        URLCache.shared.removeAllCachedResponses()
        return freed
    }

    static func formatted(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    private static func files() -> [URL] {
        let tmp = FileManager.default.temporaryDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private static func size(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
