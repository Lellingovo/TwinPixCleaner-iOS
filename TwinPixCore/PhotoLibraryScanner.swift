import Foundation
import Photos
#if canImport(UIKit)
import UIKit
#endif
import CryptoKit

/// How far back to scan.
enum ScanScope: String, CaseIterable, Identifiable, Sendable {
    case days30 = "30天"
    case days90 = "90天"
    case year1 = "1年"
    case all = "全部"

    var id: String { rawValue }

    var startDate: Date? {
        let cal = Calendar.current
        switch self {
        case .days30: return cal.date(byAdding: .day, value: -30, to: Date())
        case .days90: return cal.date(byAdding: .day, value: -90, to: Date())
        case .year1: return cal.date(byAdding: .year, value: -1, to: Date())
        case .all: return nil
        }
    }
}

struct PhotoLibraryScanner: ImageScanner, Sendable {
    let mode: ScanMode
    let scope: ScanScope
    /// When true, PhotoKit may download originals / thumbnails from iCloud.
    let includeiCloud: Bool

    /// Local hash should be quick; iCloud downloads need much longer.
    private var hashTimeoutNanoseconds: UInt64 {
        includeiCloud ? 90_000_000_000 : 4_000_000_000
    }

    init(mode: ScanMode, scope: ScanScope = .days90, includeiCloud: Bool = true) {
        self.mode = mode
        self.scope = scope
        self.includeiCloud = includeiCloud
    }

    func scan(
        in directory: URL,
        onProgress: @MainActor @Sendable @escaping (Double, String) -> Void
    ) async -> ScanResult {
        await onProgress(0.0, "正在请求相册权限…")

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            await onProgress(1.0, "相册权限被拒绝")
            return ScanResult(groups: [], skippedCount: 0)
        }

        await onProgress(0.02, includeiCloud ? "正在获取照片（含 iCloud）…" : "正在获取本机照片…")

        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let start = scope.startDate {
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        }

        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let totalCount = assets.count

        if totalCount == 0 {
            await onProgress(1.0, "该范围内没有照片")
            return ScanResult(groups: [], skippedCount: 0)
        }

        await onProgress(0.03, "共 \(totalCount) 张，开始扫描…")

