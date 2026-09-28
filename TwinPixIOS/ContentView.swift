import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var model = AppViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle:
                    IdleView(model: model)
                case .scanning:
                    ScanningView(model: model)
                case .results(let groups):
                    ResultsView(model: model, groups: groups)
                }
            }
            .navigationTitle("相册扫描")
            .alert("出错了", isPresented: Binding(
                get: { model.appError != nil },
                set: { if !$0 { model.appError = nil } }
            )) {
                Button("好的", role: .cancel) { model.appError = nil }
            } message: {
                Text(model.appError?.errorDescription ?? "")
            }
            .sheet(isPresented: $model.showSkippedSheet) {
                SkippedSheet(summary: model.lastScanSkippedSummary)
            }
            .sheet(isPresented: $model.showAISettings) {
                AISettingsSheet(model: model)
            }
        }
    }
}

private struct IdleView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("找出相册里的\n完全重复与相似照片")
                .multilineTextAlignment(.center)
                .font(.title3)

            Picker("模式", selection: $model.scanMode) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Picker("范围", selection: $model.scanScope) {
                ForEach(ScanScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Text(model.scanMode == .similar
                 ? "视觉相似较慢，建议先用「完全重复 + 90天」试扫。"
                 : "完全重复很快，适合先扫一轮。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Toggle(isOn: $model.includeiCloud) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("包含 iCloud 照片")
                    Text("扫描时会按需从云端下载，较慢且消耗流量。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            Button {
                model.startPhotosScanning()
            } label: {
                Label("开始扫描相册", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)

            Button {
                model.showAISettings = true
            } label: {
                Label(
                    model.aiSettings.isConfigured ? "AI 已配置 · \(model.aiSettings.model)" : "配置 AI（千问视觉）",
                    systemImage: "sparkles"
                )
                .font(.footnote)
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

private struct ScanningView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: model.scanProgress)
                .padding(.horizontal)
            Text("\(Int(model.scanProgress * 100))%")
                .font(.title2.monospacedDigit())
            Text(model.currentFile)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text(model.includeiCloud
                 ? "相册较大时会稍慢，云端照片会按需下载。"
                 : "相册较大时会稍慢，进度会随每张照片更新。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("取消", role: .cancel) {
                model.cancelScanning()
            }
        }
        .padding()
    }
}

private struct ResultsView: View {
    @ObservedObject var model: AppViewModel
    let groups: [DuplicateGroup]

    var body: some View {
        List {
            Section {
                HStack {
                    Text("\(groups.count) 组")
                    Spacer()
                    if model.lastScanSkippedSummary.totalCount > 0 {
                        Button("已跳过 \(model.lastScanSkippedSummary.totalCount)") {
                            model.showSkippedSheet = true
                        }
                        .font(.footnote)
                    }
                }
                if model.aiBatchBusy || model.aiBusyGroupID != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.aiStage.isEmpty ? "AI 处理中…" : model.aiStage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { model.cancelAI() }
                            .font(.footnote)
                    }
                }
            }

            if groups.isEmpty {
                ContentUnavailableView(
                    "未发现重复",
                    systemImage: "checkmark.circle",
                    description: Text("当前范围内相册看起来很干净")
                )
            } else {
                ForEach(groups) { group in
                    DuplicateGroupSection(model: model, group: group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("重新扫描") { model.reset() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.showAISettings = true
                } label: {
                    Image(systemName: "sparkles")
                }
                Button("AI 全建议") {
                    model.requestAISuggestionsForAll()
                }
                .disabled(model.aiBatchBusy || model.aiBusyGroupID != nil || groups.isEmpty)
                Button(role: .destructive) {
                    model.deleteSelectedFiles()
                } label: {
                    Label("删除 \(model.selectedFiles.count)", systemImage: "trash")
                }
                .disabled(model.selectedFiles.isEmpty)
            }
        }
    }
}

private struct DuplicateGroupSection: View {
    @ObservedObject var model: AppViewModel
    let group: DuplicateGroup
    @State private var previewItem: PhotoPreviewItem?

    private var suggestion: GroupAISuggestion? {
        model.aiSuggestions[group.hash]
    }

    private var isJudging: Bool {
        model.aiBusyGroupID == group.hash
    }

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(group.fileURLs, id: \.self) { url in
                        PhotoThumbCard(
                            url: url,
                            selected: model.selectedFiles.contains(url),
                            aiRecommended: suggestion?.keepURL == url,
                            aiReason: suggestion?.reasonsByURL[url],
                            onSelect: { model.toggleSelection(for: url) },
                            onPreview: { previewItem = PhotoPreviewItem(url: url) },
                            onKeep: { model.keepOnly(url, in: group) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("全选重复项") {
                    model.selectAllDuplicates(in: group)
                }
                .font(.footnote)

                Spacer()

                if isJudging {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(model.aiStage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if suggestion != nil {
                    Button("应用 AI 建议") {
                        model.applyAISuggestion(for: group)
                    }
                    .font(.footnote)
                } else {
                    Button {
                        model.requestAISuggestion(for: group)
                    } label: {
                        Label("AI 建议", systemImage: "sparkles")
                    }
                    .font(.footnote)
                    .disabled(model.aiBatchBusy || model.aiBusyGroupID != nil)
                }
            }

            if let suggestion {
                Text("AI 建议保留高亮那张 · \(suggestion.model)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file)
                 + " · 共 \(group.fileURLs.count) 张")
        }
        .fullScreenCover(item: $previewItem) { item in
            PhotoPreviewView(
                url: item.url,
                isSelected: model.selectedFiles.contains(item.url),
                onToggleSelect: { model.toggleSelection(for: item.url) },
                onKeep: {
                    model.keepOnly(item.url, in: group)
                    previewItem = nil
                }
            )
        }
    }
}

private struct PhotoPreviewItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct PhotoThumbCard: View {
    let url: URL
    let selected: Bool
    var aiRecommended: Bool = false
    var aiReason: String? = nil
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onKeep: () -> Void
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.secondary.opacity(0.15)
                            .overlay(ProgressView())
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            aiRecommended ? Color.green : (selected ? Color.red : Color.clear),
                            lineWidth: 3
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture(perform: onPreview)

                if aiRecommended {
                    Text("AI 留")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Button(action: onSelect) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.red : Color.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            if let aiReason, !aiReason.isEmpty {
                Text(aiReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)
            }

            Button("保留这张", action: onKeep)
                .font(.caption2)
                .buttonStyle(.bordered)
        }
        .task(id: url) {
            image = await PhotoThumbnailLoader.load(
                url: url,
                maxPixel: 240,
                allowNetwork: true,
                preferFinal: false
            )
        }
    }
}

private struct PhotoPreviewView: View {
    let url: URL
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onKeep: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isDownloading = true
    @State private var statusText = "加载中…"
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    scale = max(1, lastScale * value.magnification)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale < 1 { scale = 1; lastScale = 1 }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                if scale > 1 {
                                    scale = 1
                                    lastScale = 1
                                } else {
                                    scale = 2.5
                                    lastScale = 2.5
                                }
                            }
                        }
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                        Text(statusText)
                            .foregroundStyle(.white.opacity(0.85))
                            .font(.footnote)
                    }
                }

                if isDownloading, image != nil {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                        .padding(10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button(isSelected ? "取消选中" : "选中删除") {
                            onToggleSelect()
                        }
                        Button("保留这张", action: onKeep)
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task(id: url) {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        isDownloading = true
        statusText = "正在加载…"
        let screen = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale

        // Quick opportunistic preview first (may be local thumbnail).
        if let quick = await PhotoThumbnailLoader.load(
            url: url,
            maxPixel: Int(screen / 2),
            allowNetwork: true,
            preferFinal: false
        ) {
            image = quick
            statusText = "正在从 iCloud 拉取高清…"
        } else {
            statusText = "正在从 iCloud 下载…"
        }

        // Final high-quality (downloads from iCloud if needed).
        if let finalImage = await PhotoThumbnailLoader.load(
            url: url,
            maxPixel: Int(screen),
            allowNetwork: true,
            preferFinal: true
        ) {
            image = finalImage
            statusText = "已加载"
        } else if image == nil {
            statusText = "加载失败"
        } else {
            statusText = "已显示可用画质"
        }
        isDownloading = false
    }
}

enum PhotoThumbnailLoader {
    /// - Parameters:
    ///   - preferFinal: wait for non-degraded image (may download from iCloud).
    static func load(
        url: URL,
        maxPixel: Int,
        allowNetwork: Bool,
        preferFinal: Bool
    ) async -> UIImage? {
        guard let asset = PhotosAssetURL.asset(from: url) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = preferFinal ? .highQualityFormat : .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false
        if preferFinal {
            options.progressHandler = { _, _, _, _ in }
        }

        return await withCheckedContinuation { continuation in
            var resumed = false
            var latest: UIImage?
            let resumeOnce: (UIImage?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }

            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    resumeOnce(latest)
                    return
                }
                if info?[PHImageErrorKey] != nil {
                    resumeOnce(image ?? latest)
                    return
                }

                if let image { latest = image }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if preferFinal {
                    if let image, !degraded {
                        resumeOnce(image)
                    }
                } else if let image {
                    resumeOnce(image)
                } else {
                    resumeOnce(nil)
                }
            }

            if preferFinal {
                Task {
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    if !resumed {
                        PHImageManager.default().cancelImageRequest(requestID)
                        resumeOnce(latest)
                    }
                }
            }
        }
    }
}

