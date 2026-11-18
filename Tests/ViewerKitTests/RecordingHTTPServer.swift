// A loopback HTTP server that records every request path and answers a
// one-pixel GIF. Used by LockdownTests to observe exactly what the locked
// web view tries to fetch.

import Foundation
import Darwin

final class RecordingHTTPServer: @unchecked Sendable {
    static let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    private let lock = NSLock()
    private var _requests: [String] = []
    private var _responses: [String: (status: Int, contentType: String, body: Data)] = [:]
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?

    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// Serve a fixed response for a path. Paths without one get a one-pixel
    /// GIF (the default image bait response).
    func serve(_ path: String, status: Int = 200, contentType: String = "text/html", body: String) {
        lock.lock(); defer { lock.unlock() }
        _responses[path] = (status, contentType, Data(body.utf8))
    }

    init() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // any port
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        guard listen(listenFD, 16) == 0 else { throw POSIXError(.init(rawValue: errno)!) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(listenFD, sa, &length)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "RecordingHTTPServer"
        thread.stackSize = 1 << 18
        thread.start()
        acceptThread = thread
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var clientAddress = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &clientAddress, &length)
            guard client >= 0 else { return }
            handle(client)
            close(client)
        }
    }

    private func handle(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        // Read until the header block ends (or a sane cap).
        while buffer.count < 65536 {
            if buffer.range(of: terminator) != nil { break }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let head = String(decoding: buffer.prefix(while: { $0 != UInt8(ascii: "\n") }), as: UTF8.self)
        let parts = head.split(separator: " ")
        let path = parts.count >= 2 ? String(parts[1]) : ""
        lock.lock()
        _requests.append(path)
        let served = _responses[path]
        lock.unlock()

        let body: Data
        let contentType: String
        let status: Int
        if let served {
            body = served.body
            contentType = served.contentType
            status = served.status
        } else {
            body = RecordingHTTPServer.gif ?? Data()
            contentType = "image/gif"
            status = 200
        }
        let header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        response.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
