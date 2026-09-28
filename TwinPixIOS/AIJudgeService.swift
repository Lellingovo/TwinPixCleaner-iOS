import Foundation
import Photos
import UIKit

/// OpenAI-compatible vision judge (DashScope Qwen-VL / LM Studio style), same idea as Whittle.
enum AIJudgeService {
    static let maxPhotosPerCall = 3

    struct Verdict: Sendable {
        let keepIndex: Int
        let reasons: [String]
        let model: String
    }

    enum JudgeError: LocalizedError {
        case notConfigured
        case emptyGroup
        case loadFailed
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "请先在「AI 设置」里填写 DashScope API Key。"
            case .emptyGroup:
                return "该组照片不足，无法判断。"
            case .loadFailed:
                return "无法加载照片（可能仍在 iCloud，请稍后重试）。"
            case .server(let message):
                return message
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Public

    static func judgeGroup(
        urls: [URL],
        settings: AISettings,
        onStage: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> Verdict {
        guard settings.isConfigured else { throw JudgeError.notConfigured }
        guard urls.count >= 2 else { throw JudgeError.emptyGroup }

        await onStage("正在准备照片…")
        var jpegs: [Data] = []
        jpegs.reserveCapacity(urls.count)
        for (i, url) in urls.enumerated() {
            await onStage("加载照片 \(i + 1)/\(urls.count)…")
            guard let data = await jpegData(for: url) else { throw JudgeError.loadFailed }
            jpegs.append(data)
        }

        let indices = Array(jpegs.indices)
        var reasons = [String](repeating: "", count: jpegs.count)
        var contenders = indices

        while contenders.count > maxPhotosPerCall {
            var winners: [Int] = []
            for group in balancedChunks(contenders, maxSize: maxPhotosPerCall) {
                if group.count == 1 {
                    winners.append(group[0])
                    continue
                }
                let label = group.map { String($0 + 1) }.joined(separator: ", ")
                await onStage("AI 比对第 \(label) 张…")
                let verdict = try await judgeOnce(
                    jpegs: group.map { jpegs[$0] },
                    settings: settings
                )
                for (k, original) in group.enumerated() {
                    if k < verdict.reasons.count {
                        reasons[original] = verdict.reasons[k]
                    }
                }
                winners.append(group[verdict.keepIndex])
            }
            contenders = winners
        }

        let keep: Int
        if contenders.count == 1 {
            keep = contenders[0]
        } else {
            if contenders.count < jpegs.count {
                let label = contenders.map { String($0 + 1) }.joined(separator: " vs ")
                await onStage("决赛：第 \(label) 张…")
            } else {
                await onStage("AI 正在比对 \(jpegs.count) 张…")
            }
            let verdict = try await judgeOnce(
                jpegs: contenders.map { jpegs[$0] },
                settings: settings
            )
            for (k, original) in contenders.enumerated() {
                if k < verdict.reasons.count {
                    reasons[original] = verdict.reasons[k]
                }
            }
            keep = contenders[verdict.keepIndex]
        }

        return Verdict(keepIndex: keep, reasons: reasons, model: settings.model)
    }

    // MARK: - OpenAI-compatible call

    private static func judgeOnce(jpegs: [Data], settings: AISettings) async throws -> Verdict {
        precondition(jpegs.count >= 2)

        var content: [[String: Any]] = [
            ["type": "text", "text": prompt(count: jpegs.count)]
        ]
        for jpeg in jpegs {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
            ])
        }

        let body: [String: Any] = [
            "model": settings.model,
            "messages": [["role": "user", "content": content]],
            "response_format": ["type": "json_object"],
            "temperature": 0.2,
            "max_tokens": 2000,
        ]

