import Foundation
import Combine
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return HTTPResponse(status: 500, contentType: "application/json; charset=utf-8", body: Data("{\"ok\":false,\"error\":\"Response encoding failed\"}".utf8))
        }
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    func wireData(omitBody: Bool = false) -> Data {
        let code = (100...599).contains(status) ? status : 500
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict",
                       413: "Payload Too Large", 417: "Expectation Failed", 431: "Request Header Fields Too Large",
                       500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable"]
        let safeType = contentType.contains("\r") || contentType.contains("\n") ? "application/octet-stream" : contentType
        var text = "HTTP/1.1 \(code) \(reasons[code] ?? "Response")\r\nContent-Type: \(safeType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        let reserved = Set(["content-type", "content-length", "connection", "transfer-encoding", "cache-control"])
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) where !reserved.contains(name.lowercased()) {
            if HTTPRequestParser.isToken(name), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                text += "\(name): \(value)\r\n"
            }
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if !omitBody { data.append(body) }
        return data
    }
}

struct HTTPParseError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// One request per connection. Chunked bodies, folded headers and ambiguous lengths are rejected.
struct HTTPRequestParser {
    let maximumHeaderBytes: Int
    let maximumBodyBytes: Int
    private var buffer = Data()
    private var delimiterSearchStart = 0
    private var headerEnd: Int?
    private var pending: HTTPRequest?
    private var contentLength = 0
    private(set) var isFinished = false

    init(maximumHeaderBytes: Int = 16_384, maximumBodyBytes: Int = 65_536) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }

    mutating func append(_ data: Data) throws -> HTTPRequest? {
        guard !isFinished else { throw HTTPParseError(status: 400, message: "Connection already has a request") }
        guard data.count <= maximumHeaderBytes + maximumBodyBytes + 4 - buffer.count else {
            throw HTTPParseError(status: 413, message: "Request exceeds size limit")
        }
        buffer.append(data)
        if headerEnd == nil {
            if let range = buffer.range(of: Data([13, 10, 13, 10]), in: delimiterSearchStart..<buffer.count) {
                guard range.lowerBound <= maximumHeaderBytes else { throw HTTPParseError(status: 431, message: "Headers exceed size limit") }
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                try parseHeaders(headerData)
                headerEnd = range.upperBound
            } else {
                // The delimiter may straddle two reads, hence the three-byte allowance.
                guard buffer.count <= maximumHeaderBytes + 3 else { throw HTTPParseError(status: 431, message: "Headers exceed size limit") }
                delimiterSearchStart = max(0, buffer.count - 3)
                return nil
            }
        }
        guard let end = headerEnd, var request = pending else { return nil }
        let available = buffer.count - end
        guard available <= contentLength else { throw HTTPParseError(status: 400, message: "Unexpected bytes after request") }
        guard available == contentLength else { return nil }
        request.body = buffer.subdata(in: end..<buffer.count)
        isFinished = true
        buffer.removeAll(keepingCapacity: false)
        pending = nil
        return request
    }

    mutating func finish() throws {
        guard isFinished else { throw HTTPParseError(status: 400, message: "Request ended before complete headers or body") }
    }

    private mutating func parseHeaders(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw badRequest() }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw badRequest() }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, Self.isToken(String(requestLine[0])),
              ["HTTP/1.1", "HTTP/1.0"].contains(String(requestLine[2])) else { throw badRequest() }
        let target = String(requestLine[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#"),
              !target.unicodeScalars.contains(where: { $0.value <= 32 || $0.value >= 127 }) else { throw badRequest() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { throw badRequest() }
            let name = String(line[..<separator]).lowercased()
            guard Self.isToken(name), headers[name] == nil else { throw badRequest() }
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .init(charactersIn: " \t"))
            guard !value.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || $0.value == 127 }) else { throw badRequest() }
            headers[name] = value
        }
        if requestLine[2] == "HTTP/1.1", headers["host"]?.isEmpty != false { throw badRequest() }
        if headers["transfer-encoding"] != nil { throw HTTPParseError(status: 501, message: "Transfer-Encoding is unsupported; use Content-Length") }
        if headers["expect"] != nil { throw HTTPParseError(status: 417, message: "Expect is unsupported") }
        if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(length) else { throw badRequest() }
            guard number <= maximumBodyBytes else { throw HTTPParseError(status: 413, message: "Body exceeds size limit") }
            contentLength = number
        }
        let path = target.components(separatedBy: "?")[0]
        pending = HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: Data())
    }

    static func isToken(_ string: String) -> Bool {
        !string.isEmpty && string.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    private func badRequest() -> HTTPParseError { HTTPParseError(status: 400, message: "Malformed HTTP request") }
}