private struct AISettingsSheet: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AISettings
    @State private var showKey = false

    init(model: AppViewModel) {
        self.model = model
        _draft = State(initialValue: model.aiSettings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("和 Whittle 一样：把分组照片发给视觉模型，选出该留哪张并给出理由。默认走阿里云 DashScope（千问 VL）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("API Key") {
                    HStack {
                        Group {
                            if showKey {
                                TextField("sk-…", text: $draft.apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("sk-…", text: $draft.apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("接口") {
                    TextField("Base URL", text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)

                    Picker("常用模型", selection: $draft.model) {
                        ForEach(AISettings.knownModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    TextField("模型名", text: $draft.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)

                    Button("填入默认 DashScope") {
                        draft.baseURL = AISettings.defaultBaseURL
                        if draft.model.isEmpty {
                            draft.model = AISettings.defaultModel
                        }
                    }
                    .font(.footnote)
                }

                Section {
                    Text("照片会上传到该 API 提供商。仅建议在 Wi‑Fi 下对「视觉相似」分组使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        model.saveAISettings(draft)
                        dismiss()
                    }
                    .disabled(draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SkippedSheet: View {
    let summary: SkippedSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(SkipReason.allCases) { reason in
                    let count = summary.reasonCounts[reason, default: 0]
                    if count > 0 {
                        Section("\(reason.rawValue) · \(count)") {
                            Text(reason.explanatoryText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(summary.sampleItems.filter { $0.reason == reason }) { item in
                                Text(item.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("已跳过（\(summary.totalCount)）")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