        guard let base = URL(string: settings.baseURL) else {
            throw JudgeError.server("API 地址无效")
        }
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw JudgeError.server("HTTP \(http.statusCode)：\(text.prefix(280))")
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }

        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = chat.choices.first?.message.content, !text.isEmpty else {
            throw JudgeError.server("模型返回为空")
        }
        return try parseVerdict(from: text, photoCount: jpegs.count, model: settings.model)
    }

    private static func prompt(count: Int) -> String {
        """
        你在帮用户从一组 \(count) 张相似照片中选出最好的一张，照片按顺序编号为 1 到 \(count)。
        请从清晰度/对焦、运动模糊、曝光、构图、以及主体瞬间是否好看来判断。
        若有人脸，请重点看脸部质量、眼睛是否睁开、表情是否自然。

        只返回 JSON，不要其它文字："keep_index" 为最佳照片的 1-based 编号；
        "reasons" 必须恰好 \(count) 条短句（每条最多 12 个词），第 N 条只描述第 N 张照片自身的可见优点或缺点，
        不要写照片编号，不要互相比较。
        回复必须以字符 '{' 开头。
        """
    }

    private struct RawVerdict: Decodable {
        let keep_index: Int
        let reasons: [String]
    }

    private static func parseVerdict(from text: String, photoCount: Int, model: String) throws -> Verdict {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let jsonData = String(text[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawVerdict.self, from: jsonData)
        else {
            throw JudgeError.server("无法解析模型输出：\(text.prefix(160))")
        }
        let keep = min(max(raw.keep_index - 1, 0), photoCount - 1)
        var reasons = raw.reasons
        if reasons.count < photoCount {
            reasons += Array(repeating: "", count: photoCount - reasons.count)
        } else if reasons.count > photoCount {
            reasons = Array(reasons.prefix(photoCount))
        }
        return Verdict(keepIndex: keep, reasons: reasons, model: model)
    }

    private static func balancedChunks(_ items: [Int], maxSize: Int) -> [[Int]] {
        guard !items.isEmpty else { return [] }
        let n = items.count
        let chunkCount = Int(ceil(Double(n) / Double(maxSize)))
        let base = n / chunkCount
        let rem = n % chunkCount
        var result: [[Int]] = []
        var i = 0
        for c in 0..<chunkCount {
            let size = base + (c < rem ? 1 : 0)
            result.append(Array(items[i..<(i + size)]))
            i += size
        }
        return result
    }

    // MARK: - Image export

    private static func jpegData(for url: URL) async -> Data? {
        guard let asset = PhotosAssetURL.asset(from: url) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let image: UIImage? = await withCheckedContinuation { continuation in
            var resumed = false
            var latest: UIImage?
            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1024, height: 1024),
                contentMode: .aspectFit,
                options: options
            ) { img, info in
                if let img { latest = img }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let errored = info?[PHImageErrorKey] != nil
                if cancelled || errored {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: latest)
                    }
                    return
                }
                if let img, !degraded, !resumed {
                    resumed = true
                    continuation.resume(returning: img)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if !resumed {
                    PHImageManager.default().cancelImageRequest(requestID)
                    resumed = true
                    continuation.resume(returning: latest)
                }
            }
        }

        return image?.jpegData(compressionQuality: 0.72)
    }
}

/// Persisted AI backend settings (DashScope compatible-mode by default).
struct AISettings: Equatable {
    var apiKey: String
    var baseURL: String
    var model: String

    static let defaultBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    static let defaultModel = "qwen-vl-plus"
    static let knownModels = [
        "qwen-vl-plus",
        "qwen-vl-max",
        "qwen3-vl-plus",
        "qwen3-vl-flash",
    ]

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: baseURL) != nil
            && !model.isEmpty
    }

    static func load() -> AISettings {
        let defaults = UserDefaults.standard
        return AISettings(
            apiKey: defaults.string(forKey: "ai.apiKey") ?? "",
            baseURL: defaults.string(forKey: "ai.baseURL") ?? defaultBaseURL,
            model: defaults.string(forKey: "ai.model") ?? defaultModel
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(apiKey, forKey: "ai.apiKey")
        defaults.set(baseURL, forKey: "ai.baseURL")
        defaults.set(model, forKey: "ai.model")
    }
}

struct GroupAISuggestion: Equatable {
    let keepURL: URL
    let reasonsByURL: [URL: String]
    let model: String
}
