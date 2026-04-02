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
        let service = ChatService(client: mockClient, agentId: "test-agent", apiKey: "test-key", baseURL: "https://test.api.com/v2")
        return ChatbaseClient(service: service, userId: "test-user")
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

        // Pass conversationId — tool call arrives before finish event in the SSE stream
        for try await event in await client.stream("Do it", conversationId: "conv-1") {
            if case .toolCall(let call) = event {
                receivedCall = call
                call.ignore()
            }
        }

        #expect(receivedCall?.toolCallId == "call-1")
        #expect(receivedCall?.toolName == "my_tool")
        await #expect(receivedCall?.input["key"] == .string("val"))
        #expect(receivedCall?.conversationId == "conv-1")
    }

    // MARK: - resolve

    @Test("resolve submits result and sets shouldContinue")
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
                #expect(call.shouldContinue == true)
                #expect(call.isResolved == true)
            }
        }

        // Stream request + submit request = 2
        #expect(mockClient.requestCount == 2)
    }

    @Test("resolve with continue: false sets shouldContinue to false")
    func resolveNoContinue() async throws {
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
                await call.resolve(["status": .string("started")], continue: false)
                #expect(call.shouldContinue == false)
            }
        }
    }

    // MARK: - fail

    @Test("fail submits error and sets shouldContinue")
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
                #expect(call.shouldContinue == true)
            }
        }

        #expect(mockClient.requestCount == 2)
    }

    @Test("fail with continue: false does not set shouldContinue")
    func failNoContinue() async throws {
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
                await call.fail("Cancelled", continue: false)
                #expect(call.shouldContinue == false)
            }
        }
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
                call.ignore()
                #expect(call.isResolved == true)
                #expect(call.shouldContinue == false)
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

    // MARK: - userId

    @Test("uses configured userId")
    func usesUserId() async throws {
        let c = client // userId is "test-user"

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\"}}",
            "data: [DONE]"
        ])

        for try await _ in c.stream("Hi") {}

        let body = try #require(mockClient.lastRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["userId"] as? String == "test-user")
    }
}
