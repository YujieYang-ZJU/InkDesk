import Foundation

private func serviceAssert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw InkError.message("Service test failed: \(message)") }
}

private final class MockAIProtocol: URLProtocol {
    typealias Reply = (status: Int, data: Data, delay: TimeInterval)
    static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?
    private var stopped = false
    private let instanceLock = NSLock()

    static func setHandler(_ next: @escaping (URLRequest) throws -> Reply) {
        lock.lock(); handler = next; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler = handler else { throw InkError.message("Mock handler missing") }
            let reply = try handler(request)
            let deliver = { [weak self] in
                guard let self = self else { return }
                self.instanceLock.lock(); let stopped = self.stopped; self.instanceLock.unlock()
                guard !stopped else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                               httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) }
            else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { instanceLock.lock(); stopped = true; instanceLock.unlock() }
}

private func mockJSON(_ object: Any, status: Int = 200, delay: TimeInterval = 0) throws -> MockAIProtocol.Reply {
    (status, try JSONSerialization.data(withJSONObject: object), delay)
}

private func mockRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count == 0 { return data }
        if count < 0 { throw stream.streamError ?? InkError.message("Mock body stream read failed") }
        data.append(buffer, count: count)
        try serviceAssert(data.count <= 1_048_576, "mock request body size")
    }
}

private func expectAIFailure(_ operation: () async throws -> String, matching: (Error) -> Bool, _ message: String) async throws {
    do {
        _ = try await operation()
        throw InkError.message("Service test failed: expected failure for \(message)")
    } catch {
        try serviceAssert(matching(error), message)
    }
}

