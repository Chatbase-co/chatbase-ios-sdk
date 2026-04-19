//
//  ChatServiceTests.swift
//  tatbeeqMa7moolTests
//

import Testing
@testable import ChatbaseSDK
import Foundation

@Suite("ChatService")
struct ChatServiceTests {

    private let mockClient = MockAPIClient()
    private var service: ChatService {
        ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device"
        )
    }

    // MARK: - sendMessage

    @Test("sendMessage streams and collects into ChatResponse")
    func sendMessageStreamsAndCollects() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\", world\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-1\",\"userMessageId\":\"user-msg-1\",\"userId\":null,\"finishReason\":\"stop\",\"usage\":{\"credits\":1}}}",
            "data: [DONE]"
        ])

        let response = try await service.sendMessage("Hi")

        await #expect(response.message.id == "msg-1")
        await #expect(response.message.text == "Hello, world")
        await #expect(response.message.sender == .agent)
        await #expect(response.conversationId == "conv-1")
        await #expect(response.userMessageId == "user-msg-1")
        await #expect(response.finishReason == .stop)
        await #expect(response.usage.credits == 1)
    }

    @Test("sendMessage request body omits the stream field and includes conversationId")
    func sendMessageBodyOmitsStream() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"m\",\"userMessageId\":\"user-msg-2\",\"userId\":null,\"finishReason\":\"stop\",\"usage\":{\"credits\":1}}}",
            "data: [DONE]"
        ])
        _ = try await service.sendMessage("Follow up", conversationId: "conv-1")

        let body = try #require(mockClient.lastRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["conversationId"] as? String == "conv-1")
        #expect(json["message"] as? String == "Follow up")
        #expect(json["stream"] == nil)
    }

    @Test("sendMessage surfaces tool-calls finish reason (parts not materialized)")
    func sendMessageToolCallsFinish() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"my_tool\",\"input\":{\"key\":\"val\"}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-1\",\"userMessageId\":\"user-msg-1\",\"userId\":null,\"finishReason\":\"tool-calls\",\"usage\":{\"credits\":2}}}",
            "data: [DONE]"
        ])

        let response = try await service.sendMessage("Do something")
        #expect(response.finishReason == .toolCalls)
        #expect(response.conversationId == "conv-1")
    }

    @Test("sendMessage returns empty text when no text deltas are emitted")
    func sendMessageNoText() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-1\",\"userMessageId\":null,\"userId\":null,\"finishReason\":\"stop\",\"usage\":{\"credits\":0}}}",
            "data: [DONE]"
        ])

        let response = try await service.sendMessage("Hi")
        await #expect(response.message.text == "")
        #expect(response.finishReason == .stop)
    }

    @Test("propagates HTTP errors with code and status")
    func sendMessageHTTPError() async throws {
        mockClient.respondWithError(
            APIError.httpError(
                statusCode: 402,
                detail: APIErrorDetail(code: "CHAT_CREDITS_EXHAUSTED", message: "Message limit reached", details: nil)
            )
        )

        do {
            _ = try await service.sendMessage("Hi")
            Issue.record("Expected error")
        } catch let error as APIError {
            #expect(error.statusCode == 402)
            #expect(error.apiCode == "CHAT_CREDITS_EXHAUSTED")
        }
    }

    // MARK: - streamMessage

    @Test("emits start, text chunks, and finish with metadata")
    func streamMessageEvents() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\" world\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-1\",\"userMessageId\":\"user-1\",\"userId\":null,\"finishReason\":\"stop\",\"usage\":{\"credits\":1}}}",
            "data: [DONE]"
        ])

        var events: [StreamEvent] = []
        for try await event in await service.streamMessage("Hi") {
            events.append(event)
        }

        #expect(events.count == 4)

        guard case .messageStarted(let id) = events[0] else {
            Issue.record("Expected messageStarted"); return
        }
        #expect(id == "msg-1")

        guard case .textChunk(let t1) = events[1] else {
            Issue.record("Expected textChunk"); return
        }
        #expect(t1 == "Hello")

        guard case .textChunk(let t2) = events[2] else {
            Issue.record("Expected textChunk"); return
        }
        #expect(t2 == " world")

        guard case .finished(let info) = events[3] else {
            Issue.record("Expected finished"); return
        }
        #expect(info.conversationId == "conv-1")
        #expect(info.finishReason == .stop)
        await #expect(info.usage?.credits == 1)
        #expect(info.userMessageId == "user-1")
    }

    @Test("emits tool call with input")
    func streamMessageToolCall() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"open_camera\",\"input\":{\"mode\":\"photo\"}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        var events: [StreamEvent] = []
        for try await event in await service.streamMessage("Take a photo") {
            events.append(event)
        }

        #expect(events.count == 3)

        guard case .toolCall(let tc) = events[1] else {
            Issue.record("Expected toolCall"); return
        }
        #expect(tc.toolCallId == "call-1")
        #expect(tc.toolName == "open_camera")
        #expect(tc.input["mode"] == .string("photo"))

        guard case .finished(let info) = events[2] else {
            Issue.record("Expected finished"); return
        }
        #expect(info.finishReason == .toolCalls)
    }

    // MARK: - continueConversation

    @Test("omits message field, sends conversationId")
    func continueConversationRequest() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Done!\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\"}}",
            "data: [DONE]"
        ])

        var events: [StreamEvent] = []
        for try await event in await service.continueConversation("conv-1") {
            events.append(event)
        }

        #expect(events.count == 3)

        let body = try #require(mockClient.lastRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["message"] == nil || json["message"] is NSNull)
        #expect(json["conversationId"] as? String == "conv-1")
        #expect(json["stream"] == nil)
    }

    // MARK: - submitToolResult

    @Test("sends toolCallId and output")
    func submitToolResultBody() async throws {
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)

        let toolCall = ToolCall(toolCallId: "call-1", toolName: "my_tool", input: .object([:]))
        try await service.submitToolResult(conversationId: "conv-1", toolCall: toolCall, output: .object(["result": .string("done")]))

        let body = try #require(mockClient.lastRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["toolCallId"] as? String == "call-1")

        let path = mockClient.lastRequest?.url?.path ?? ""
        #expect(path.contains("conv-1"))
        #expect(path.contains("tool-result"))
    }

    @Test("retries on 404 with exponential backoff")
    func submitToolResultRetries() async throws {
        mockClient.respondWithError(
            APIError.httpError(statusCode: 404, detail: APIErrorDetail(code: "NOT_FOUND", message: "Not found", details: nil))
        )
        mockClient.respondWithError(
            APIError.httpError(statusCode: 404, detail: APIErrorDetail(code: "NOT_FOUND", message: "Not found", details: nil))
        )
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)

        let toolCall = ToolCall(toolCallId: "call-1", toolName: "my_tool", input: .object([:]))
        try await service.submitToolResult(conversationId: "conv-1", toolCall: toolCall, output: .object(["status": .string("ok")]))

        #expect(mockClient.requestCount == 3)
    }

    @Test("throws after max retries exhausted")
    func submitToolResultMaxRetries() async {
        for _ in 1...3 {
            mockClient.respondWithError(
                APIError.httpError(statusCode: 404, detail: APIErrorDetail(code: "NOT_FOUND", message: "Not found", details: nil))
            )
        }

        let toolCall = ToolCall(toolCallId: "call-1", toolName: "my_tool", input: .object([:]))

        do {
            try await service.submitToolResult(conversationId: "conv-1", toolCall: toolCall, output: .null)
            Issue.record("Expected error")
        } catch let error as APIError {
            #expect(error.statusCode == 404)
        }
        catch let error {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - listConversations

    @Test("maps conversations and pagination")
    func listConversationsMapping() async throws {
        mockClient.respondWithRawJSON("""
        {
            "data": [{
                "id": "conv-1",
                "title": "Test Chat",
                "createdAt": 1700000000,
                "updatedAt": 1700001000,
                "userId": "user-1",
                "status": "ongoing"
            }],
            "pagination": {"cursor": "next-page", "hasMore": true, "total": 42}
        }
        """)

        let response = try await service.listConversations()

        #expect(response.data.count == 1)
        await #expect(response.data[0].id == "conv-1")
        await #expect(response.data[0].title == "Test Chat")
        await #expect(response.data[0].userId == "user-1")
        await #expect(response.data[0].status == .ongoing)
        #expect(response.hasMore == true)
        #expect(response.total == 42)
    }

    @Test("URLSessionClient streaming session uses configured timeout")
    func streamingTimeoutConfigurable() {
        let client = URLSessionClient(streamIdleTimeout: 120)
        #expect(client.streamSessionTimeout == 120)

        let defaultClient = URLSessionClient()
        #expect(defaultClient.streamSessionTimeout == 300)
    }

    @Test("conversations decode epoch-ms timestamps as Date")
    func conversationsEpochMsTimestamps() async throws {
        // 1704067200000 ms = 2024-01-01T00:00:00Z
        mockClient.respondWithRawJSON("""
        {
          "data": [{
            "id": "c-1",
            "title": null,
            "createdAt": 1704067200000,
            "updatedAt": 1704067200000,
            "userId": null,
            "status": "ongoing"
          }],
          "pagination": {"cursor": null, "hasMore": false, "total": 1}
        }
        """)

        let page = try await service.listConversations()
        let first = try #require(page.data.first)
        let expected = Date(timeIntervalSince1970: 1704067200)
        #expect(abs(first.createdAt.timeIntervalSince(expected)) < 0.001)
        #expect(abs(first.updatedAt.timeIntervalSince(expected)) < 0.001)
    }

    @Test("passes cursor and limit as query params")
    func listConversationsQueryParams() async throws {
        mockClient.respondWithRawJSON("""
        {"data": [], "pagination": {"cursor": null, "hasMore": false, "total": 0}}
        """)

        _ = try await service.listConversations(cursor: "abc", limit: 10)

        let url = mockClient.lastRequest?.url?.absoluteString ?? ""
        #expect(url.contains("cursor=abc"))
        #expect(url.contains("limit=10"))
    }

    @Test("loadMore fetches next page with server cursor")
    func listConversationsLoadMore() async throws {
        mockClient.respondWithRawJSON("""
        {
            "data": [{"id": "conv-1", "title": null, "createdAt": 1700000000, "updatedAt": 1700000000, "userId": null, "status": "ongoing"}],
            "pagination": {"cursor": "page-2", "hasMore": true, "total": 2}
        }
        """)

        let first = try await service.listConversations(limit: 1)
        #expect(first.hasMore == true)

        mockClient.respondWithRawJSON("""
        {
            "data": [{"id": "conv-2", "title": null, "createdAt": 1700000001, "updatedAt": 1700000001, "userId": null, "status": "ongoing"}],
            "pagination": {"cursor": null, "hasMore": false, "total": 2}
        }
        """)

        let second = try await first.loadMore()
        #expect(second != nil)
        #expect(second?.data.count == 1)
        #expect(second?.hasMore == false)

        let url = mockClient.lastRequest?.url?.absoluteString ?? ""
        #expect(url.contains("cursor=page-2"))
        #expect(url.contains("limit=1"))
    }

    @Test("loadMore returns nil when hasMore is false")
    func loadMoreReturnsNil() async throws {
        mockClient.respondWithRawJSON("""
        {"data": [], "pagination": {"cursor": null, "hasMore": false, "total": 0}}
        """)

        let response = try await service.listConversations()
        let next = try await response.loadMore()
        #expect(next == nil)
    }

    // MARK: - listMessages

    @Test("maps messages with score and feedback")
    func listMessagesMaps() async throws {
        mockClient.respondWithRawJSON("""
        {
            "data": [
                {"id": "msg-1", "role": "user", "parts": [{"type": "text", "text": "Hi"}], "createdAt": 1700000000, "feedback": null},
                {"id": "msg-2", "role": "assistant", "parts": [{"type": "text", "text": "Hello!"}], "createdAt": 1700000001, "feedback": "positive", "metadata": {"score": 0.85}}
            ],
            "pagination": {"cursor": "prev", "hasMore": true, "total": 10}
        }
        """)

        let response = try await service.listMessages(conversationId: "conv-1")

        #expect(response.data.count == 2)
        #expect(response.data[0].sender == .user)
        #expect(response.data[0].text == "Hi")
        #expect(response.data[1].sender == .agent)
        #expect(response.data[1].feedback == .positive)
        #expect(response.data[1].score == 0.85)
        #expect(response.hasMore == true)
    }

    @Test("filters messages with no displayable text")
    func listMessagesFiltersEmpty() async throws {
        mockClient.respondWithRawJSON("""
        {
            "data": [
                {"id": "msg-1", "role": "user", "parts": [{"type": "text", "text": "Hi"}], "createdAt": 1700000000, "feedback": null},
                {"id": "msg-2", "role": "assistant", "parts": [{"type": "tool-call", "toolCallId": "c1", "toolName": "t1", "input": {}}], "createdAt": null, "feedback": null},
                {"id": "msg-3", "role": "user", "parts": [{"type": "text", "text": ""}], "createdAt": 1700000002, "feedback": null},
                {"id": "msg-4", "role": "assistant", "parts": [{"type": "tool-call", "toolCallId": "c1", "toolName": "t1", "input": {}}, {"type": "text", "text": "Done!"}], "createdAt": 1700000003, "feedback": null}
            ],
            "pagination": {"cursor": null, "hasMore": false, "total": 4}
        }
        """)

        let response = try await service.listMessages(conversationId: "conv-1")

        // msg-1: has text, kept
        // msg-2: tool-call only, no text, filtered
        // msg-3: empty text, filtered
        // msg-4: tool-call + text, kept
        #expect(response.data.count == 2)
        #expect(response.data[0].id == "msg-1")
        #expect(response.data[1].id == "msg-4")
        #expect(response.data[1].text == "Done!")
    }

    // MARK: - Request validation

    @Test("includes X-Device-Id header and no X-User-Token when anonymous")
    func anonymousHeaders() async throws {
        mockClient.respondWithRawJSON("""
        {"data": [], "pagination": {"cursor": null, "hasMore": false, "total": 0}}
        """)

        _ = try await service.listConversations()

        #expect(mockClient.lastRequest?.value(forHTTPHeaderField: "X-Device-Id") == "test-device")
        #expect(mockClient.lastRequest?.value(forHTTPHeaderField: "X-User-Token") == nil)
        #expect(mockClient.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("sends SDK User-Agent header")
    func sdkUserAgentHeader() async throws {
        mockClient.respondWithRawJSON("""
        {"data": [], "pagination": {"cursor": null, "hasMore": false, "total": 0}}
        """)

        _ = try await service.listConversations()

        let ua = mockClient.lastRequest?.value(forHTTPHeaderField: "User-Agent")
        #expect(ua?.hasPrefix("Chatbase-iOS-SDK/") == true)
    }

    @Test("includes X-User-Token when identified")
    func identifiedHeaders() async throws {
        let identified = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device",
            auth: .identified(token: "jwt-abc", userId: "user-1")
        )

        mockClient.respondWithRawJSON("""
        {"data": [], "pagination": {"cursor": null, "hasMore": false, "total": 0}}
        """)

        _ = try await identified.listConversations()

        #expect(mockClient.lastRequest?.value(forHTTPHeaderField: "X-Device-Id") == "test-device")
        #expect(mockClient.lastRequest?.value(forHTTPHeaderField: "X-User-Token") == "jwt-abc")
    }

    // MARK: - verify

    @Test("verify posts token in body and promotes session to identified")
    func verifyFlow() async throws {
        let svc = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device"
        )

        mockClient.respondWithRawJSON("""
        {"data": {"userId": "user-xyz"}}
        """)

        try await svc.verify(token: "jwt-xyz")

        #expect(svc.authState == .identified(token: "jwt-xyz", userId: "user-xyz"))

        #expect(mockClient.lastRequest?.httpMethod == "POST")
        #expect(mockClient.lastRequest?.url?.path.hasSuffix("/agents/test-agent/verify") == true)
        #expect(mockClient.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(mockClient.lastRequest?.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded["token"] == "jwt-xyz")
    }

    @Test("verify throws when userId is missing")
    func verifyThrowsMissingUserId() async throws {
        let svc = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device"
        )

        mockClient.respondWithRawJSON("""
        {"data": {}}
        """)

        do {
            try await svc.verify(token: "jwt-abc")
            Issue.record("Expected verifyResponseMissingUserId")
        } catch ChatError.verifyResponseMissingUserId {
            // expected
        }

        #expect(svc.authState == .anonymous)
    }

    @Test("verify 401 leaves auth state anonymous and surfaces status code")
    func verify401StaysAnonymous() async throws {
        let svc = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device"
        )

        mockClient.respondWithError(
            APIError.httpError(
                statusCode: 401,
                detail: APIErrorDetail(code: "UNAUTHORIZED", message: "Invalid token", details: nil)
            )
        )

        do {
            try await svc.verify(token: "bad-token")
            Issue.record("Expected error")
        } catch let error as APIError {
            #expect(error.statusCode == 401)
            #expect(error.apiCode == "UNAUTHORIZED")
        }

        #expect(svc.authState == .anonymous)
    }

    @Test("streamMessage 401 surfaces httpError via the stream")
    func streamMessage401() async throws {
        mockClient.respondWithError(
            APIError.httpError(
                statusCode: 401,
                detail: APIErrorDetail(code: "UNAUTHORIZED", message: "Token expired", details: nil)
            )
        )

        do {
            for try await _ in service.streamMessage("Hi") {}
            Issue.record("Expected error")
        } catch let error as APIError {
            #expect(error.statusCode == 401)
            #expect(error.apiCode == "UNAUTHORIZED")
        }
    }

    @Test("uses configured base URL and agent ID")
    func baseURLAndAgentId() async throws {
        mockClient.respondWithRawJSON("""
        {"data": [], "pagination": {"cursor": null, "hasMore": false, "total": 0}}
        """)

        _ = try await service.listConversations()

        let url = mockClient.lastRequest?.url?.absoluteString ?? ""
        #expect(url.hasPrefix("https://test.api.com/v2"))
        #expect(url.contains("/agents/test-agent/"))
    }
}

// MARK: - ChatError Equatable for tests

extension ChatError: Equatable {
    public static func == (lhs: ChatError, rhs: ChatError) -> Bool {
        switch (lhs, rhs) {
        case (.noContent, .noContent): return true
        case (.decodingFailed, .decodingFailed): return true
        default: return false
        }
    }
}
