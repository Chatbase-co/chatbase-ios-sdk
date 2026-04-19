import Foundation

// MARK: - Tool Results, Retry, Feedback

extension ChatService {

    // MARK: - Tool Results

    public func submitToolResult(conversationId: String, toolCall: ToolCall, output: JSONValue, maxRetries: Int = 3) async throws {
        let request = try buildJSONRequest(
            method: "POST",
            path: "/agents/\(agentId)/conversations/\(conversationId)/tool-result",
            body: ToolResultRequestDTO(toolCallId: toolCall.toolCallId, output: output)
        )

        var lastError: Error = APIError.invalidResponse
        var delay: Duration = .milliseconds(300)

        for attempt in 1...maxRetries {
            do {
                let _: ToolResultResponseDTO = try await sendRequest(request)
                return
            } catch let error as APIError where error.statusCode == 404 && attempt < maxRetries {
                lastError = error
                serviceLogger.warning("Tool result not ready (attempt \(attempt)/\(maxRetries)), retrying...")
                try await Task.sleep(for: delay)
                delay *= 2
            } catch where attempt < maxRetries {
                lastError = error
                serviceLogger.warning("Tool result submission failed (attempt \(attempt)/\(maxRetries)), retrying...")
                try await Task.sleep(for: delay)
                delay *= 2
            }
        }
        throw lastError
    }

    // MARK: - Retry

    public func retryMessage(conversationId: String, messageId: String) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            let request = try buildJSONRequest(
                method: "POST",
                path: "/agents/\(agentId)/conversations/\(conversationId)/retry",
                body: RetryRequestDTO(messageId: messageId, stream: true)
            )
            return streamSSE(request: request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    /// Blocking retry that drives the same tool loop as sendMessage:
    /// seed stream = POST /conversations/{id}/retry {messageId, stream:true},
    /// continuation turns via POST /chat {conversationId, stream:true}.
    public func retry(
        conversationId: String,
        messageId: String,
        registry: ToolRegistry,
        maxIterations: Int = 10
    ) async throws -> ChatResponse {
        var stream = retryMessage(conversationId: conversationId, messageId: messageId)
        var currentConversationId: String? = conversationId

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
                try await submitToolResult(conversationId: cid, toolCall: tc, output: output)
            }

            stream = continueConversation(cid)
        }

        throw ChatError.toolLoopExceeded(limit: maxIterations)
    }

}

// MARK: - Action DTOs

struct ToolResultRequestDTO: Encodable {
    let toolCallId: String
    let output: JSONValue
}

struct ToolResultResponseDTO: Decodable {
    let data: ToolResultSuccessDTO
    struct ToolResultSuccessDTO: Decodable { let success: Bool }
}

struct RetryRequestDTO: Encodable {
    let messageId: String
    let stream: Bool
}

