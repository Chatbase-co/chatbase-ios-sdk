import Testing
@testable import ChatbaseSDK
import Foundation

@Suite("ConversationState")
@MainActor
struct ConversationStateTests {

    let mockClient = MockAPIClient()

    private var client: ChatbaseClient {
        let service = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device"
        )
        return ChatbaseClient(service: service)
    }

    // MARK: - sendMessage

    @Test("sendMessage streams deltas into an assistant placeholder and stamps messageId on finish")
    func sendMessageStreamsText() async throws {
        let state = ConversationState(client: client)

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Hel\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"lo\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"m1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        await state.sendMessage("Hi")

        #expect(state.messages.count == 2)
        #expect(state.messages[0].sender == .user)
        if case .text(let userText) = state.messages[0].kind { #expect(userText == "Hi") }
        #expect(state.messages[1].sender == .agent)
        if case .text(let agentText) = state.messages[1].kind { #expect(agentText == "Hello") }
        #expect(state.messages[1].isStreaming == false)
        #expect(state.messages[1].messageId == "m1")
        #expect(state.conversationId == "conv-1")
        #expect(state.isSending == false)
    }

    @Test("sendMessage trims whitespace and ignores empty input")
    func sendMessageIgnoresBlank() async throws {
        let state = ConversationState(client: client)
        await state.sendMessage("   ")
        #expect(state.messages.isEmpty)
    }

    @Test("sendMessage renders a tool-call card and a continuation placeholder")
    func sendMessageWithToolCall() async throws {
        let c = client
        c.tool("ping") { _ in .object(["ok": .bool(true)]) }
        let state = ConversationState(client: c)

        // Turn 1: text then tool call
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Running\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"tc-1\",\"toolName\":\"ping\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        // Submit tool result
        mockClient.respondWithRawJSON(#"{"data": {"success": true}}"#)
        // Continuation turn
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Done!\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"m2\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        await state.sendMessage("Do it")

        // [user, "Running", tool card (done), "Done!"]
        #expect(state.messages.count == 4)
        #expect(state.messages[0].sender == .user)
        if case .text(let t) = state.messages[1].kind { #expect(t == "Running") }
        #expect(state.messages[1].isStreaming == false)
        if case .toolCall(_, let name, _, let output, let isExecuting) = state.messages[2].kind {
            #expect(name == "ping")
            #expect(isExecuting == false)
            #expect(output != nil)
        } else {
            Issue.record("Expected tool-call card at index 2")
        }
        if case .text(let t) = state.messages[3].kind { #expect(t == "Done!") }
        #expect(state.messages[3].isStreaming == false)
        #expect(state.messages[3].messageId == "m2")
    }

    @Test("sendMessage marks streaming message as error on throw")
    func sendMessageError() async throws {
        let state = ConversationState(client: client)
        mockClient.respondWithError(APIError.invalidResponse)

        await state.sendMessage("boom")

        #expect(state.error != nil)
        let agent = state.messages.last!
        #expect(agent.sender == .agent)
        #expect(agent.isError == true)
        #expect(agent.isStreaming == false)
    }

    // MARK: - loadHistory

    @Test("loadHistory populates messages in chronological order and sets hasMoreHistory")
    func loadHistoryOrder() async throws {
        let state = ConversationState(client: client)
        mockClient.respondWithRawJSON("""
        {
          "data": [
            {"id":"b","role":"assistant","parts":[{"type":"text","text":"second"}],"createdAt":2.0},
            {"id":"a","role":"user","parts":[{"type":"text","text":"first"}],"createdAt":1.0}
          ],
          "pagination": {"cursor":"c1","hasMore":true,"total":5}
        }
        """)

        await state.loadHistory(conversationId: "conv-9")

        #expect(state.messages.count == 2)
        #expect(state.messages[0].messageId == "a")
        #expect(state.messages[1].messageId == "b")
        #expect(state.hasMoreHistory == true)
        #expect(state.conversationId == "conv-9")
    }

    @Test("loadMoreHistory prepends older messages and dedupes by messageId")
    func loadMoreHistoryDedupe() async throws {
        let state = ConversationState(client: client)

        // First page
        mockClient.respondWithRawJSON("""
        {
          "data": [
            {"id":"b","role":"assistant","parts":[{"type":"text","text":"B"}],"createdAt":2.0}
          ],
          "pagination": {"cursor":"c1","hasMore":true,"total":2}
        }
        """)
        await state.loadHistory(conversationId: "conv-9")
        #expect(state.messages.map(\.messageId) == ["b"])

        // Second page: contains overlap ("b") and older ("a")
        mockClient.respondWithRawJSON("""
        {
          "data": [
            {"id":"b","role":"assistant","parts":[{"type":"text","text":"B"}],"createdAt":2.0},
            {"id":"a","role":"user","parts":[{"type":"text","text":"A"}],"createdAt":1.0}
          ],
          "pagination": {"cursor":null,"hasMore":false,"total":2}
        }
        """)
        await state.loadMoreHistory()

        #expect(state.messages.map(\.messageId) == ["a", "b"])
        #expect(state.hasMoreHistory == false)
    }

    // MARK: - retry

    @Test("retry truncates from target messageId and re-streams")
    func retryTruncates() async throws {
        let state = ConversationState(client: client)
        mockClient.respondWithRawJSON("""
        {
          "data": [
            {"id":"m2","role":"assistant","parts":[{"type":"text","text":"old"}],"createdAt":2.0},
            {"id":"m1","role":"user","parts":[{"type":"text","text":"q"}],"createdAt":1.0}
          ],
          "pagination": {"cursor":null,"hasMore":false,"total":2}
        }
        """)
        await state.loadHistory(conversationId: "conv-1")
        #expect(state.messages.count == 2)

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m3\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"new\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"m3\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        await state.retry(messageId: "m2")

        #expect(state.messages.count == 2)
        #expect(state.messages[0].messageId == "m1")
        #expect(state.messages[1].messageId == "m3")
        if case .text(let t) = state.messages[1].kind { #expect(t == "new") }
    }

    // MARK: - clearError / clear

    @Test("clearError resets error state")
    func clearErrorResets() async throws {
        let state = ConversationState(client: client)
        mockClient.respondWithError(APIError.invalidResponse)
        await state.sendMessage("boom")
        #expect(state.error != nil)

        state.clearError()
        #expect(state.error == nil)
    }

    @Test("clear resets messages and conversationId")
    func clearResets() async throws {
        let state = ConversationState(client: client)
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"hi\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"m1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])
        await state.sendMessage("hi")
        #expect(state.messages.isEmpty == false)
        #expect(state.conversationId == "conv-1")

        state.clear()
        #expect(state.messages.isEmpty)
        #expect(state.conversationId == nil)
    }
}

@Suite("ConversationListState")
@MainActor
struct ConversationListStateTests {

    let mockClient = MockAPIClient()

    private var client: ChatbaseClient {
        let service = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device"
        )
        return ChatbaseClient(service: service)
    }

    @Test("load populates conversations and hasMore")
    func loadPopulates() async throws {
        let state = ConversationListState(client: client)
        mockClient.respondWithRawJSON("""
        {
          "data": [
            {"id":"c1","title":"One","createdAt":1.0,"updatedAt":1.0,"userId":null,"status":"ongoing"}
          ],
          "pagination": {"cursor":"x","hasMore":true,"total":2}
        }
        """)

        await state.load()

        #expect(state.conversations.count == 1)
        #expect(state.conversations[0].id == "c1")
        #expect(state.hasMore == true)
        #expect(state.isLoading == false)
    }

    @Test("loadMore appends next page")
    func loadMoreAppends() async throws {
        let state = ConversationListState(client: client)
        mockClient.respondWithRawJSON("""
        {
          "data": [{"id":"c1","title":"One","createdAt":1.0,"updatedAt":1.0,"userId":null,"status":"ongoing"}],
          "pagination": {"cursor":"x","hasMore":true,"total":2}
        }
        """)
        await state.load()

        mockClient.respondWithRawJSON("""
        {
          "data": [{"id":"c2","title":"Two","createdAt":2.0,"updatedAt":2.0,"userId":null,"status":"ongoing"}],
          "pagination": {"cursor":null,"hasMore":false,"total":2}
        }
        """)
        await state.loadMore()

        #expect(state.conversations.map(\.id) == ["c1", "c2"])
        #expect(state.hasMore == false)
    }

    @Test("load records error on failure")
    func loadError() async throws {
        let state = ConversationListState(client: client)
        mockClient.respondWithError(APIError.invalidResponse)
        await state.load()
        #expect(state.error != nil)
    }
}
