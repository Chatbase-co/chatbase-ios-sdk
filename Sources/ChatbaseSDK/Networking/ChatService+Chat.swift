import Foundation

// MARK: - Chat & Streaming

extension ChatService {

    public func sendMessage(_ text: String, conversationId: String? = nil) async throws -> ChatResponse {
        try await collectStream(streamMessage(text, conversationId: conversationId))
    }

    /// Streams, collects, and transparently executes registered tool handlers.
    /// Continues the stream via POST /chat {conversationId} until finish reason is not `.toolCalls`,
    /// bounded to `maxIterations` turns.
    public func sendMessage(
        _ text: String,
        conversationId: String? = nil,
        registry: ToolRegistry,
        maxIterations: Int = 10
    ) async throws -> ChatResponse {
        var stream = streamMessage(text, conversationId: conversationId)
        var currentConversationId = conversationId

        for _ in 0..<maxIterations {
            let turn = try await collectTurn(stream)
            let cid = turn.finish.conversationId ?? currentConversationId
            currentConversationId = cid

            if turn.finish.finishReason != .toolCalls {
                guard let finalCid = cid else { throw ChatError.noContent }
                return ChatResponse(
                    message: Message(
                        id: turn.messageId ?? turn.finish.messageId ?? "",
                        text: turn.text,
                        sender: .agent,
                        date: .now,
                        parts: []
                    ),
                    conversationId: finalCid,
                    userMessageId: turn.finish.userMessageId,
                    finishReason: turn.finish.finishReason ?? .stop,
                    usage: turn.finish.usage ?? Usage(credits: 0)
                )
            }

            guard let cid, !turn.toolCalls.isEmpty else { throw ChatError.noContent }

            for tc in turn.toolCalls {
                guard let handler = await registry.handler(for: tc.toolName) else {
                    throw ChatError.toolHandlerMissing(name: tc.toolName)
                }
                let output: JSONValue
                do {
                    output = try await handler(tc.input)
                } catch {
                    output = .object(["error": .string(String(describing: error))])
                }
                try await submitToolResult(
                    conversationId: cid,
                    toolCall: tc,
                    output: output
                )
            }

            stream = continueConversation(cid)
        }

        throw ChatError.toolLoopExceeded(limit: maxIterations)
    }

    /// Subscribes to an SSE stream, accumulates text + tool calls + finish info,
    /// returns a terminal ChatResponse. Throws on decoding / network errors.
    /// Tool calls that appear in the stream are silently collected here; the
    /// auto-loop is run by `sendMessage(_:conversationId:registry:)` (Phase 4).
    func collectStream(_ raw: AsyncThrowingStream<StreamEvent, Error>) async throws -> ChatResponse {
        let turn = try await collectTurn(raw)
        guard let conversationId = turn.finish.conversationId else { throw ChatError.noContent }
        return ChatResponse(
            message: Message(
                id: turn.messageId ?? turn.finish.messageId ?? "",
                text: turn.text,
                sender: .agent,
                date: .now,
                parts: []
            ),
            conversationId: conversationId,
            userMessageId: turn.finish.userMessageId,
            finishReason: turn.finish.finishReason ?? .stop,
            usage: turn.finish.usage ?? Usage(credits: 0)
        )
    }

    struct CollectedTurn: Sendable {
        let messageId: String?
        let text: String
        let toolCalls: [ToolCall]
        let finish: StreamFinishInfo
    }

    func collectTurn(_ raw: AsyncThrowingStream<StreamEvent, Error>) async throws -> CollectedTurn {
        var messageId: String?
        var textBuffer = ""
        var pendingToolCalls: [ToolCall] = []
        var finish: StreamFinishInfo?

        for try await event in raw {
            switch event {
            case .messageStarted(let id): messageId = id
            case .textChunk(let chunk): textBuffer.append(chunk)
            case .toolCall(let tc): pendingToolCalls.append(tc)
            case .finished(let info): finish = info
            }
        }

        guard let meta = finish else { throw ChatError.noContent }
        return CollectedTurn(messageId: messageId, text: textBuffer, toolCalls: pendingToolCalls, finish: meta)
    }

