//
//  ChatbaseClientTests.swift
//  tatbeeqMa7moolTests
//

import Testing
@testable import ChatbaseSDK
import Foundation

@Suite("ChatbaseClient")
struct ChatbaseClientTests {

    private let mockClient = MockAPIClient()

    private var client: ChatbaseClient {
        let service = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device"
        )
        return ChatbaseClient(service: service)
    }

    // MARK: - Streaming text

    @Test("streams text as .text events")
    func streamText() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\" world\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-1\",\"finishReason\":\"stop\",\"usage\":{\"credits\":1}}}",
            "data: [DONE]"
        ])

        var texts: [String] = []
        var finishInfo: StreamFinishInfo?

        for try await event in client.stream("Hi") {
            switch event {
            case .text(let chunk): texts.append(chunk)
            case .finished(let info): finishInfo = info
            default: break
            }
        }

        #expect(texts == ["Hello", " world"])
        #expect(finishInfo?.conversationId == "conv-1")
        #expect(finishInfo?.finishReason == .stop)
    }

    // MARK: - Tool calls in stream

    @Test("tool call appears as .toolCall event")
    func toolCallInStream() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"my_tool\",\"input\":{\"key\":\"val\"}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        var receivedCall: ToolCallHandle?

        // Pass conversationId: tool call arrives before finish event in the SSE stream
        for try await event in await client.stream("Do it", conversationId: "conv-1") {
            if case .toolCall(let call) = event {
                receivedCall = call
                await call.ignore()
            }
        }

        #expect(receivedCall?.toolCallId == "call-1")
        #expect(receivedCall?.toolName == "my_tool")
        #expect(receivedCall?.input["key"] == .string("val"))
        #expect(receivedCall?.conversationId == "conv-1")
    }

    // MARK: - resolve

    @Test("resolve submits result")
    func resolveSubmits() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"my_tool\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        // Mock for submitToolResult
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)

        for try await event in client.stream("Do it") {
            if case .toolCall(let call) = event {
                await call.resolve(["result": .string("done")])
                await #expect(call.status == .resolved)
            }
        }

        // Stream request + submit request = 2
        #expect(mockClient.requestCount == 2)
    }

    // MARK: - fail

    @Test("fail submits error result")
    func failSubmits() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"my_tool\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)

        for try await event in client.stream("Do it") {
            if case .toolCall(let call) = event {
                await call.fail("Something broke")
                await #expect(call.status == .failed)
            }
        }

        #expect(mockClient.requestCount == 2)
    }

    // MARK: - ignore

    @Test("ignore does not submit anything")
    func ignoreNoSubmit() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"log_event\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        for try await event in client.stream("Log it") {
            if case .toolCall(let call) = event {
                await call.ignore()
                await #expect(call.status == .ignored)
            }
        }

        // Only the stream request, no submit
        #expect(mockClient.requestCount == 1)
    }

    // MARK: - Double resolve protection

    @Test("second resolve is a no-op")
    func doubleResolve() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"my_tool\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)

        for try await event in client.stream("Do it") {
            if case .toolCall(let call) = event {
                await call.resolve(["first": .bool(true)])
                await call.resolve(["second": .bool(true)]) // no-op
            }
        }

        // Stream + one submit = 2 (not 3)
        #expect(mockClient.requestCount == 2)
    }

    // MARK: - First-turn tool call uses conversationId from finish

    @Test("first-turn tool call handle carries conversationId resolved from finish metadata")
    func firstTurnToolCallGetsConversationId() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"my_tool\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"new-conv\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        var received: ToolCallHandle?

        // Caller passes no conversationId (first-turn scenario)
        for try await event in client.stream("Hi") {
            if case .toolCall(let call) = event { received = call }
        }

        #expect(received?.conversationId == "new-conv")
    }

    // MARK: - Submission error + retry

    @Test("submission failure lands in .submissionError and can be retried")
    func submissionErrorRetry() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"my_tool\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])

        // submitToolResult retries 3x internally. Exhaust them to hit submissionError.
        mockClient.respondWithError(APIError.invalidResponse)
        mockClient.respondWithError(APIError.invalidResponse)
        mockClient.respondWithError(APIError.invalidResponse)
        // Retry attempt succeeds
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)

        for try await event in client.stream("Do it") {
            if case .toolCall(let call) = event {
                await call.resolve(["result": .string("first")])
                await #expect(call.status == .submissionError(APIError.invalidResponse))

                await call.resolve(["result": .string("retry")])
                await #expect(call.status == .resolved)
            }
        }

        // Stream + 3 failed submits + 1 successful = 5
        #expect(mockClient.requestCount == 5)
    }

    // MARK: - continue

    @Test("client.continue returns a new stream")
    func continueStream() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Continued!\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        var texts: [String] = []
        for try await event in client.continue(conversationId: "conv-1") {
            if case .text(let chunk) = event { texts.append(chunk) }
        }

        #expect(texts == ["Continued!"])
    }

    // MARK: - Stream cancellation

    @Test("cancel stops the stream")
    func cancelStream() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\" world\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\" more\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\"}}",
            "data: [DONE]"
        ])

        let stream = client.stream("Hi")
        var count = 0

        for try await event in stream {
            if case .text = event {
                count += 1
                if count == 1 { stream.cancel() }
            }
        }

        #expect(stream.isCancelled)
    }

    // MARK: - Non-streaming

    @Test("send returns full ChatResponse")
    func sendMessage() async throws {
        mockClient.respondWithRawJSON("""
        {
            "data": {
                "id": "msg-1",
                "role": "assistant",
                "parts": [{"type": "text", "text": "Hello!"}],
                "metadata": {
                    "conversationId": "conv-1",
                    "userMessageId": "user-1",
                    "userId": null,
                    "finishReason": "stop",
                    "usage": {"credits": 1}
                }
            }
        }
        """)

        let response = try await client.send("Hi")

        #expect(response.message.text == "Hello!")
        #expect(response.conversationId == "conv-1")
        #expect(response.finishReason == .stop)
    }

    // MARK: - messageStarted passes through

    @Test("messageStarted event is forwarded")
    func messageStartedForwarded() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\"}}",
            "data: [DONE]"
        ])

        var startedId: String?
        for try await event in client.stream("Hi") {
            if case .messageStarted(let id) = event { startedId = id }
        }

        #expect(startedId == "msg-1")
    }

    // MARK: - identity

    @Test("exposes deviceId and starts anonymous")
    func startsAnonymous() {
        #expect(client.deviceId == "test-device")
        #expect(client.authState == .anonymous)
    }

    @Test("identify promotes session")
    func identifyFlow() async throws {
        let c = client

        mockClient.respondWithRawJSON("""
        {"data": {"userId": "user-xyz"}}
        """)

        try await c.identify(token: "jwt-xyz")

        #expect(c.authState == .identified(token: "jwt-xyz", userId: "user-xyz"))
        #expect(c.currentUserId == "user-xyz")
        #expect(c.isIdentified == true)
    }

    @Test("logout returns to anonymous")
    func logoutClears() async throws {
        let svc = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device",
            auth: .identified(token: "jwt", userId: "user-1")
        )
        let c = ChatbaseClient(service: svc)

        #expect(c.authState == .identified(token: "jwt", userId: "user-1"))
        c.logout()
        #expect(c.authState == .anonymous)
        #expect(c.currentUserId == nil)
        #expect(c.isIdentified == false)
    }
}