        if mode == .exact {
            return await scanExact(assets: assets, totalCount: totalCount, onProgress: onProgress)
        } else {
            return await scanSimilar(assets: assets, totalCount: totalCount, onProgress: onProgress)
        }
    }

    // MARK: - Exact

    private func scanExact(
        assets: PHFetchResult<PHAsset>,
        totalCount: Int,
        onProgress: @MainActor @Sendable @escaping (Double, String) -> Void
    ) async -> ScanResult {
        var candidates: [(url: URL, size: Int64, label: String)] = []
        var skippedSummary = SkippedSummary()

        for i in 0..<totalCount {
            guard !Task.isCancelled else {
                return ScanResult(groups: [], skippedSummary: skippedSummary)
            }

            let asset = assets.object(at: i)
            let fraction = 0.03 + (Double(i) / Double(max(totalCount, 1))) * 0.25
            await onProgress(fraction, "整理中 \(i + 1)/\(totalCount)")

            let resources = PHAssetResource.assetResources(for: asset)
            let photoResource = resources.first(where: { $0.type == .photo })

            guard StillImageEligibility.isComparableStillPhotoAsset(asset, resource: photoResource) else {
                skippedSummary.add(
                    name: photoResource?.originalFilename ?? "照片 \(i + 1)",
                    detail: PhotosAssetURL.build(for: asset.localIdentifier).absoluteString,
                    reason: .unsupportedFormat
                )
                continue
            }

            if !includeiCloud && !Self.isLocallyAvailable(asset) {
                skippedSummary.add(
                    name: photoResource?.originalFilename ?? "照片 \(i + 1)",
                    detail: PhotosAssetURL.build(for: asset.localIdentifier).absoluteString,
                    reason: .inCloudOnly
                )
                continue
            }

            guard let resource = photoResource else {
                skippedSummary.add(
                    name: "照片 \(i + 1)",
                    detail: PhotosAssetURL.build(for: asset.localIdentifier).absoluteString,
                    reason: .inCloudOnly
                )
                continue
            }

            // Prefer reported file size; if missing but iCloud allowed, still include with size 1
            // so it enters the "must hash" path (size-bucketed alone won't collide wrongly —
            // unique size 1 photos with missing size are hashed only when another also has size 1.
            // Better: use pixelWidth*pixelHeight as soft size key when fileSize unknown.
            var size = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            if size <= 0 {
                let soft = Int64(max(asset.pixelWidth, 1) * max(asset.pixelHeight, 1))
                size = soft
            }

            candidates.append((
                PhotosAssetURL.build(for: asset.localIdentifier),
                size,
                resource.originalFilename
            ))

            if i % 5 == 0 { await Task.yield() }
        }

        await onProgress(
            0.30,
            includeiCloud
                ? "正在计算指纹 \(candidates.count) 张（可能从 iCloud 下载）…"
                : "正在计算指纹 \(candidates.count) 张本机照片…"
        )

        let allowNetwork = includeiCloud
        let timeout = hashTimeoutNanoseconds
        let result = await SizeHashGrouping.group(
            candidates: candidates,
            hash: { url in
                await self.computeHashWithTimeout(
                    forPhotoURL: url,
                    allowNetwork: allowNetwork,
                    timeoutNanoseconds: timeout
                )
            },
            onProgress: onProgress,
            baseProgress: 0.30,
            progressSpan: 0.70
        )
        skippedSummary.merge(result.skippedSummary)
        await onProgress(1.0, "完成 · \(result.groups.count) 组")
        return ScanResult(groups: result.groups, skippedSummary: skippedSummary)
    }

    /// Fast local probe — never triggers iCloud download.
    nonisolated private static func isLocallyAvailable(_ asset: PHAsset) -> Bool {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast

        var available = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 32, height: 32),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey]
            available = (image != nil) && !inCloud && (error == nil)
        }
        return available
    }

    // MARK: - Similar

    private struct PhotoPrintCandidate: Sendable {
        let url: URL
        let localIdentifier: String
        let filename: String
        let modificationDate: Date?
        let fileSize: Int64
        let isScreenshot: Bool
    }

    private func scanSimilar(
        assets: PHFetchResult<PHAsset>,
        totalCount: Int,
        onProgress: @MainActor @Sendable @escaping (Double, String) -> Void
    ) async -> ScanResult {
        var candidates: [PhotoPrintCandidate] = []
        var skippedSummary = SkippedSummary()

        for i in 0..<totalCount {
            guard !Task.isCancelled else { return ScanResult(groups: [], skippedSummary: skippedSummary) }

            let asset = assets.object(at: i)
            let fraction = 0.03 + (Double(i) / Double(max(totalCount, 1))) * 0.07
            await onProgress(fraction, "准备中 \(i + 1)/\(totalCount)")

            let photoResource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo })

            guard StillImageEligibility.isComparableStillPhotoAsset(asset, resource: photoResource) else {
                skippedSummary.add(
                    name: photoResource?.originalFilename ?? "照片 \(i + 1)",
                    detail: PhotosAssetURL.build(for: asset.localIdentifier).absoluteString,
                    reason: .unsupportedFormat
                )
                continue
            }

            if !includeiCloud && !Self.isLocallyAvailable(asset) {
                skippedSummary.add(
                    name: photoResource?.originalFilename ?? "照片 \(i + 1)",
                    detail: PhotosAssetURL.build(for: asset.localIdentifier).absoluteString,
                    reason: .inCloudOnly
                )
                continue
            }

            var fileSize: Int64 = 0
            if let resource = photoResource {
                fileSize = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            }

            candidates.append(
                PhotoPrintCandidate(
                    url: PhotosAssetURL.build(for: asset.localIdentifier),
                    localIdentifier: asset.localIdentifier,
                    filename: photoResource?.originalFilename ?? "照片 \(i + 1)",
                    modificationDate: asset.modificationDate,
                    fileSize: fileSize,
                    isScreenshot: StillImageEligibility.isScreenshotPhotoAsset(asset)
                )
            )

            if i % 5 == 0 { await Task.yield() }
        }

        let printResult = await computePhotoPrints(
            candidates: candidates,
            onProgress: onProgress,
            baseProgress: 0.10,
            progressSpan: 0.55
        )

        var sizeByURL: [URL: Int64] = [:]
        var screenshotByURL: [URL: Bool] = [:]
        for c in candidates {
            sizeByURL[c.url] = c.fileSize
            screenshotByURL[c.url] = c.isScreenshot
        }

        skippedSummary.merge(printResult.skippedSummary)
        let prints = printResult.prints
        if prints.isEmpty {
            await onProgress(1.0, "完成")
            return ScanResult(groups: [], skippedSummary: skippedSummary)
        }

        await onProgress(0.65, "正在比对 \(prints.count) 张照片…")

        let tagged = prints.map { entry in
            (entry.url, entry.vector, screenshotByURL[entry.url] ?? false)
        }
        let clusters = await FeaturePrintClustering.clusterSeparatingScreenshots(
            prints: tagged,
            photoThreshold: AppConstants.Scan.activeThreshold(),
            screenshotThreshold: AppConstants.Scan.activeScreenshotThreshold(),
            onProgress: onProgress,
            baseProgress: 0.65,
            progressSpan: 0.35
        )

        let groups = clusters.map { urls -> DuplicateGroup in
            DuplicateGroup(
                hash: "visual-\(UUID().uuidString)",
                fileSize: sizeByURL[urls[0]] ?? 0,
                fileURLs: urls
            )
        }

        await onProgress(1.0, "完成 · \(groups.count) 组")
        return ScanResult(groups: groups, skippedSummary: skippedSummary)
    }

    private func computePhotoPrints(
        candidates: [PhotoPrintCandidate],
        onProgress: @MainActor @Sendable @escaping (Double, String) -> Void,
        baseProgress: Double,
        progressSpan: Double
    ) async -> (prints: [FeaturePrintEngine.Entry], skippedSummary: SkippedSummary, skipped: Int) {
        let limit = min(
            AppConstants.Scan.maxConcurrentFeaturePrints,
            max(1, ProcessInfo.processInfo.activeProcessorCount)
        )
        let total = candidates.count
        if total == 0 { return ([], SkippedSummary(), 0) }

        let maxPixel = AppConstants.Scan.featurePrintMaxPixelSize
        let allowNetwork = includeiCloud
        let counter = PhotoProgressCounter()
        var results: [FeaturePrintEngine.Entry?] = Array(repeating: nil, count: total)
        var skippedSummary = SkippedSummary()
        var skipped = 0

        await withTaskGroup(of: (Int, FeaturePrintEngine.Entry?).self) { group in
            var nextIndex = 0
            var inFlight = 0

            func enqueueAvailable() {
                while inFlight < limit && nextIndex < total {
                    let index = nextIndex
                    let candidate = candidates[index]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask(priority: .utility) {
                        let entry = Self.featurePrint(
                            for: candidate,
                            maxPixel: maxPixel,
                            allowNetwork: allowNetwork
                        )
                        return (index, entry)
                    }
                }
            }

            enqueueAvailable()
            for await (index, entry) in group {
                inFlight -= 1
                if let entry {
                    results[index] = entry
                } else {
                    skipped += 1
                    skippedSummary.add(
                        name: candidates[index].filename,
                        detail: candidates[index].url.absoluteString,
                        reason: allowNetwork ? .unreadableFile : .inCloudOnly
                    )
                }

                let done = counter.increment()
                let fraction = baseProgress + (Double(done) / Double(total)) * progressSpan
                let label = allowNetwork
                    ? "分析中 \(done)/\(total)（可从 iCloud 下载）"
                    : "分析中 \(done)/\(total)"
                await onProgress(fraction, label)
                enqueueAvailable()
            }
        }

        return (results.compactMap { $0 }, skippedSummary, skipped)
    }

    nonisolated private static func featurePrint(
        for candidate: PhotoPrintCandidate,
        maxPixel: Int,
        allowNetwork: Bool
    ) -> FeaturePrintEngine.Entry? {
        let contentKey = FeaturePrintEngine.contentKey(
            photoLocalIdentifier: candidate.localIdentifier,
            modificationDate: candidate.modificationDate
        )
        let cacheKey = FeaturePrintEngine.fullCacheKey(contentKey: contentKey)
        if let cached = FeaturePrintEngine.loadCachedVector(cacheKey: cacheKey) {
            return FeaturePrintEngine.Entry(url: candidate.url, vector: cached)
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .fastFormat
        requestOptions.resizeMode = .fast
        requestOptions.isNetworkAccessAllowed = allowNetwork

        let target = CGSize(width: maxPixel, height: maxPixel)
        var cgImage: CGImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: requestOptions
        ) { image, info in
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
            // When network is disallowed, skip cloud-only. When allowed, PhotoKit may
            // still briefly report inCloud before delivering the downloaded image.
            if inCloud && !allowNetwork { return }
            if let image {
                #if canImport(UIKit)
                cgImage = image.cgImage
                #elseif canImport(AppKit)
                cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #endif
            }
        }

        guard let cgImage,
              let vector = FeaturePrintEngine.vector(fromCGImage: cgImage, contentKey: contentKey) else {
            return nil
        }
        return FeaturePrintEngine.Entry(url: candidate.url, vector: vector)
    }

    // MARK: - Hash with timeout

    nonisolated private func computeHashWithTimeout(
        forPhotoURL url: URL,
        allowNetwork: Bool,
        timeoutNanoseconds: UInt64
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await self.computeHash(forPhotoURL: url, allowNetwork: allowNetwork)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    nonisolated private func computeHash(forPhotoURL url: URL, allowNetwork: Bool) async -> String? {
        guard let asset = PhotosAssetURL.asset(from: url) else { return nil }
        return await computeHash(for: asset, allowNetwork: allowNetwork)
    }

    nonisolated private func computeHash(for asset: PHAsset, allowNetwork: Bool) async -> String? {
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .photo }) else {
            return nil
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork

        final class DataAccumulator: @unchecked Sendable {
            let lock = NSLock()
            var chunks: [Data] = []
            func append(_ data: Data) {
                lock.lock(); defer { lock.unlock() }
                chunks.append(data)
            }
            func allData() -> Data {
                lock.lock(); defer { lock.unlock() }
                return chunks.reduce(into: Data()) { $0.append($1) }
            }
        }
        let accumulator = DataAccumulator()

        return await withCheckedContinuation { continuation in
            var resumed = false
            let resumeOnce: (String?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    accumulator.append(chunk)
                },
                completionHandler: { error in
                    guard error == nil else {
                        resumeOnce(nil)
                        return
                    }
                    let data = accumulator.allData()
                    guard !data.isEmpty else {
                        resumeOnce(nil)
                        return
                    }
                    var hasher = SHA256()
                    hasher.update(data: data)
                    let digest = hasher.finalize()
                    resumeOnce(digest.compactMap { String(format: "%02x", $0) }.joined())
                }
            )
        }
    }
}

private final class PhotoProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
