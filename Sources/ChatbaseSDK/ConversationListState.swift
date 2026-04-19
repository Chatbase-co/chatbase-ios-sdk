import Foundation
import Observation

/// Observable list of the user's conversations. Parallels Android's
/// `ConversationListState`.
@MainActor
@Observable
public final class ConversationListState {
    public private(set) var conversations: [Conversation] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = false
    public private(set) var error: Error?

    @ObservationIgnored private let client: ChatbaseClient
    @ObservationIgnored private var page: PaginatedResponse<Conversation>?

    public init(client: ChatbaseClient) {
        self.client = client
    }

    public func load(limit: Int = 20) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let p = try await client.listConversations(limit: limit)
            conversations = p.data
            hasMore = p.hasMore
            page = p
        } catch {
            self.error = error
        }
    }

    public func loadMore() async {
        guard let page, page.hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let next = try await page.loadMore() else {
                hasMore = false
                return
            }
            conversations.append(contentsOf: next.data)
            hasMore = next.hasMore
            self.page = next
        } catch {
            self.error = error
        }
    }

    public func clearError() {
        error = nil
    }
}
