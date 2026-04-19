//
//  MockAPIClient.swift
//  tatbeeqMa7moolTests
//

import Foundation
@testable import ChatbaseSDK

/// A mock APIClient that returns preconfigured responses.
/// Use `respondWith(_:)` to queue JSON data for `send()`,
/// and `respondWithSSE(_:)` to queue SSE lines for `streamLines()`.
final class MockAPIClient: APIClient, @unchecked Sendable {
    private enum Response {
        case json(Data)
        case sse([String])
        case error(Error)
    }

    private var queue: [Response] = []

    var lastRequest: URLRequest?
    var requestCount = 0

    // MARK: - Configuration

    func respondWith<T: Encodable>(_ value: T) {
        queue.append(.json(try! JSONEncoder().encode(value)))
    }

    func respondWithRawJSON(_ json: String) {
        queue.append(.json(json.data(using: .utf8)!))
    }

    func respondWithSSE(_ lines: [String]) {
        queue.append(.sse(lines))
    }

    func respondWithError(_ error: Error) {
        queue.append(.error(error))
    }

    // MARK: - APIClient

    func send<T: Decodable>(request: URLRequest) async throws -> T {
        lastRequest = request
        requestCount += 1

        guard !queue.isEmpty else { throw APIError.invalidResponse }
        let response = queue.removeFirst()

        switch response {
        case .json(let data):
            return try JSONDecoder().decode(T.self, from: data)
        case .error(let error):
            throw error
        case .sse:
            throw APIError.invalidResponse
        }
    }

    func streamLines(request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        lastRequest = request
        requestCount += 1

        guard !queue.isEmpty else { throw APIError.invalidResponse }
        let response = queue.removeFirst()

        let lines: [String]
        switch response {
        case .sse(let sseLines):
            lines = sseLines
        case .error(let error):
            throw error
        case .json:
            throw APIError.invalidResponse
        }

        let combined = lines.joined(separator: "\n") + "\n"
        let data = combined.data(using: .utf8)!

        // Create a local URL to stream from
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL)

        let fileURL = URL(fileURLWithPath: tempURL.path)
        let (bytes, _) = try await URLSession.shared.bytes(from: fileURL)

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        return (bytes, httpResponse)
    }
}