    public func streamMessage(_ text: String, conversationId: String? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            return streamSSE(request: try buildChatRequest(message: text, conversationId: conversationId))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    // MARK: - Verify

    /// POST /verify with the given JWT; on success, promotes the session to identified.
    public func verify(token: String) async throws {
        let request = try buildJSONRequest(
            method: "POST",
            path: "/agents/\(agentId)/verify",
            body: VerifyRequestDTO(token: token)
        )
        let response: VerifyResponseDTO = try await sendRequest(request)
        guard let userId = response.data.userId, !userId.isEmpty else {
            throw ChatError.verifyResponseMissingUserId
        }
        updateAuth(.identified(token: token, userId: userId))
    }

    public func continueConversation(_ conversationId: String) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            return streamSSE(request: try buildChatRequest(message: nil, conversationId: conversationId))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    // MARK: - SSE

    func streamSSE(request: URLRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        let client = self.client

        Task { @Sendable in
            do {
                let (bytes, _) = try await client.streamLines(request: request)

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8) else { continue }

                    let event: StreamEventDTO
                    do {
                        event = try JSONDecoder().decode(StreamEventDTO.self, from: data)
                    } catch {
                        serviceLogger.error("Failed to decode SSE event: \(error.localizedDescription)")
                        continuation.finish(throwing: ChatError.decodingFailed(String(describing: error)))
                        return
                    }

                    switch event {
                    case .start(let messageId):
                        continuation.yield(.messageStarted(id: messageId))
                    case .textDelta(let delta):
                        continuation.yield(.textChunk(delta))
                    case .finish(let metadata):
                        continuation.yield(.finished(StreamFinishInfo(
                            conversationId: metadata.conversationId,
                            messageId: metadata.messageId,
                            userMessageId: metadata.userMessageId,
                            userId: metadata.userId,
                            finishReason: metadata.finishReason.flatMap { FinishReason(rawValue: $0) },
                            usage: metadata.usage.map { Usage(credits: $0.credits) }
                        )))
                    case .toolCall(let toolCallId, let toolName, let input):
                        continuation.yield(.toolCall(ToolCall(
                            toolCallId: toolCallId,
                            toolName: toolName,
                            input: input
                        )))
                    case .other:
                        continue
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        return stream
    }
}

// MARK: - Chat DTOs

struct VerifyRequestDTO: Encodable {
    let token: String
}

struct VerifyResponseDTO: Decodable {
    struct Data: Decodable { let userId: String? }
    let data: Data
}

// MARK: - SSE DTOs

enum StreamEventDTO: Decodable {
    case start(messageId: String)
    case textDelta(delta: String)
    case toolCall(toolCallId: String, toolName: String, input: JSONValue)
    case finish(metadata: StreamFinishMetadataDTO)
    case other

    enum CodingKeys: String, CodingKey {
        case type, messageId, delta, messageMetadata, toolName, toolCallId, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "start":
            self = .start(messageId: try container.decode(String.self, forKey: .messageId))
        case "text-delta":
            self = .textDelta(delta: try container.decode(String.self, forKey: .delta))
        case "finish":
            self = .finish(metadata: try container.decode(StreamFinishMetadataDTO.self, forKey: .messageMetadata))
        case "tool-input-available":
            self = .toolCall(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                toolName: try container.decode(String.self, forKey: .toolName),
                input: (try? container.decode(JSONValue.self, forKey: .input)) ?? .object([:])
            )
        default:
            self = .other
        }
    }
}

struct StreamFinishMetadataDTO: Decodable {
    let conversationId: String?
    let messageId: String?
    let userMessageId: String?
    let userId: String?
    let finishReason: String?
    let usage: UsageDTO?
}