/// Invoked by the app's --self-test runner. No external AI request or production Keychain item is used.
func runServiceTests() async throws {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MockAIProtocol.self]
    sessionConfiguration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    let client = AIClient(session: session)
    var configuration = AIConfiguration()
    configuration.baseURL = "https://provider.example/v1"
    configuration.model = "mock-model"
    configuration.style = .chatCompletions
    let fixtureKey = "unit-test-placeholder"

    MockAIProtocol.setHandler { request in
        try serviceAssert(request.url?.absoluteString == "https://provider.example/v1/chat/completions", "provider endpoint preserved")
        try serviceAssert(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixtureKey)", "bearer header")
        let body = try JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any]
        try serviceAssert(body?["model"] as? String == "mock-model", "model preserved")
        try serviceAssert(body?["max_completion_tokens"] as? Int == 1200, "completion token parameter")
        try serviceAssert(body?["stream"] as? Bool == false, "nonstreaming request")
        return try mockJSON(["choices": [["message": ["content": "  最终回答  ", "reasoning_content": "private reasoning"], "finish_reason": "stop"]]])
    }
    let chat = try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "system", prompt: "test")
    try serviceAssert(chat == "最终回答", "chat result excludes reasoning")

    MockAIProtocol.setHandler { _ in
        try mockJSON(["choices": [["message": ["content": [["type": "text", "text": "first"], ["type": "image_url", "text": "ignore"], ["type": "text", "text": "second"]]]]]])
    }
    let multipart = try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "", prompt: "test")
    try serviceAssert(multipart == "first\nsecond", "chat content array")

    configuration.style = .responses
    MockAIProtocol.setHandler { request in
        try serviceAssert(request.url?.path == "/v1/responses", "Responses endpoint")
        let body = try JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any]
        try serviceAssert(body?["instructions"] as? String == "system", "Responses instructions")
        try serviceAssert(body?["store"] as? Bool == false, "Responses storage disabled")
        return try mockJSON(["status": "completed", "output": [["type": "reasoning", "summary": [["type": "summary_text", "text": "ignore"]]],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "response"], ["type": "output_text", "text": "text"]]]]])
    }
    let response = try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "system", prompt: "test")
    try serviceAssert(response == "response\ntext", "Responses output parsing")

    MockAIProtocol.setHandler { _ in try mockJSON(["output_text": "convenience text", "status": "completed"]) }
    let convenience = try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "", prompt: "test")
    try serviceAssert(convenience == "convenience text", "compatible output_text field")

    let productionDefaults = AIConfiguration()
    try serviceAssert(productionDefaults.style == .responses, "production default uses Responses")
    MockAIProtocol.setHandler { request in
        try serviceAssert(request.url?.absoluteString == "https://api.deepseek.com/responses", "DeepSeek production endpoint")
        try serviceAssert(request.httpMethod == "POST", "DeepSeek generation POST")
        let body = try JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any]
        try serviceAssert(body?["model"] as? String == "deepseek-v4-pro", "DeepSeek production model")
        try serviceAssert(body?["instructions"] as? String == "production fixture", "DeepSeek system instructions")
        try serviceAssert(body?["input"] as? String == "mock-only prompt", "DeepSeek input prompt")
        try serviceAssert(body?["max_output_tokens"] as? Int == productionDefaults.maxTokens, "DeepSeek output token limit")
        try serviceAssert(body?["store"] as? Bool == false && body?["stream"] as? Bool == false, "DeepSeek nonstreaming private request")
        return try mockJSON(["status": "completed", "output": [["type": "message", "role": "assistant",
            "content": [["type": "output_text", "text": "DeepSeek mock result"]]]]])
    }
    let productionResult = try await client.complete(configuration: productionDefaults, apiKey: fixtureKey,
        system: "production fixture", prompt: "mock-only prompt")
    try serviceAssert(productionResult == "DeepSeek mock result", "DeepSeek production-default Responses parsing")

    MockAIProtocol.setHandler { _ in try mockJSON(["status": "completed", "output": [["type": "reasoning", "summary": []]]]) }
    try await expectAIFailure({ try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "", prompt: "test") }, matching: {
        if case AIClientError.noText = $0 { return $0.localizedDescription.contains("推理") }; return false
    }, "reasoning-only output is an error")

    MockAIProtocol.setHandler { _ in try mockJSON(["status": "incomplete", "output_text": "partial"]) }
    try await expectAIFailure({ try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "", prompt: "test") }, matching: {
        if case AIClientError.incomplete = $0 { return true }; return false
    }, "incomplete output is not success")

    MockAIProtocol.setHandler { _ in try mockJSON(["error": ["message": "Invalid key \(fixtureKey)"]], status: 401) }
    try await expectAIFailure({ try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "", prompt: "test") }, matching: {
        if case AIClientError.http(401, _) = $0 { return !$0.localizedDescription.contains(fixtureKey) }; return false
    }, "HTTP error redacts key")

    MockAIProtocol.setHandler { _ in (200, Data("not JSON".utf8), 0) }
    try await expectAIFailure({ try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "", prompt: "test") }, matching: {
        if case AIClientError.invalidResponse = $0 { return true }; return false
    }, "malformed AI JSON")

    MockAIProtocol.setHandler { request in
        try serviceAssert(request.httpMethod == "GET" && request.url?.path == "/v1/models", "model listing GET")
        return try mockJSON(["data": [["id": "z"], ["id": "mock-model"], ["id": "z"]]])
    }
    let models = try await client.listModels(configuration: configuration, apiKey: fixtureKey)
    try serviceAssert(models == ["mock-model", "z"], "model list deduplicates and sorts")

    var unsafe = configuration
    unsafe.baseURL = "http://provider.example/v1"
    try await expectAIFailure({ try await client.complete(configuration: unsafe, apiKey: fixtureKey, system: "", prompt: "test") }, matching: {
        if case AIClientError.invalidConfiguration = $0 { return true }; return false
    }, "remote HTTP rejected")
    unsafe.baseURL = "https://user:password@provider.example/v1"
    try await expectAIFailure({ try await client.complete(configuration: unsafe, apiKey: fixtureKey, system: "", prompt: "test") }, matching: {
        if case AIClientError.invalidConfiguration = $0 { return true }; return false
    }, "URL credentials rejected")
    try await expectAIFailure({ try await client.complete(configuration: configuration, apiKey: "key\r\nInjected: yes", system: "", prompt: "test") }, matching: {
        if case AIClientError.invalidConfiguration = $0 { return true }; return false
    }, "header injection rejected")

    MockAIProtocol.setHandler { _ in try mockJSON(["output_text": "late", "status": "completed"], delay: 1) }
    let cancelled = Task { try await client.complete(configuration: configuration, apiKey: fixtureKey, system: "", prompt: "test") }
    try await Task.sleep(nanoseconds: 30_000_000)
    cancelled.cancel()
    do { _ = try await cancelled.value; throw InkError.message("Service test failed: cancellation did not stop AI request") }
    catch { try serviceAssert(error is CancellationError, "AI cancellation propagation") }

    try testHTTPParser()
    try await testDeviceLoopback()
    print("Service tests passed: mocked AI, bounded HTTP parser, loopback server.")
}

private func expectParserError(_ text: String, status: Int, maximumHeaderBytes: Int = 16_384, maximumBodyBytes: Int = 65_536) throws {
    var parser = HTTPRequestParser(maximumHeaderBytes: maximumHeaderBytes, maximumBodyBytes: maximumBodyBytes)
    do {
        _ = try parser.append(Data(text.utf8))
        throw InkError.message("Service test failed: parser accepted malformed request")
    } catch let error as HTTPParseError {
        try serviceAssert(error.status == status, "parser error HTTP status")
    }
}

