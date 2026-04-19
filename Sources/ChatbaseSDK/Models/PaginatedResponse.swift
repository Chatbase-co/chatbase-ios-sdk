import Foundation

public struct PaginatedResponse<T: Sendable>: Sendable {
    public let data: [T]
    public let hasMore: Bool
    public let total: Int
    private let fetchNext: @Sendable () async throws -> PaginatedResponse<T>

    public init(
        data: [T],
        hasMore: Bool,
        total: Int,
        fetchNext: @escaping @Sendable () async throws -> PaginatedResponse<T>
    ) {
        self.data = data
        self.hasMore = hasMore
        self.total = total
        self.fetchNext = fetchNext
    }

    public func loadMore() async throws -> PaginatedResponse<T>? {
        guard hasMore else { return nil }
        return try await fetchNext()
    }
}
