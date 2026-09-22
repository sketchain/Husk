import Photos
import UIKit

/// 把一张 PNG 存进相册。
///
/// 刻意只申请 **add-only** 权限（`PHAccessLevel.addOnly` + Info.plist 里的
/// `NSPhotoLibraryAddUsageDescription`）：这个功能只需要"往里放"，
/// 申请完整读写权限等于顺手要走用户整个相册的读取权，没有道理。
///
/// 也不用 `UIImageWriteToSavedPhotosAlbum`——它拿的是 `UIImage`，写进去会被转码，
/// 主屏图标要的恰好是原样的 PNG。走 `PHAssetCreationRequest.addResource(with:data:)`
/// 才是把这份字节原封不动放进去。
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied: "没有「添加到相册」权限。到 设置 → Husk → 照片 里打开「仅添加照片」。"
            case .failed(let message): "存进相册失败：\(message)"
            }
        }
    }

    static func save(png: Data) async throws {
        let status = await requestAddOnlyAccess()
        // .limited 在 add-only 下也算拿到了写入许可
        guard status == .authorized || status == .limited else { throw SaveError.denied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: png, options: nil)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SaveError.failed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }
    }

    private static func requestAddOnlyAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }
}