private func testHTTPParser() throws {
    let body = Data("{\"action\":\"toggle_task\",\"text\":\"完成\"}".utf8)
    var bytes = Data("POST /api/action?source=test HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer device-fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    bytes.append(body)
    // Every boundary, including UTF-8 code units and the CRLF delimiter, can split across reads.
    for split in 1..<bytes.count {
        var parser = HTTPRequestParser()
        let first = try parser.append(bytes.subdata(in: 0..<split))
        try serviceAssert(first == nil, "fragment not complete prematurely")
        let request = try parser.append(bytes.subdata(in: split..<bytes.count))
        try serviceAssert(request?.method == "POST" && request?.path == "/api/action", "fragmented request line")
        try serviceAssert(request?.headers["authorization"] == "Bearer device-fixture", "lowercase header keys")
        try serviceAssert(request?.body == body, "fragmented UTF-8 request body bytes")
        try parser.finish()
    }
    var byteParser = HTTPRequestParser()
    var finalRequest: HTTPRequest?
    for byte in bytes { finalRequest = try byteParser.append(Data([byte])) ?? finalRequest }
    try serviceAssert(finalRequest?.body == body, "byte-at-a-time receive")
    try expectParserError("GET / HTTP/1.1\r\n\r\n", status: 400)
    try expectParserError("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx", status: 400)
    try expectParserError("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n", status: 400)
    try expectParserError("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9999999999999999999999999\r\n\r\n", status: 400)
    try expectParserError("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc", status: 413, maximumBodyBytes: 2)
    try expectParserError("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", status: 501)
    try expectParserError("POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n", status: 417)
    try expectParserError("GET / HTTP/1.1\r\nHost: x\r\n Header: folded\r\n\r\n", status: 400)
    try expectParserError("GET / HTTP/1.1\r\nHost: x\r\n\r\nextra", status: 400)
    try expectParserError("GET / HTTP/1.1\r\nHost: abcdefghijklmnopqrstuvwxyz\r\n\r\n", status: 431, maximumHeaderBytes: 32)
    var incomplete = HTTPRequestParser()
    _ = try incomplete.append(Data("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na".utf8))
    do { try incomplete.finish(); throw InkError.message("Service test failed: truncated body accepted") }
    catch let error as HTTPParseError { try serviceAssert(error.status == 400, "truncated body status") }

    let wire = HTTPResponse(status: 200, contentType: "application/octet-stream", body: Data([0, 255]), headers: ["X-Invalid\r\nInjected": "x"]).wireData()
    try serviceAssert(wire.suffix(2) == Data([0, 255]), "binary response preserves bytes")
    let wireText = String(decoding: wire.dropLast(2), as: UTF8.self)
    try serviceAssert(wireText.contains("Content-Length: 2\r\n") && !wireText.contains("Injected"), "response length and header sanitizing")
    try serviceAssert(HTTPResponse.json(Date()).status == 500, "invalid response object fails honestly")
}

@MainActor
private func testDeviceLoopback() async throws {
    let server = DeviceServer()
    var receivedBody: Data?
    server.handler = { request in
        if request.path == "/health" { return .json(["ok": true]) }
        if request.headers["authorization"] != "Bearer device-fixture" { return .json(["ok": false], status: 401) }
        receivedBody = request.body
        return HTTPResponse(status: 200, contentType: "application/octet-stream", body: Data([0, 1, 254, 255]))
    }
    try server.start(port: 0)
    defer { server.stop() }
    for _ in 0..<100 {
        if server.isRunning { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try serviceAssert(server.isRunning, "listener reached ready state")
    guard let port = server.listeningPort else { throw InkError.message("Service test failed: listener did not expose port") }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "http://127.0.0.1:\(port)/api/action")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data("{\"action\":\"refresh\"}".utf8)
    request.setValue("Bearer device-fixture", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    try serviceAssert((response as? HTTPURLResponse)?.statusCode == 200 && data == Data([0, 1, 254, 255]), "loopback binary response")
    try serviceAssert(receivedBody == request.httpBody, "loopback Content-Length body")
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    let (_, rejected) = try await session.data(for: request)
    try serviceAssert((rejected as? HTTPURLResponse)?.statusCode == 401, "loopback handler authentication")
    server.stop()
    try serviceAssert(!server.isRunning && server.listeningPort == nil, "server stops cleanly")
}
