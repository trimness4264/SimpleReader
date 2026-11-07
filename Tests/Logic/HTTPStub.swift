import XCTest
@testable import SimpleReader

// Each test gets a distinct origin. Handlers cannot leak into a parallel test.
final class HTTPStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, String)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func client(for test: XCTestCase, handler: @escaping Handler) -> (HTTPClient, URL) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        lock.lock()
        handlers[host] = handler
        lock.unlock()
        test.addTeardownBlock {
            lock.lock()
            handlers.removeValue(forKey: host)
            lock.unlock()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        return (HTTPClient(configuration: configuration), URL(string: "https://" + host)!)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = request.url?.host.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        do {
            guard let url = request.url, let handler = handler else { throw URLError(.unsupportedURL) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

extension URLRequest {
    func jsonBody() throws -> [String: Any] {
        var data = httpBody ?? Data()
        if data.isEmpty, let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
