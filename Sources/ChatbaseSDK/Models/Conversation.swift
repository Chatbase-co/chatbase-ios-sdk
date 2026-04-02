import Foundation

public enum ConversationStatus: String, Decodable, Sendable {
    case ongoing
    case ended
    case takenOver = "taken_over"
}

public struct Conversation: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let userId: String?
    public let status: ConversationStatus

    public init(id: String, title: String?, createdAt: Date, updatedAt: Date, userId: String?, status: ConversationStatus) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userId = userId
        self.status = status
    }
}
