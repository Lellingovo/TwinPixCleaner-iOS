import Foundation

/// Defines all possible errors that can occur during the execution of TwinPixCleaner.
/// Conforms to `LocalizedError` to provide user-facing error descriptions for SwiftUI alerts.
public enum AppError: Error, LocalizedError, Equatable {
    
    /// Thrown when directory traversal fails or user selects an invalid folder.
    case unreadableDirectory(URL)

    /// Thrown when the user drops something that isn't a folder onto the dashboard.
    case notAFolder(URL)


    /// Thrown when an individual file deletion to the macOS Trash fails.
    case deletionFailed(URL, String)
    
    /// Thrown when multiple file deletions fail.
    case multipleDeletionsFailed([String])
    
    /// Thrown when attempting to undo a deletion fails.
    case restorationFailed(URL, String)

    /// Generic unknown error fallback.
    case unknown(String)
    
    public var errorDescription: String? {
        switch self {
        case .unreadableDirectory(let url):
            return "无法读取目录 \(url.path)，请确认已授予所需权限。"
        case .notAFolder(let url):
            return "「\(url.lastPathComponent)」不是文件夹，请选择文件夹再扫描。"
        case .deletionFailed(let url, let reason):
            return "删除 \(url.lastPathComponent) 失败：\(reason)"
        case .multipleDeletionsFailed(let files):
            return "有 \(files.count) 个文件删除失败：\(files.joined(separator: ", "))"
        case .restorationFailed(let url, let reason):
            return "恢复 \(url.lastPathComponent) 失败：\(reason)"
        case .unknown(let details):
            return "发生错误：\(details)"
        }
    }
}
