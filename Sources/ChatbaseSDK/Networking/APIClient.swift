import Foundation
import os

private let logger = Logger(subsystem: "com.chatbase.sdk", category: "APIClient")

public struct StreamResponse: Sendable {
    public let bytes: URLSession.AsyncBytes
    public let response: HTTPURLResponse
}

public protocol APIClient: Sendable {
    func send<T: Decodable>(request: URLRequest) async throws -> T
    func streamLines(request: URLRequest) async throws -> StreamResponse
}

public struct APIErrorDetail: Decodable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: String]?
}

struct APIErrorResponse: Decodable {
    let error: APIErrorDetail
}

public enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, detail: APIErrorDetail)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let statusCode, let detail):
            if let details = detail.details, let fieldError = details.values.first {
                return "\(detail.message): \(fieldError) (HTTP \(statusCode))"
            }
            return "\(detail.message) (HTTP \(statusCode))"
        case .networkError(let error):
            return error.localizedDescription
        }
    }

    public var apiCode: String? {
        if case .httpError(_, let detail) = self { return detail.code }
        return nil
    }

    public var statusCode: Int? {
        if case .httpError(let code, _) = self { return code }
        return nil
    }
}

public final class URLSessionClient: APIClient, @unchecked Sendable {
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(configuration: URLSessionConfiguration = .default) {
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send<T: Decodable>(request: URLRequest) async throws -> T {
        logRequest(request)
        let start = ContinuousClock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logNetworkError(request, error: error, duration: ContinuousClock.now - start)
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let duration = ContinuousClock.now - start

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = parseHTTPError(statusCode: httpResponse.statusCode, data: data)
            logResponse(request, statusCode: httpResponse.statusCode, duration: duration, bodySize: data.count, error: apiError)
            throw apiError
        }

        logResponse(request, statusCode: httpResponse.statusCode, duration: duration, bodySize: data.count)
        return try decoder.decode(T.self, from: data)
    }

    public func streamLines(request: URLRequest) async throws -> StreamResponse {
        logRequest(request, isStream: true)
        let start = ContinuousClock.now

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            logNetworkError(request, error: error, duration: ContinuousClock.now - start)
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let duration = ContinuousClock.now - start

        guard (200...299).contains(httpResponse.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            let apiError = parseHTTPError(statusCode: httpResponse.statusCode, data: data)
            logResponse(request, statusCode: httpResponse.statusCode, duration: duration, bodySize: data.count, error: apiError)
            throw apiError
        }

        logResponse(request, statusCode: httpResponse.statusCode, duration: duration, isStream: true)
        return StreamResponse(bytes: bytes, response: httpResponse)
    }

    private func parseHTTPError(statusCode: Int, data: Data) -> APIError {
        if let response = try? decoder.decode(APIErrorResponse.self, from: data) {
            return .httpError(statusCode: statusCode, detail: response.error)
        }
        return .httpError(statusCode: statusCode, detail: APIErrorDetail(code: "UNKNOWN", message: "Unknown error", details: nil))
    }

    private func durationMs(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func logRequest(_ request: URLRequest, isStream: Bool = false) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        let bodySize = request.httpBody?.count ?? 0
        let streamTag = isStream ? " [stream]" : ""
        logger.info("→ \(method) \(url)\(streamTag) (\(bodySize)B body)")
    }

    private func logResponse(_ request: URLRequest, statusCode: Int, duration: Duration, bodySize: Int = 0, isStream: Bool = false, error: APIError? = nil) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "unknown"
        let ms = durationMs(duration)

        if let error {
            let desc = error.localizedDescription
            logger.error("← \(method) \(path) \(statusCode) \(ms)ms ERROR: \(desc)")
        } else if isStream {
            logger.info("← \(method) \(path) \(statusCode) \(ms)ms [stream opened]")
        } else {
            logger.info("← \(method) \(path) \(statusCode) \(ms)ms \(bodySize)B")
        }
    }

    private func logNetworkError(_ request: URLRequest, error: Error, duration: Duration) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "unknown"
        let ms = durationMs(duration)
        let desc = error.localizedDescription
        logger.error("← \(method) \(path) NETWORK ERROR \(ms)ms: \(desc)")
    }
}
