import Foundation
import os

let serviceLogger = Logger(subsystem: "com.chatbase.sdk", category: "ChatService")

// MARK: - Public Types

public struct ToolCall: Sendable {
    public let toolCallId: String
    public let toolName: String
    public let input: JSONValue

    public init(toolCallId: String, toolName: String, input: JSONValue) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.input = input
    }
}

public struct StreamFinishInfo: Sendable {
    public let conversationId: String?
    public let messageId: String?
    public let userMessageId: String?
    public let userId: String?
    public let finishReason: FinishReason?
    public let usage: Usage?

    public init(conversationId: String?, messageId: String?, userMessageId: String?, userId: String?, finishReason: FinishReason?, usage: Usage?) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.userMessageId = userMessageId
        self.userId = userId
        self.finishReason = finishReason
        self.usage = usage
    }
}

public enum StreamEvent: Sendable {
    case messageStarted(id: String)
    case textChunk(String)
    case toolCall(ToolCall)
    case finished(StreamFinishInfo)
}

public struct ChatResponse: Sendable {
    public let message: Message
    public let conversationId: String
    public let userMessageId: String?
    public let finishReason: FinishReason
    public let usage: Usage

    public init(message: Message, conversationId: String, userMessageId: String?, finishReason: FinishReason, usage: Usage) {
        self.message = message
        self.conversationId = conversationId
        self.userMessageId = userMessageId
        self.finishReason = finishReason
        self.usage = usage
    }
}

public enum ChatError: Error, LocalizedError {
    case noContent
    case decodingFailed(String)
    case invalidURL(String)
    case verifyResponseMissingUserId

    public var errorDescription: String? {
        switch self {
        case .noContent: return "No content in response"
        case .decodingFailed(let detail): return "Failed to decode response: \(detail)"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .verifyResponseMissingUserId: return "Verify response missing data.userId"
        }
    }
}

// MARK: - Internal DTOs (shared across extensions)

struct UsageDTO: Decodable {
    let credits: Double
}

enum MessagePartDTO: Decodable {
    case text(String)
    case toolCall(toolCallId: String, toolName: String, input: JSONValue)
    case toolResult(toolCallId: String, toolName: String, output: JSONValue)

    enum CodingKeys: String, CodingKey {
        case type, text, toolCallId, toolName, input, output
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "tool-call":
            self = .toolCall(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                toolName: try container.decode(String.self, forKey: .toolName),
                input: (try? container.decode(JSONValue.self, forKey: .input)) ?? .object([:])
            )
        case "tool-result":
            self = .toolResult(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                toolName: try container.decode(String.self, forKey: .toolName),
                output: (try? container.decode(JSONValue.self, forKey: .output)) ?? .object([:])
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown part type: \(type)"
            )
        }
    }
}

struct ConversationDTO: Decodable {
    let id: String
    let title: String?
    let createdAt: Int64
    let updatedAt: Int64
    let userId: String?
    let status: String
}

struct ConversationMessageDTO: Decodable {
    let id: String
    let role: String
    let parts: [MessagePartDTO]
    let createdAt: Int64?
    let feedback: String?
    let metadata: ConversationMessageMetadataDTO?
}

struct ConversationMessageMetadataDTO: Decodable {
    let score: Double?
}

struct PaginationDTO: Decodable {
    let cursor: String?
    let hasMore: Bool
    let total: Int
}

// MARK: - ChatService

public final class ChatService: @unchecked Sendable {
    let client: APIClient
    let baseURL: String
    let agentId: String
    public let deviceId: String

    private let lock = NSLock()
    private var auth: AuthState

    public init(
        client: APIClient = URLSessionClient(),
        agentId: String,
        baseURL: String = "https://www.chatbase.co/api/sdk",
        deviceId: String,
        auth: AuthState = .anonymous
    ) {
        self.client = client
        self.baseURL = baseURL
        self.agentId = agentId
        self.deviceId = deviceId
        self.auth = auth
    }

    // MARK: - Auth state

    public var authState: AuthState {
        lock.lock(); defer { lock.unlock() }
        return auth
    }

    func updateAuth(_ newState: AuthState) {
        lock.lock()
        self.auth = newState
        lock.unlock()
        Identity.save(newState)
    }

    // MARK: - Internal Helpers

    func sendRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            return try await client.send(request: request)
        } catch let error as DecodingError {
            throw ChatError.decodingFailed(String(describing: error))
        }
    }

    func extractText(from parts: [MessagePartDTO]) -> String? {
        let joined = parts.compactMap { part -> String? in
            if case .text(let t) = part, !t.isEmpty { return t }
            return nil
        }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    func mapParts(_ dtos: [MessagePartDTO]) -> [MessagePart] {
        dtos.map { dto in
            switch dto {
            case .text(let text):
                return MessagePart(kind: .text(text))
            case .toolCall(let id, let name, let input):
                return MessagePart(kind: .toolCall(toolCallId: id, toolName: name, input: input))
            case .toolResult(let id, let name, let output):
                return MessagePart(kind: .toolResult(toolCallId: id, toolName: name, output: output))
            }
        }
    }

    func mapMessage(_ dto: ConversationMessageDTO) -> Message? {
        guard let text = extractText(from: dto.parts) else { return nil }
        return Message(
            id: dto.id,
            text: text,
            sender: dto.role == "user" ? .user : .agent,
            date: dto.createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .now,
            feedback: dto.feedback.flatMap { MessageFeedback(rawValue: $0) },
            score: dto.metadata?.score,
            parts: mapParts(dto.parts)
        )
    }

    func mapConversation(_ dto: ConversationDTO) -> Conversation {
        Conversation(
            id: dto.id,
            title: dto.title,
            createdAt: Date(timeIntervalSince1970: Double(dto.createdAt) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(dto.updatedAt) / 1000),
            userId: dto.userId,
            status: ConversationStatus(rawValue: dto.status) ?? .ongoing
        )
    }

    // MARK: - Request Builders

    func buildChatRequest(message: String? = nil, conversationId: String? = nil, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: try url("/agents/\(agentId)/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(&request)
        request.httpBody = try JSONEncoder().encode(
            ChatRequestDTO(message: message, conversationId: conversationId, stream: stream)
        )
        return request
    }

    func buildJSONRequest<T: Encodable>(method: String, path: String, body: T) throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(&request)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func buildGETRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw ChatError.invalidURL("\(baseURL)\(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let finalURL = components.url else {
            throw ChatError.invalidURL("\(baseURL)\(path)")
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        applyAuthHeaders(&request)
        return request
    }

    func url(_ path: String) throws -> URL {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw ChatError.invalidURL("\(baseURL)\(path)")
        }
        return url
    }

    func applyAuthHeaders(_ request: inout URLRequest) {
        request.setValue(sdkUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        if case .identified(let token, _) = authState {
            request.setValue(token, forHTTPHeaderField: "X-User-Token")
        }
    }

    func paginationQuery(cursor: String?, limit: Int?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return items
    }
}

// MARK: - Private Request DTOs

private struct ChatRequestDTO: Encodable {
    let message: String?
    let conversationId: String?
    let stream: Bool

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encode(stream, forKey: .stream)
    }

    enum CodingKeys: String, CodingKey {
        case message, conversationId, stream
    }
}
