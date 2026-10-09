import Foundation

enum AIClientError: LocalizedError {
    case invalidConfiguration(String)
    case transport(String)
    case http(Int, String)
    case invalidResponse
    case noText(String)
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .transport(let message): return message
        case .http(let status, let message): return "AI 服务返回 HTTP \(status)：\(message)"
        case .invalidResponse: return "AI 服务返回的内容不是有效的 JSON 响应。"
        case .noText(let message), .incomplete(let message): return message
        }
    }
}

/// Non-streaming OpenAI-compatible requests. A failed generation is never retried automatically.
struct AIClient {
    private let session: URLSession
    private static let responseLimit = 8 * 1024 * 1024

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 200
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            // A redirect is surfaced as an HTTP error, so credentials cannot move to another host.
            self.session = URLSession(configuration: configuration, delegate: AIRedirectPolicy(), delegateQueue: nil)
        }
    }

    func complete(configuration: AIConfiguration, apiKey: String, system: String, prompt: String) async throws -> String {
        try Task.checkCancellation()
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 256, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AIClientError.invalidConfiguration("请填写有效的模型名称。")
        }
        guard (1...128_000).contains(configuration.maxTokens) else {
            throw AIClientError.invalidConfiguration("输出 token 上限必须在 1 至 128000 之间。")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.invalidConfiguration("请先填写生成提示词。")
        }
        let endpoint = configuration.style == .chatCompletions ? "chat/completions" : "responses"
        var request = try makeRequest(configuration: configuration, apiKey: apiKey, endpoint: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any]
        switch configuration.style {
        case .chatCompletions:
            payload = ["model": model,
                       "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
                       "max_completion_tokens": configuration.maxTokens, "stream": false]
        case .responses:
            payload = ["model": model, "instructions": system, "input": prompt,
                       "max_output_tokens": configuration.maxTokens, "stream": false, "store": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let object = try await send(request, apiKey: apiKey)
        try Task.checkCancellation()
        return try Self.extractText(object, style: configuration.style, apiKey: apiKey)
    }

    func listModels(configuration: AIConfiguration, apiKey: String) async throws -> [String] {
        try Task.checkCancellation()
        var request = try makeRequest(configuration: configuration, apiKey: apiKey, endpoint: "models")
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let object = try await send(request, apiKey: apiKey)
        guard let rows = object["data"] as? [[String: Any]] else { throw AIClientError.invalidResponse }
        let names = rows.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw AIClientError.noText("AI 服务未返回可用的模型列表。") }
        return Array(Set(names)).sorted()
    }

    private func makeRequest(configuration: AIConfiguration, apiKey: String, endpoint: String) throws -> URLRequest {
        let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: base), let url = components.url,
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw AIClientError.invalidConfiguration("API Base URL 必须是完整地址，且不能含账号、密码、查询参数或片段。")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw AIClientError.invalidConfiguration("API Base URL 必须使用 HTTPS；HTTP 仅允许本机地址。")
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw AIClientError.invalidConfiguration("请填写有效的 API Key，不能包含空格或换行。")
        }
        var request = URLRequest(url: url.appendingPathComponent(endpoint))
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest, apiKey: String) async throws -> [String: Any] {
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, receivedResponse) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            response = receivedResponse
            // Bound accumulation even if a provider omits or misstates Content-Length.
            for try await byte in bytes {
                guard data.count < Self.responseLimit else { throw AIClientError.noText("AI 响应超过 8 MB，已停止读取。") }
                data.append(byte)
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? AIClientError { throw error }
            if let error = error as? URLError {
                switch error.code {
                case .timedOut: throw AIClientError.transport("AI 请求超时。可检查网络和服务状态后手动重试。")
                case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                    throw AIClientError.transport("无法连接 AI 服务。请检查网络和 API Base URL。")
                default: throw AIClientError.transport("AI 网络请求失败（错误码 \(error.code.rawValue)）。")
                }
            }
            throw AIClientError.transport("AI 网络请求失败。")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        guard data.count <= Self.responseLimit else { throw AIClientError.noText("AI 响应超过 8 MB，已拒绝解析。") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let fallback: String
            switch http.statusCode {
            case 401, 403: fallback = "认证失败，请检查 API Key 和服务权限。"
            case 404: fallback = "接口或模型不存在，请检查 Base URL、接口模式和模型。"
            case 429: fallback = "请求频率或额度受限，请稍后手动重试。"
            case 300..<400: fallback = "服务返回重定向，请直接填写最终的 HTTPS API 地址。"
            default: fallback = "服务暂时不可用，或请求参数不受支持。"
            }
            let message = Self.providerError(object, apiKey: apiKey) ?? fallback
            throw AIClientError.http(http.statusCode, message)
        }
        guard let object = object else { throw AIClientError.invalidResponse }
        if let message = Self.providerError(object, apiKey: apiKey) { throw AIClientError.noText("AI 服务错误：\(message)") }
        return object
    }

    private static func extractText(_ object: [String: Any], style: APIStyle, apiKey: String) throws -> String {
        let text: String
        var reasoningOnly = false
        var refusal: String?
        switch style {
        case .chatCompletions:
            guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else { throw AIClientError.invalidResponse }
            text = textContent(message["content"])
            reasoningOnly = !textContent(message["reasoning_content"]).isEmpty || !textContent(message["reasoning"]).isEmpty
            refusal = message["refusal"] as? String
            if refusal == nil, let parts = message["content"] as? [[String: Any]] {
                refusal = parts.first(where: { $0["type"] as? String == "refusal" })?["refusal"] as? String
            }
            if choice["finish_reason"] as? String == "length" {
                throw AIClientError.incomplete("生成达到 token 上限，服务未完整完成回答。请提高上限或缩短提示词后重试。")
            }
            if choice["finish_reason"] as? String == "content_filter" {
                throw AIClientError.noText("AI 服务过滤了回答内容，未提供完整回答。请调整提示词。")
            }
        case .responses:
            var pieces: [String] = []
            if let output = object["output"] as? [[String: Any]] {
                for item in output {
                    if item["type"] as? String == "reasoning" { reasoningOnly = true; continue }
                    guard item["type"] as? String == "message",
                          (item["role"] as? String ?? "assistant") == "assistant" else { continue }
                    if let parts = item["content"] as? [[String: Any]] {
                        for part in parts {
                            if part["type"] as? String == "output_text", let value = part["text"] as? String { pieces.append(value) }
                            if part["type"] as? String == "refusal" { refusal = part["refusal"] as? String }
                        }
                    }
                }
            }
            // Some compatible providers expose the convenience field directly in JSON.
            if pieces.isEmpty, let value = object["output_text"] as? String { pieces.append(value) }
            text = pieces.joined(separator: "\n")
            if let status = object["status"] as? String, status != "completed" {
                if status == "incomplete" {
                    throw AIClientError.incomplete("AI 回答未完成，可能达到输出 token 上限。请调整上限或提示词后重试。")
                }
                throw AIClientError.noText("AI 服务返回状态 \(safeMessage(status, apiKey: apiKey))，未完成回答。")
            }
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        if let refusal = refusal, !refusal.isEmpty { throw AIClientError.noText("模型未提供回答：\(safeMessage(refusal, apiKey: apiKey))") }
        if reasoningOnly { throw AIClientError.noText("服务只返回推理内容，没有最终回答。请提高输出 token 上限或检查模型及接口模式。") }
        throw AIClientError.noText("AI 服务未返回可显示的文字。请检查模型及接口模式；工具调用和图片响应不适用于文字卡片。")
    }

    private static func textContent(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            guard let type = part["type"] as? String, ["text", "output_text"].contains(type) else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
    }

    private static func providerError(_ object: [String: Any]?, apiKey: String) -> String? {
        guard let error = object?["error"], !(error is NSNull) else { return nil }
        if let dictionary = error as? [String: Any], let message = dictionary["message"] as? String { return safeMessage(message, apiKey: apiKey) }
        if let message = error as? String { return safeMessage(message, apiKey: apiKey) }
        return "服务报告错误，但没有提供可读说明。"
    }

    private static func safeMessage(_ value: String, apiKey: String) -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = key.isEmpty ? value : value.replacingOccurrences(of: key, with: "[已隐藏 API Key]")
        return String(redacted.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }.prefix(600))
    }
}

private final class AIRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
