import Foundation

// MARK: - Chat & Streaming

extension ChatService {

    public func sendMessage(_ text: String, conversationId: String? = nil, userId: String? = nil) async throws -> ChatResponse {
        let request = try buildChatRequest(message: text, conversationId: conversationId, stream: false, userId: userId)
        let response: ChatResponseDTO = try await sendRequest(request)

        let parts = mapParts(response.data.parts)
        let responseText = extractText(from: response.data.parts)
        let meta = response.data.metadata

        return ChatResponse(
            message: Message(
                id: response.data.id,
                text: responseText ?? "",
                sender: .agent,
                date: .now,
                parts: parts
            ),
            conversationId: meta.conversationId,
            userMessageId: meta.userMessageId,
            finishReason: FinishReason(rawValue: meta.finishReason) ?? .stop,
            usage: Usage(credits: meta.usage.credits)
        )
    }

    public func streamMessage(_ text: String, conversationId: String? = nil, userId: String? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            return streamSSE(request: try buildChatRequest(message: text, conversationId: conversationId, stream: true, userId: userId))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func continueConversation(_ conversationId: String) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            return streamSSE(request: try buildChatRequest(message: nil, conversationId: conversationId, stream: true))
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
                var lastKnownEventTime = ContinuousClock.now

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8) else { continue }

                    do {
                        let event = try JSONDecoder().decode(StreamEventDTO.self, from: data)
                        switch event {
                        case .start(let messageId):
                            lastKnownEventTime = .now
                            continuation.yield(.messageStarted(id: messageId))
                        case .textDelta(let delta):
                            lastKnownEventTime = .now
                            continuation.yield(.textChunk(delta))
                        case .finish(let metadata):
                            lastKnownEventTime = .now
                            continuation.yield(.finished(StreamFinishInfo(
                                conversationId: metadata.conversationId,
                                messageId: metadata.messageId,
                                userMessageId: metadata.userMessageId,
                                userId: metadata.userId,
                                finishReason: metadata.finishReason.flatMap { FinishReason(rawValue: $0) },
                                usage: metadata.usage.map { Usage(credits: $0.credits) }
                            )))
                        case .toolCall(let toolCallId, let toolName, let input):
                            lastKnownEventTime = .now
                            continuation.yield(.toolCall(ToolCall(
                                toolCallId: toolCallId,
                                toolName: toolName,
                                input: input
                            )))
                        case .other:
                            if ContinuousClock.now - lastKnownEventTime > .seconds(10) {
                                continuation.finish(throwing: ChatError.streamTimeout)
                                return
                            }
                        }
                    } catch {
                        serviceLogger.error("Failed to decode SSE event: \(error.localizedDescription)")
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

struct ChatResponseDTO: Decodable {
    let data: ChatResponseDataDTO
}

struct ChatResponseDataDTO: Decodable {
    let id: String
    let role: String
    let parts: [MessagePartDTO]
    let metadata: ChatResponseMetadataDTO
}

struct ChatResponseMetadataDTO: Decodable {
    let conversationId: String
    let userMessageId: String?
    let userId: String?
    let finishReason: String
    let usage: UsageDTO
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
