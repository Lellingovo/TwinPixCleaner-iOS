import SwiftUI
import Photos

enum AppState: Equatable {
    case idle
    case scanning
    case results([DuplicateGroup])
}

enum ScanMode: String, CaseIterable, Identifiable, Sendable {
    case exact = "完全重复"
    case similar = "视觉相似"
    var id: String { rawValue }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var state: AppState = .idle
    @Published var selectedFiles: Set<URL> = []
    @Published var scanProgress: Double = 0
    @Published var currentFile: String = ""
    @Published var appError: AppError?
    /// Exact is much faster on device; recommend starting here.
    @Published var scanMode: ScanMode = .exact
    @Published var scanScope: ScanScope = .days90
    /// Download iCloud originals/thumbnails while scanning (uses cellular/Wi‑Fi data).
    @Published var includeiCloud: Bool = true
    @Published var lastScanSkippedSummary: SkippedSummary = SkippedSummary()
    @Published var showSkippedSheet = false
    @Published var showAISettings = false
    @Published var aiSettings = AISettings.load()
    @Published var aiSuggestions: [String: GroupAISuggestion] = [:]
    @Published var aiBusyGroupID: String?
    @Published var aiStage: String = ""
    @Published var aiBatchBusy = false

    private var scanTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?

    init() {
        Task.detached(priority: .background) {
            FeaturePrintEngine.pruneCache()
        }
    }

    var duplicateCount: Int {
        if case .results(let groups) = state { return groups.count }
        return 0
    }

    func startPhotosScanning() {
        state = .scanning
        selectedFiles.removeAll()
        scanProgress = 0
        currentFile = "正在开始…"
        appError = nil
        lastScanSkippedSummary = SkippedSummary()
        aiSuggestions.removeAll()
        aiBusyGroupID = nil
        aiStage = ""

        let mode = scanMode
        let scope = scanScope
        let iCloud = includeiCloud
        scanTask = Task { @MainActor in
            let started = Date()
            let progressHandler: @MainActor @Sendable (Double, String) -> Void = { progress, file in
                self.scanProgress = max(self.scanProgress, progress)
                let elapsed = Int(Date().timeIntervalSince(started))
                self.currentFile = "\(file) · \(elapsed)s"
            }

            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let elapsed = Int(Date().timeIntervalSince(started))
                    if self.state == .scanning {
                        let base = self.currentFile.split(separator: "·").first?
                            .trimmingCharacters(in: .whitespaces) ?? self.currentFile
                        self.currentFile = "\(base) · \(elapsed)s"
                    }
                }
            }

