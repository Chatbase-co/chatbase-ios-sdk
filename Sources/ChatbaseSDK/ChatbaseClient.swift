import Foundation
import os

private let logger = Logger(subsystem: "com.chatbase.sdk", category: "ChatbaseClient")

// MARK: - ToolCallHandle

public enum ToolCallStatus: Sendable {
    case pending
    case resolved
    case failed
    case ignored
    case submissionError(Error)

    public static func == (lhs: ToolCallStatus, rhs: ToolCallStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending),
             (.resolved, .resolved),
             (.failed, .failed),
             (.ignored, .ignored),
             (.submissionError, .submissionError):
            return true
        default:
            return false
        }
    }
}

public actor ToolCallHandle {
    public nonisolated let toolCallId: String
    public nonisolated let toolName: String
    public nonisolated let input: JSONValue
    public nonisolated let conversationId: String

    private let service: ChatService
    public private(set) var status: ToolCallStatus = .pending
    private var inFlight = false

    init(toolCall: ToolCall, conversationId: String, service: ChatService) {
        self.toolCallId = toolCall.toolCallId
        self.toolName = toolCall.toolName
        self.input = toolCall.input
        self.conversationId = conversationId
        self.service = service
    }

    private func reserve() -> Bool {
        guard !inFlight else { return false }
        switch status {
        case .pending, .submissionError:
            inFlight = true
            return true
        case .resolved, .failed, .ignored:
            return false
        }
    }

    public func resolve(_ output: [String: JSONValue] = [:]) async {
        guard reserve() else {
            logger.warning("ToolCall \(self.toolCallId) not pending")
            return
        }
        defer { inFlight = false }
        do {
            try await service.submitToolResult(
                conversationId: conversationId,
                toolCall: ToolCall(toolCallId: toolCallId, toolName: toolName, input: input),
                output: .object(output)
            )
            status = .resolved
        } catch {
            logger.error("Failed to submit tool result: \(error.localizedDescription)")
            status = .submissionError(error)
        }
    }

    public func fail(_ message: String) async {
        guard reserve() else {
            logger.warning("ToolCall \(self.toolCallId) not pending")
            return
        }
        defer { inFlight = false }
        do {
            try await service.submitToolResult(
                conversationId: conversationId,
                toolCall: ToolCall(toolCallId: toolCallId, toolName: toolName, input: input),
                output: .object(["error": .string(message)])
            )
            status = .failed
        } catch {
            logger.error("Failed to submit tool error: \(error.localizedDescription)")
            status = .submissionError(error)
        }
    }

    public func ignore() {
        guard reserve() else {
            logger.warning("ToolCall \(self.toolCallId) not pending")
            return
        }
        defer { inFlight = false }
        status = .ignored
    }
}

// MARK: - ChatEvent

public enum ChatEvent: Sendable {
    case messageStarted(id: String)
    case text(String)
    case toolCall(ToolCallHandle)
    case finished(StreamFinishInfo)
}

// MARK: - ChatStream

public final class ChatStream: AsyncSequence, Sendable {
    public typealias Element = ChatEvent

    private let stream: AsyncThrowingStream<ChatEvent, Error>
    private let task: Task<Void, Never>

    public var isCancelled: Bool { task.isCancelled }

    init(rawStream: AsyncThrowingStream<StreamEvent, Error>, conversationId: String?, service: ChatService) {
        let (chatStream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        self.stream = chatStream
        let initialConvId = conversationId

        self.task = Task { @Sendable in
            // Tool calls arrive before the finish event that carries conversationId for first-turn streams.
            // Buffer them until finish resolves the id, then emit just before finish.
            var pendingToolCalls: [ToolCall] = []

            do {
                for try await event in rawStream {
                    switch event {
                    case .messageStarted(let id):
                        continuation.yield(.messageStarted(id: id))
                    case .textChunk(let chunk):
                        continuation.yield(.text(chunk))
                    case .toolCall(let toolCall):
                        pendingToolCalls.append(toolCall)
                    case .finished(let info):
                        let resolvedConvId = info.conversationId ?? initialConvId
                        if let cid = resolvedConvId, !cid.isEmpty {
                            for tc in pendingToolCalls {
                                continuation.yield(.toolCall(ToolCallHandle(
                                    toolCall: tc,
                                    conversationId: cid,
                                    service: service
                                )))
                            }
                        } else if !pendingToolCalls.isEmpty {
                            logger.error("Dropped \(pendingToolCalls.count) tool calls: no conversationId available")
                        }
                        pendingToolCalls.removeAll()
                        continuation.yield(.finished(info))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func cancel() {
        task.cancel()
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<ChatEvent, Error>.AsyncIterator {
        stream.makeAsyncIterator()
    }
}

// MARK: - ChatbaseClient

public final class ChatbaseClient: @unchecked Sendable {
    public let service: ChatService

    public init(agentId: String, baseURL: String = "https://www.chatbase.co/api/sdk") {
        self.service = ChatService(
            agentId: agentId,
            baseURL: baseURL,
            deviceId: DeviceId.get(),
            auth: Identity.load()
        )
    }

    public init(service: ChatService) {
        self.service = service
    }

    public var deviceId: String { service.deviceId }

    public var authState: AuthState { service.authState }

    public var currentUserId: String? {
        if case .identified(_, let userId) = service.authState { return userId }
        return nil
    }

    public var isIdentified: Bool {
        if case .identified = service.authState { return true }
        return false
    }

    public func identify(token: String) async throws {
        try await service.verify(token: token)
    }

    public func logout() {
        service.updateAuth(.anonymous)
    }

    public func stream(_ message: String, conversationId: String? = nil) -> ChatStream {
        ChatStream(
            rawStream: service.streamMessage(message, conversationId: conversationId),
            conversationId: conversationId,
            service: service
        )
    }

    public func `continue`(conversationId: String) -> ChatStream {
        ChatStream(
            rawStream: service.continueConversation(conversationId),
            conversationId: conversationId,
            service: service
        )
    }

    public func retry(conversationId: String, messageId: String) -> ChatStream {
        ChatStream(
            rawStream: service.retryMessage(conversationId: conversationId, messageId: messageId),
            conversationId: conversationId,
            service: service
        )
    }

    public func send(_ message: String, conversationId: String? = nil) async throws -> ChatResponse {
        try await service.sendMessage(message, conversationId: conversationId)
    }

    public func listConversations(cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Conversation> {
        try await service.listConversations(cursor: cursor, limit: limit)
    }

    public func listMessages(conversationId: String, cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Message> {
        try await service.listMessages(conversationId: conversationId, cursor: cursor, limit: limit)
    }
}