@MainActor
final class DeviceServer: ObservableObject {
    @Published private(set) var status = "服务已停止"
    @Published private(set) var isRunning = false
    private(set) var listeningPort: UInt16?
    var handler: ((HTTPRequest) -> HTTPResponse)?
    private var listener: NWListener?
    private var generation = UUID()
    private var clients: [UUID: DeviceHTTPConnection] = [:]
    private let maximumConnections = 32

    /// Port zero selects an available port for local tests; normal configuration uses a fixed port.
    func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        let next = try NWListener(using: parameters, on: endpointPort)
        let identity = UUID()
        generation = identity
        listener = next
        status = "正在启动服务…"
        next.stateUpdateHandler = { [weak self, weak next] state in
            Task { @MainActor [weak self, weak next] in
                guard let self = self, self.generation == identity else { return }
                switch state {
                case .ready:
                    self.listeningPort = next?.port?.rawValue
                    self.isRunning = true
                    self.status = "服务运行中 · 端口 \(self.listeningPort.map(String.init) ?? String(port))"
                case .failed(let error):
                    self.stop()
                    self.status = "服务启动或运行失败：\(error.localizedDescription)"
                case .waiting(let error):
                    self.isRunning = false
                    self.status = "服务正在等待网络：\(error.localizedDescription)"
                case .cancelled: self.isRunning = false
                default: break
                }
            }
        }
        next.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self = self, self.generation == identity, self.listener != nil else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        next.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let active = Array(clients.values)
        clients.removeAll()
        for client in active { client.close() }
        listeningPort = nil
        isRunning = false
        status = "服务已停止"
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < maximumConnections else { connection.cancel(); return }
        let id = UUID()
        let client = DeviceHTTPConnection(connection: connection, onRequest: { [weak self] request in
            self?.handler?(request) ?? .json(["ok": false, "error": "Device handler unavailable"], status: 503)
        }, onClose: { [weak self] in self?.clients.removeValue(forKey: id) })
        clients[id] = client
        client.start()
    }
}

@MainActor
private final class DeviceHTTPConnection {
    private let connection: NWConnection
    private let onRequest: (HTTPRequest) -> HTTPResponse
    private let onClose: () -> Void
    private var parser = HTTPRequestParser()
    private var timeout: DispatchSourceTimer?
    private var responding = false
    private var closed = false

    init(connection: NWConnection, onRequest: @escaping (HTTPRequest) -> HTTPResponse, onClose: @escaping () -> Void) {
        self.connection = connection
        self.onRequest = onRequest
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self = self, !self.closed else { return }
                if case .failed = state { self.close() }
                if case .cancelled = state { self.close() }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.closed else { return }
                if self.responding { self.close() }
                else { self.send(.json(["ok": false, "error": "Request timeout"], status: 408)) }
            }
        }
        timeout = timer
        timer.resume()
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self = self, !self.closed, !self.responding else { return }
                do {
                    if let data = data, let request = try self.parser.append(data) {
                        self.send(self.onRequest(request), omitBody: request.method == "HEAD")
                        return
                    }
                    if error != nil { self.close(); return }
                    if complete { try self.parser.finish(); self.close(); return }
                    self.receive()
                } catch let failure as HTTPParseError {
                    self.send(.json(["ok": false, "error": failure.message], status: failure.status))
                } catch {
                    self.send(.json(["ok": false, "error": "Malformed request"], status: 400))
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, omitBody: Bool = false) {
        guard !closed, !responding else { return }
        responding = true
        // Keep a send deadline as well, so a client that stops reading cannot retain a slot.
        timeout?.schedule(deadline: .now() + 15)
        connection.send(content: response.wireData(omitBody: omitBody), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        })
    }
}
