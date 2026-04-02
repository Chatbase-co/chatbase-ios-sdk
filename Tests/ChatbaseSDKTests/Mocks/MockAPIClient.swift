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
    private var jsonResponses: [Data] = []
    private var sseLines: [[String]] = []
    private var errors: [Error?] = []

    var lastRequest: URLRequest?
    var requestCount = 0

    // MARK: - Configuration

    func respondWith<T: Encodable>(_ value: T) {
        jsonResponses.append(try! JSONEncoder().encode(value))
    }

    func respondWithRawJSON(_ json: String) {
        jsonResponses.append(json.data(using: .utf8)!)
    }

    func respondWithSSE(_ lines: [String]) {
        sseLines.append(lines)
    }

    func respondWithError(_ error: Error) {
        errors.append(error)
    }

    // MARK: - APIClient

    func send<T: Decodable>(request: URLRequest) async throws -> T {
        lastRequest = request
        requestCount += 1

        if let error = errors.first {
            errors.removeFirst()
            throw error!
        }

        guard !jsonResponses.isEmpty else {
            throw APIError.invalidResponse
        }

        let data = jsonResponses.removeFirst()
        return try JSONDecoder().decode(T.self, from: data)
    }

    func streamLines(request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        lastRequest = request
        requestCount += 1

        if let error = errors.first {
            errors.removeFirst()
            throw error!
        }

        guard !sseLines.isEmpty else {
            throw APIError.invalidResponse
        }

        let lines = sseLines.removeFirst()
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