            let scanner = PhotoLibraryScanner(mode: mode, scope: scope, includeiCloud: iCloud)
            let dummyURL = URL(string: "photos://library")!
            let result = await scanner.scan(in: dummyURL, onProgress: progressHandler)
            heartbeat.cancel()
            guard !Task.isCancelled else { return }

            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .restricted || status == .denied {
                self.appError = .unknown("无法访问照片。请到 设置 → 相册扫描 中开启权限。")
                self.state = .idle
            } else {
                self.state = .results(result.groups)
                self.lastScanSkippedSummary = result.skippedSummary
            }
        }
    }

    func cancelScanning() {
        scanTask?.cancel()
        scanTask = nil
        state = .idle
    }

    func reset() {
        aiTask?.cancel()
        aiTask = nil
        state = .idle
        selectedFiles.removeAll()
        lastScanSkippedSummary = SkippedSummary()
        showSkippedSheet = false
        aiSuggestions.removeAll()
        aiBusyGroupID = nil
        aiStage = ""
        aiBatchBusy = false
    }

    func keepOnly(_ url: URL, in group: DuplicateGroup) {
        for fileURL in group.fileURLs where fileURL != url {
            selectedFiles.insert(fileURL)
        }
        selectedFiles.remove(url)
    }

    func selectAllDuplicates(in group: DuplicateGroup) {
        for fileURL in group.fileURLs.dropFirst() {
            selectedFiles.insert(fileURL)
        }
    }

    func toggleSelection(for url: URL) {
        if selectedFiles.contains(url) {
            selectedFiles.remove(url)
        } else {
            selectedFiles.insert(url)
        }
    }

    func deleteSelectedFiles() {
        guard case .results(var groups) = state else { return }
        let urlsToDelete = Array(selectedFiles)
        guard !urlsToDelete.isEmpty else { return }

        do {
            _ = try FileDeleter.deleteFiles(at: urlsToDelete)

            groups = groups.compactMap { group in
                let remaining = group.fileURLs.filter { !urlsToDelete.contains($0) }
                guard remaining.count > 1 else { return nil }
                return DuplicateGroup(hash: group.hash, fileSize: group.fileSize, fileURLs: remaining)
            }
            selectedFiles.removeAll()
            let remainingIDs = Set(groups.map(\.hash))
            aiSuggestions = aiSuggestions.filter { remainingIDs.contains($0.key) }
            state = .results(groups)
        } catch {
            appError = (error as? AppError) ?? .unknown(error.localizedDescription)
        }
    }

    func saveAISettings(_ settings: AISettings) {
        aiSettings = settings
        settings.save()
    }

    func applyAISuggestion(for group: DuplicateGroup) {
        guard let suggestion = aiSuggestions[group.hash] else { return }
        keepOnly(suggestion.keepURL, in: group)
    }

    func requestAISuggestion(for group: DuplicateGroup) {
        guard !aiBatchBusy, aiBusyGroupID == nil else { return }
        guard aiSettings.isConfigured else {
            showAISettings = true
            return
        }
        aiTask?.cancel()
        aiBusyGroupID = group.hash
        aiStage = "准备中…"
        let settings = aiSettings
        aiTask = Task { @MainActor in
            do {
                let verdict = try await AIJudgeService.judgeGroup(
                    urls: group.fileURLs,
                    settings: settings
                ) { stage in
                    self.aiStage = stage
                }
                guard !Task.isCancelled else { return }
                let keepURL = group.fileURLs[verdict.keepIndex]
                var reasons: [URL: String] = [:]
                for (i, url) in group.fileURLs.enumerated() {
                    if i < verdict.reasons.count {
                        reasons[url] = verdict.reasons[i]
                    }
                }
                aiSuggestions[group.hash] = GroupAISuggestion(
                    keepURL: keepURL,
                    reasonsByURL: reasons,
                    model: verdict.model
                )
                keepOnly(keepURL, in: group)
                aiStage = "完成"
            } catch {
                if !Task.isCancelled {
                    appError = .unknown(error.localizedDescription)
                }
            }
            aiBusyGroupID = nil
            aiStage = ""
        }
    }

    func requestAISuggestionsForAll() {
        guard case .results(let groups) = state, !groups.isEmpty else { return }
        guard !aiBatchBusy, aiBusyGroupID == nil else { return }
        guard aiSettings.isConfigured else {
            showAISettings = true
            return
        }
        aiTask?.cancel()
        aiBatchBusy = true
        let settings = aiSettings
        aiTask = Task { @MainActor in
            for (index, group) in groups.enumerated() {
                guard !Task.isCancelled else { break }
                if aiSuggestions[group.hash] != nil { continue }
                aiBusyGroupID = group.hash
                aiStage = "第 \(index + 1)/\(groups.count) 组…"
                do {
                    let verdict = try await AIJudgeService.judgeGroup(
                        urls: group.fileURLs,
                        settings: settings
                    ) { stage in
                        self.aiStage = "第 \(index + 1)/\(groups.count) 组 · \(stage)"
                    }
                    guard !Task.isCancelled else { break }
                    let keepURL = group.fileURLs[verdict.keepIndex]
                    var reasons: [URL: String] = [:]
                    for (i, url) in group.fileURLs.enumerated() {
                        if i < verdict.reasons.count {
                            reasons[url] = verdict.reasons[i]
                        }
                    }
                    aiSuggestions[group.hash] = GroupAISuggestion(
                        keepURL: keepURL,
                        reasonsByURL: reasons,
                        model: verdict.model
                    )
                    keepOnly(keepURL, in: group)
                } catch {
                    if !Task.isCancelled {
                        appError = .unknown("第 \(index + 1) 组失败：\(error.localizedDescription)")
                    }
                    break
                }
            }
            aiBusyGroupID = nil
            aiBatchBusy = false
            aiStage = ""
        }
    }

    func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        aiBusyGroupID = nil
        aiBatchBusy = false
        aiStage = ""
    }
}
