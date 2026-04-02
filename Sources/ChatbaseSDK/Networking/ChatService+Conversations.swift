import Foundation

// MARK: - Conversations

extension ChatService {

    public func listConversations(cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Conversation> {
        let request = try buildGETRequest(path: "/agents/\(agentId)/conversations", query: paginationQuery(cursor: cursor, limit: limit))
        let response: ListConversationsResponseDTO = try await sendRequest(request)
        return PaginatedResponse(
            data: response.data.map { mapConversation($0) },
            pagination: mapPagination(response.pagination)
        )
    }

    public func getConversation(_ conversationId: String) async throws -> (Conversation, [Message], Pagination) {
        let request = try buildGETRequest(path: "/agents/\(agentId)/conversations/\(conversationId)")
        let response: GetConversationResponseDTO = try await sendRequest(request)
        let d = response.data
        return (
            Conversation(
                id: d.id, title: d.title,
                createdAt: Date(timeIntervalSince1970: d.createdAt),
                updatedAt: Date(timeIntervalSince1970: d.updatedAt),
                userId: d.userId,
                status: ConversationStatus(rawValue: d.status) ?? .ongoing
            ),
            d.messages.compactMap { mapMessage($0) },
            mapPagination(response.pagination)
        )
    }

    public func listMessages(conversationId: String, cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Message> {
        let request = try buildGETRequest(
            path: "/agents/\(agentId)/conversations/\(conversationId)/messages",
            query: paginationQuery(cursor: cursor, limit: limit)
        )
        let response: ListMessagesResponseDTO = try await sendRequest(request)
        return PaginatedResponse(
            data: response.data.compactMap { mapMessage($0) },
            pagination: mapPagination(response.pagination)
        )
    }

    public func listUserConversations(userId: String, cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Conversation> {
        let request = try buildGETRequest(
            path: "/agents/\(agentId)/users/\(userId)/conversations",
            query: paginationQuery(cursor: cursor, limit: limit)
        )
        let response: ListConversationsResponseDTO = try await sendRequest(request)
        return PaginatedResponse(
            data: response.data.map { mapConversation($0) },
            pagination: mapPagination(response.pagination)
        )
    }
}

// MARK: - Conversation DTOs

struct ListConversationsResponseDTO: Decodable {
    let data: [ConversationDTO]
    let pagination: PaginationDTO
}

struct GetConversationResponseDTO: Decodable {
    let data: GetConversationDataDTO
    let pagination: PaginationDTO

    struct GetConversationDataDTO: Decodable {
        let id: String
        let title: String?
        let createdAt: Double
        let updatedAt: Double
        let userId: String?
        let status: String
        let messages: [ConversationMessageDTO]
    }
}

struct ListMessagesResponseDTO: Decodable {
    let data: [ConversationMessageDTO]
    let pagination: PaginationDTO
}
