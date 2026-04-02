//
//  ChatbaseClient.swift
//  tatbeeqMa7mool
//
//  Created by Eesabase on 01/04/2026.
//

import Foundation

import os

private let logger = Logger(subsystem: "com.chatbase.sdk", category: "ChatbaseClient")

// MARK: - ToolCallHandle

/// Represents a tool call from the agent. Call resolve/fail to submit a result, or ignore to skip.
public final class ToolCallHandle: @unchecked Sendable {
    public let toolCallId: String
    public let toolName: String
    public let input: JSONValue
    public let conversationId: String

    private let service: ChatService
    private var resolved = false

    /// Whether this tool call was resolved with continue: true.
    public private(set) var shouldContinue = false

    init(toolCall: ToolCall, conversationId: String, service: ChatService) {
        self.toolCallId = toolCall.toolCallId
        self.toolName = toolCall.toolName
        self.input = toolCall.input
        self.conversationId = conversationId
        self.service = service
    }

    /// Submit a successful result.
    public func resolve(_ output: [String: JSONValue] = [:], `continue`: Bool = true) async {
        guard !resolved else {
            logger.warning("ToolCall \(self.toolCallId) already resolved")
            return
        }
        resolved = true
        shouldContinue = `continue`
        do {
            try await service.submitToolResult(
                conversationId: conversationId,
                toolCall: ToolCall(toolCallId: toolCallId, toolName: toolName, input: input),
                output: .object(output)
            )
        } catch {
            logger.error("Failed to submit tool result: \(error.localizedDescription)")
        }
    }

    /// Submit an error result.
    public func fail(_ message: String, `continue`: Bool = true) async {
        guard !resolved else {
            logger.warning("ToolCall \(self.toolCallId) already resolved")
            return
        }
        resolved = true
        shouldContinue = `continue`
        do {
            try await service.submitToolResult(
                conversationId: conversationId,
                toolCall: ToolCall(toolCallId: toolCallId, toolName: toolName, input: input),
                output: .object(["error": .string(message)])
            )
        } catch {
            logger.error("Failed to submit tool error: \(error.localizedDescription)")
        }
    }

    /// Don't submit anything. Don't continue.
    public func ignore() {
        guard !resolved else {
            logger.warning("ToolCall \(self.toolCallId) already resolved")
            return
        }
        resolved = true
    }

    public var isResolved: Bool { resolved }
}

// MARK: - ChatEvent

/// Events emitted by ChatbaseClient streams.
public enum ChatEvent: Sendable {
    case messageStarted(id: String)
    case text(String)
    case toolCall(ToolCallHandle)
    case finished(StreamFinishInfo)
    case error(Error)
}

// MARK: - ChatStream

/// A cancellable async sequence of chat events.
public final class ChatStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = ChatEvent

    private let stream: AsyncThrowingStream<ChatEvent, Error>
    private var task: Task<Void, Never>?
    private(set) var isCancelled = false

    init(rawStream: AsyncThrowingStream<StreamEvent, Error>, conversationId: String?, service: ChatService) {
        let (chatStream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        self.stream = chatStream
        let convId = conversationId ?? ""

        self.task = Task { @Sendable in
            do {
                for try await event in rawStream {
                    switch event {
                    case .messageStarted(let id):
                        continuation.yield(.messageStarted(id: id))
                    case .textChunk(let chunk):
                        continuation.yield(.text(chunk))
                    case .finished(let info):
                        continuation.yield(.finished(info))
                    case .toolCall(let toolCall):
                        let handle = ToolCallHandle(
                            toolCall: toolCall,
                            conversationId: convId,
                            service: service
                        )
                        continuation.yield(.toolCall(handle))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    nonisolated func cancel() {
        isCancelled = true
        task?.cancel()
    }

    nonisolated public func makeAsyncIterator() -> AsyncThrowingStream<ChatEvent, Error>.AsyncIterator {
        stream.makeAsyncIterator()
    }
}

// MARK: - ChatbaseClient

public final class ChatbaseClient: @unchecked Sendable {
    public let service: ChatService
    public let userId: String

    public init(agentId: String, apiKey: String, userId: String, baseURL: String = "https://www.chatbase.co/api/v2") {
        self.service = ChatService(agentId: agentId, apiKey: apiKey, baseURL: baseURL)
        self.userId = userId
    }

    public init(service: ChatService, userId: String) {
        self.service = service
        self.userId = userId
    }

    // MARK: - Streaming

    /// Stream a message to the agent.
    public func stream(_ message: String, conversationId: String? = nil) -> ChatStream {
        ChatStream(
            rawStream: service.streamMessage(message, conversationId: conversationId, userId: userId),
            conversationId: conversationId,
            service: service
        )
    }

    /// Continue a conversation after submitting a tool result.
    public func `continue`(conversationId: String) -> ChatStream {
        ChatStream(
            rawStream: service.continueConversation(conversationId),
            conversationId: conversationId,
            service: service
        )
    }

    /// Retry a message.
    public func retry(conversationId: String, messageId: String) -> ChatStream {
        ChatStream(
            rawStream: service.retryMessage(conversationId: conversationId, messageId: messageId),
            conversationId: conversationId,
            service: service
        )
    }

    // MARK: - Non-Streaming

    public func send(_ message: String, conversationId: String? = nil) async throws -> ChatResponse {
        try await service.sendMessage(message, conversationId: conversationId, userId: userId)
    }

    // MARK: - Conversations

    public func listConversations(cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Conversation> {
        try await service.listUserConversations(userId: userId, cursor: cursor, limit: limit)
    }

    public func getConversation(_ conversationId: String) async throws -> (Conversation, [Message], Pagination) {
        try await service.getConversation(conversationId)
    }

    public func listMessages(conversationId: String, cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Message> {
        try await service.listMessages(conversationId: conversationId, cursor: cursor, limit: limit)
    }

    public func listUserConversations(userId: String, cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Conversation> {
        try await service.listUserConversations(userId: userId, cursor: cursor, limit: limit)
    }

    public func updateFeedback(conversationId: String, messageId: String, feedback: MessageFeedback?) async throws -> Message {
        try await service.updateFeedback(conversationId: conversationId, messageId: messageId, feedback: feedback)
    }
}
