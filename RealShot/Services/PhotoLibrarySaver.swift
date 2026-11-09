import Foundation
import Photos
import UIKit

/// 输出文件名。用毫秒 + 4 位随机后缀，避免同一秒内保存两次撞名
/// （撞名会让分享用的临时文件互相覆盖）。
enum OutputName {
    static func jpeg() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        return "RealShot-\(ms)-\(UUID().uuidString.prefix(4)).jpg"
    }
}

enum PhotoLibrarySaver {

    struct File {
        let data: Data
        let filename: String
    }

    enum SaveError: LocalizedError {
        case permissionDenied
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有相册写入权限，请到系统设置里开启"
            case .writeFailed: return "写入相册失败"
            }
        }
    }

    // MARK: - 对外

    /// 保存单张。
    static func save(data: Data, filename: String, albumName: String? = nil) async throws {
        let results = await saveAll([File(data: data, filename: filename)], albumName: albumName)
        guard results.first == true else { throw SaveError.writeFailed }
    }

    /// 一批图放进一次相册事务，返回每张的成功与否（顺序与入参一致）。
    ///
    /// 20 张各开一次 `performChanges` 在旧机型上明显偏慢，这里合并成一次。
    /// 万一整批失败（磁盘满、权限被中途收回），再退回逐张保存 ——
    /// 这样仍然能指出具体是哪一张出的问题。
    static func saveAll(_ files: [File], albumName: String? = nil) async -> [Bool] {
        guard !files.isEmpty else { return [] }

        var album: PHAssetCollection?
        var status: PHAuthorizationStatus

        if let albumName, !albumName.isEmpty {
            status = await requestAccess(forAlbum: true)
            if status == .authorized || status == .limited {
                album = await ensureAlbum(named: albumName)
            } else {
                // 不愿给完整相册权限：退回只写权限，照片照常保存，只是不归类。
                status = await requestAccess(forAlbum: false)
            }
        } else {
            status = await requestAccess(forAlbum: false)
        }

        guard status == .authorized || status == .limited else {
            return Array(repeating: false, count: files.count)
        }

        // 先把所有图落到临时文件：PHAssetCreationRequest 只认 URL。
        var urls: [URL?] = []
        for file in files {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            do {
                try file.data.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                urls.append(nil)
            }
        }
        defer {
            for url in urls {
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        }

        let valid = urls.compactMap { $0 }
        if await addAssets(valid, to: album) {
            return urls.map { $0 != nil }
        }

        // 整批失败：逐张重试，定位到具体哪几张没写进去。
        var results: [Bool] = []
        for url in urls {
            guard let url else {
                results.append(false)
                continue
            }
            results.append(await addAssets([url], to: album))
        }
        return results
    }

    // MARK: - 相册事务

    private static func addAssets(_ urls: [URL], to album: PHAssetCollection?) async -> Bool {
        guard !urls.isEmpty else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                var placeholders: [PHObjectPlaceholder] = []
                for url in urls {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "public.jpeg"
                    options.originalFilename = url.lastPathComponent
                    request.addResource(with: .photo, fileURL: url, options: options)
                    if let placeholder = request.placeholderForCreatedAsset {
                        placeholders.append(placeholder)
                    }
                }
                if let album, !placeholders.isEmpty,
                   let change = PHAssetCollectionChangeRequest(for: album) {
                    change.addAssets(placeholders as NSArray)
                }
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private static func fetchAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        let result = PHAssetCollection.fetchAssetCollections(with: .album,
                                                            subtype: .albumRegular,
                                                            options: options)
        return result.firstObject
    }

    /// 相册不存在就建一个。建相册和往里加图要分两次事务，
    /// 同一个 change block 里拿不到新建相册的引用。
    private static func ensureAlbum(named name: String) async -> PHAssetCollection? {
        if let existing = fetchAlbum(named: name) { return existing }

        let created: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard created else { return nil }
        return fetchAlbum(named: name)
    }

    private static func requestAccess(forAlbum: Bool) async -> PHAuthorizationStatus {
        let level: PHAccessLevel = forAlbum ? .readWrite : .addOnly
        return await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: level) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
