import Foundation

/// A protocol defining the standard interface for an image scanning engine.
/// Not MainActor-bound so heavy PhotoKit / Vision work can run off the UI thread.
public protocol ImageScanner: Sendable {
    func scan(
        in directory: URL,
        onProgress: @MainActor @Sendable @escaping (Double, String) -> Void
    ) async throws -> ScanResult
}

/// Represents a group of mathematically or visually identical files.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let fileSize: Int64
    public let fileURLs: [URL]

    public init(hash: String, fileSize: Int64, fileURLs: [URL]) {
        self.hash = hash
        self.fileSize = fileSize
        self.fileURLs = fileURLs
    }
}

/// The outcome of a scan: the duplicate groups found, plus a summary of any skipped files.
public struct ScanResult: Sendable {
    public let groups: [DuplicateGroup]
    public let skippedSummary: SkippedSummary

    public var skippedCount: Int { skippedSummary.totalCount }

    public init(groups: [DuplicateGroup], skippedSummary: SkippedSummary) {
        self.groups = groups
        self.skippedSummary = skippedSummary
    }

    public init(groups: [DuplicateGroup], skippedCount: Int) {
        self.groups = groups
        var summary = SkippedSummary()
        if skippedCount > 0 {
            for _ in 0..<skippedCount {
                summary.add(name: "已跳过项目", reason: .unreadableFile)
            }
        }
        self.skippedSummary = summary
    }
}
