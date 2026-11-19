import Foundation

/// Answers URLSession requests in tests without touching the network.
/// Each stub gets its own host, so parallel tests never see each other's handlers.
final class HTTPStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    /// A session whose requests to `host` go to `handler`. Use `base` as the server address.
    static func make(_ handler: @escaping Handler) -> (session: URLSession, base: URL, log: RequestLog) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        let log = RequestLog()
        lock.withLock {
            handlers[host] = { req, body in
                log.append(req, body)
                return handler(req, body)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        return (URLSession(configuration: config), URL(string: "http://\(host)")!, log)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.lock.withLock({ Self.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let (status, body) = handler(request, Self.body(of: request))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(request: URLRequest, body: Data)] = []
    func append(_ r: URLRequest, _ b: Data) { lock.withLock { items.append((r, b)) } }
    var all: [(request: URLRequest, body: Data)] { lock.withLock { items } }
    var paths: [String] { all.map { $0.request.url?.path ?? "" } }
}

func json(_ s: String) -> Data { Data(s.utf8) }
func jsonObject(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
