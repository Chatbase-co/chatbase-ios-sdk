import Foundation

// MARK: - Tool Results, Retry, Feedback

extension ChatService {

    // MARK: - Tool Results

    func submitToolResult(conversationId: String, toolCall: ToolCall, output: JSONValue, maxRetries: Int = 3) async throws {
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

    func retryMessage(conversationId: String, messageId: String) -> AsyncThrowingStream<StreamEvent, Error> {
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

