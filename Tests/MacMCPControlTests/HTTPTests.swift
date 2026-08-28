import XCTest
import Darwin
@testable import Swifter

final class HTTPTests: XCTestCase {
    // An in-memory socket exercises the production parser without allocating a declared body.
    final class Input: Socket {
        let bytes: [UInt8]
        var offset = 0
        var bodyRead = false
        init(_ request: String) { bytes = Array(request.utf8); super.init(socketFileDescriptor: -1) }
        override func read() throws -> UInt8 {
            guard offset < bytes.count else { throw SocketError.recvFailed("EOF") }
            defer { offset += 1 }
            return bytes[offset]
        }
        override func read(length: Int) throws -> [UInt8] {
            bodyRead = true
            return Array(repeating: 0, count: length)
        }
    }

    func testRejectsOversizedOrAmbiguousBodyBeforeAllocation() {
        for headers in ["Content-Length: 1048577", "Content-Length: 9223372036854775807", "Content-Length: -1", "Content-Length: nope", "Content-Length: 1\r\nContent-Length: 1", "Transfer-Encoding: chunked", "Content-Length: 0\r\nTransfer-Encoding: chunked"] {
            let input = Input("POST /mcp HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n\r\n")
            XCTAssertThrowsError(try HttpParser().readHttpRequest(input), headers)
            XCTAssertFalse(input.bodyRead)
        }
    }

    func testBoundsHeadersAndRequestLine() {
        let longPath = String(repeating: "x", count: 8192)
        let manyHeaders = (0..<101).map { "X-\($0): a\r\n" }.joined()
        let longValue = String(repeating: "x", count: 8000)
        let largeHeaders = (0..<5).map { "X-\($0): \(longValue)\r\n" }.joined()
        let requests = [
            "GET /\(longPath) HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\n\(manyHeaders)\r\n",
            "GET / HTTP/1.1\r\n\(largeHeaders)\r\n"
        ]
        for text in requests {
            XCTAssertThrowsError(try HttpParser().readHttpRequest(Input(text)))
        }
    }

    func testNormalRequestAndTruncatedSocketRead() throws {
        let input = Input("POST /mcp HTTP/1.1\r\nContent-Length: 4\r\n\r\n")
        XCTAssertEqual(try HttpParser().readHttpRequest(input).body.count, 4)
        // Real allocation/error path. The production buffer uses defer to free on EOF.
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let socket = Socket(socketFileDescriptor: pair[0])
        Darwin.close(pair[1])
        XCTAssertThrowsError(try socket.read(length: 1024))
        socket.close()
    }
}
