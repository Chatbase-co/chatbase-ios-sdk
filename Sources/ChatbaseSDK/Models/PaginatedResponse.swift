import Foundation

public struct PaginatedResponse<T: Sendable>: Sendable {
    public let data: [T]
    public let pagination: Pagination

    public init(data: [T], pagination: Pagination) {
        self.data = data
        self.pagination = pagination
    }
}

public struct Pagination: Sendable {
    public let cursor: String?
    public let hasMore: Bool
    public let total: Int

    public init(cursor: String?, hasMore: Bool, total: Int) {
        self.cursor = cursor
        self.hasMore = hasMore
        self.total = total
    }
}
