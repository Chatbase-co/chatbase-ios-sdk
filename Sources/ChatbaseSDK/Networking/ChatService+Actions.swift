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

    // MARK: - Feedback

    public func updateFeedback(conversationId: String, messageId: String, feedback: MessageFeedback?) async throws -> Message {
        let request = try buildJSONRequest(
            method: "PATCH",
            path: "/agents/\(agentId)/conversations/\(conversationId)/messages/\(messageId)/feedback",
            body: UpdateFeedbackRequestDTO(feedback: feedback?.rawValue)
        )
        let response: UpdateFeedbackResponseDTO = try await sendRequest(request)
        guard let message = mapMessage(response.data) else { throw ChatError.noContent }
        return message
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

struct UpdateFeedbackRequestDTO: Encodable {
    let feedback: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(feedback, forKey: .feedback)
    }

    enum CodingKeys: String, CodingKey {
        case feedback
    }
}

struct UpdateFeedbackResponseDTO: Decodable {
    let data: ConversationMessageDTO
}
