import Foundation

// MARK: - Conversations

extension ChatService {

    func listConversations(cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Conversation> {
        let request = try buildGETRequest(path: "/agents/\(agentId)/conversations", query: paginationQuery(cursor: cursor, limit: limit))
        let response: ListConversationsResponseDTO = try await sendRequest(request)
        let nextCursor = response.pagination.cursor
        return PaginatedResponse(
            data: response.data.map { mapConversation($0) },
            hasMore: response.pagination.hasMore,
            total: response.pagination.total,
            fetchNext: { [self] in
                try await listConversations(cursor: nextCursor, limit: limit)
            }
        )
    }

    func listMessages(conversationId: String, cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Message> {
        let request = try buildGETRequest(
            path: "/agents/\(agentId)/conversations/\(conversationId)/messages",
            query: paginationQuery(cursor: cursor, limit: limit)
        )
        let response: ListMessagesResponseDTO = try await sendRequest(request)
        let nextCursor = response.pagination.cursor
        return PaginatedResponse(
            data: response.data.compactMap { mapMessage($0) },
            hasMore: response.pagination.hasMore,
            total: response.pagination.total,
            fetchNext: { [self] in
                try await listMessages(conversationId: conversationId, cursor: nextCursor, limit: limit)
            }
        )
    }

}

// MARK: - Conversation DTOs

struct ListConversationsResponseDTO: Decodable {
    let data: [ConversationDTO]
    let pagination: PaginationDTO
}

struct ListMessagesResponseDTO: Decodable {
    let data: [ConversationMessageDTO]
    let pagination: PaginationDTO
}
