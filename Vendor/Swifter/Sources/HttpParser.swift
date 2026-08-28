//
//  HttpParser.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation

enum HttpParserError: Error, Equatable {
    case invalidStatusLine(String)
    case invalidFraming
    case requestTooLarge
}

public class HttpParser {

    public init() { }

    public func readHttpRequest(_ socket: Socket) throws -> HttpRequest {
        let statusLine = try socket.readLine()
        let statusLineTokens = statusLine.components(separatedBy: " ")
        if statusLineTokens.count < 3 {
            throw HttpParserError.invalidStatusLine(statusLine)
        }
        let request = HttpRequest()
        request.method = statusLineTokens[0]
        let encodedPath = statusLineTokens[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? statusLineTokens[1]
        let urlComponents = URLComponents(string: encodedPath)
        request.path = urlComponents?.path ?? ""
        request.queryParams = urlComponents?.queryItems?.map { ($0.name, $0.value ?? "") } ?? []
        request.headers = try readHeaders(socket)
        // Enforce bounds before allocating a body or dispatching to authentication.
        guard request.headers["transfer-encoding"] == nil else { throw HttpParserError.invalidFraming }
        if let contentLength = request.headers["content-length"] {
            guard !contentLength.isEmpty, contentLength.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let size = Int(contentLength) else { throw HttpParserError.invalidFraming }
            guard size <= 1_048_576 else { throw HttpParserError.requestTooLarge }
            request.body = try readBody(socket, size: size)
        }
        return request
    }

    private func readBody(_ socket: Socket, size: Int) throws -> [UInt8] {
        return try socket.read(length: size)
    }

    private func readHeaders(_ socket: Socket) throws -> [String: String] {
        var headers = [String: String]()
        var headerBytes = 0
        var headerCount = 0
        while case let headerLine = try socket.readLine(), !headerLine.isEmpty {
            headerCount += 1
            headerBytes += headerLine.utf8.count
            guard headerCount <= 100, headerBytes <= 32768 else { throw HttpParserError.requestTooLarge }
            let headerTokens = headerLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            if let name = headerTokens.first, let value = headerTokens.last {
                guard !name.contains(where: { $0.isWhitespace }), headers[name.lowercased()] == nil else { throw HttpParserError.invalidFraming }
                headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    func supportsKeepAlive(_ headers: [String: String]) -> Bool {
        if let value = headers["connection"] {
            return "keep-alive" == value.trimmingCharacters(in: .whitespaces)
        }
        return false
    }
}
