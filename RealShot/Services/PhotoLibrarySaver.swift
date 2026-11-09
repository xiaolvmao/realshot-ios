import Foundation
import Photos
import UIKit

enum PhotoLibrarySaver {

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

    /// 用 PHAssetCreationRequest 写入原始文件，这样 EXIF 不会被系统重新编码掉。
    static func save(data: Data, filename: String) async throws {
        let status = await requestAddOnlyAccess()
        guard status == .authorized || status == .limited else {
            throw SaveError.permissionDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename, isDirectory: false)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SaveError.writeFailed
        }

        defer { try? FileManager.default.removeItem(at: url) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "public.jpeg"
                options.originalFilename = filename
                request.addResource(with: .photo, fileURL: url, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SaveError.writeFailed)
                }
            }
        }
    }

    private static func requestAddOnlyAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
