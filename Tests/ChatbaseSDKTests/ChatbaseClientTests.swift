//
//  ChatbaseClientTests.swift
//  tatbeeqMa7moolTests
//

import Testing
@testable import ChatbaseSDK
import Foundation

/// Lock-protected mutable box for collecting values inside @Sendable callback closures.
final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    func mutate(_ block: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        block(&_value)
    }
}

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
                await call.resolve(.object(["result": .string("done")]))
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
                await call.resolve(.object(["first": .bool(true)]))
                await call.resolve(.object(["second": .bool(true)])) // no-op
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
                await call.resolve(.object(["result": .string("first")]))
                await #expect(call.status == .submissionError(APIError.invalidResponse))

                await call.resolve(.object(["result": .string("retry")]))
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

    @Test("sendNonStreaming returns full ChatResponse")
    func sendNonStreaming() async throws {
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

        let response = try await client.sendNonStreaming("Hi")

        #expect(response.message.text == "Hello!")
        #expect(response.conversationId == "conv-1")
        #expect(response.finishReason == .stop)
    }

    // MARK: - Auto tool-loop send

    @Test("send streams text with no tools and returns ChatResponse")
    func sendStreamingText() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\" world\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-1\",\"userMessageId\":\"user-1\",\"finishReason\":\"stop\",\"usage\":{\"credits\":1}}}",
            "data: [DONE]"
        ])

        let deltas = TestBox<[String]>([])

        let response = try await client.send("Hi") { cb in
            cb.onTextDelta = { chunk in deltas.mutate { $0.append(chunk) } }
        }

        #expect(deltas.value == ["Hello", " world"])
        #expect(response.message.id == "msg-1")
        #expect(response.message.text == "Hello world")
        #expect(response.conversationId == "conv-1")
        #expect(response.userMessageId == "user-1")
        #expect(response.finishReason == .stop)
        #expect(mockClient.requestCount == 1)
    }

    @Test("send auto-runs registered tool and continues to final text")
    func sendAutoToolLoop() async throws {
        let c = client
        c.tool("get_weather") { input in
            #expect(input["city"] == .string("SF"))
            return .object(["temp": .int(72)])
        }

        // Turn 1: tool call
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"get_weather\",\"input\":{\"city\":\"SF\"}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        // submitToolResult
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)
        // Turn 2: continuation with final text
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"It's 72F in SF.\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-2\",\"finishReason\":\"stop\",\"usage\":{\"credits\":2}}}",
            "data: [DONE]"
        ])

        let toolCalls = TestBox<[String]>([])
        let toolResults = TestBox<[JSONValue]>([])

        let response = try await c.send("Weather?") { cb in
            cb.onToolCall = { info in toolCalls.mutate { $0.append(info.toolName) } }
            cb.onToolResult = { info in toolResults.mutate { $0.append(info.output) } }
        }

        #expect(toolCalls.value == ["get_weather"])
        #expect(toolResults.value == [.object(["temp": .int(72)])])
        #expect(response.message.text == "It's 72F in SF.")
        #expect(response.finishReason == .stop)
        #expect(response.conversationId == "conv-1")
        // Turn 1 stream + submitToolResult + Turn 2 continue = 3
        #expect(mockClient.requestCount == 3)
    }

    @Test("send with no registered handler submits error payload and continues")
    func sendNoHandlerFallback() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"mystery_tool\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Sorry.\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-2\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        let results = TestBox<[JSONValue]>([])
        let response = try await client.send("Hi") { cb in
            cb.onToolResult = { info in results.mutate { $0.append(info.output) } }
        }

        #expect(response.message.text == "Sorry.")
        #expect(results.value.count == 1)
        if case .object(let obj) = results.value[0], case .string(let msg) = obj["error"] {
            #expect(msg.contains("mystery_tool"))
        } else {
            Issue.record("Expected error payload, got \(results.value[0])")
        }
    }

    @Test("send with throwing handler submits handler error payload")
    func sendThrowingHandler() async throws {
        struct BoomError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }

        let c = client
        c.tool("broken") { _ in
            throw BoomError()
        }

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"broken\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"oops\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-2\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        let results = TestBox<[JSONValue]>([])
        _ = try await c.send("Try") { cb in
            cb.onToolResult = { info in results.mutate { $0.append(info.output) } }
        }

        #expect(results.value.count == 1)
        if case .object(let obj) = results.value[0], case .string(let msg) = obj["error"] {
            #expect(msg == "boom")
        } else {
            Issue.record("Expected error payload, got \(results.value[0])")
        }
    }

    @Test("removeTool clears handler; subsequent call falls back")
    func removeToolFallback() async throws {
        let c = client
        c.tool("ping") { _ in .object(["ok": .bool(true)]) }
        c.removeTool("ping")

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"call-1\",\"toolName\":\"ping\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"msg-2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"done\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"msg-2\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        let results = TestBox<[JSONValue]>([])
        _ = try await c.send("Hi") { cb in
            cb.onToolResult = { info in results.mutate { $0.append(info.output) } }
        }

        #expect(results.value.count == 1)
        if case .object(let obj) = results.value[0] {
            #expect(obj["error"] != nil)
        } else {
            Issue.record("Expected error payload")
        }
    }

    @Test("send multi-hop: tool → tool → text")
    func sendMultiHop() async throws {
        let c = client
        c.tool("step_a") { _ in .object(["a": .int(1)]) }
        c.tool("step_b") { input in
            #expect(input["prev"] == .int(1))
            return .object(["b": .int(2)])
        }

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"c1\",\"toolName\":\"step_a\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m2\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"c2\",\"toolName\":\"step_b\",\"input\":{\"prev\":1}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m3\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"All done.\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"m3\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        let calls = TestBox<[String]>([])
        let response = try await c.send("Start") { cb in
            cb.onToolCall = { info in calls.mutate { $0.append(info.toolName) } }
        }

        #expect(calls.value == ["step_a", "step_b"])
        #expect(response.message.text == "All done.")
        #expect(response.finishReason == .stop)
        // 3 streams + 2 submits = 5
        #expect(mockClient.requestCount == 5)
    }

    @Test("send propagates stream error via throw")
    func sendStreamError() async throws {
        mockClient.respondWithError(
            APIError.httpError(
                statusCode: 402,
                detail: APIErrorDetail(code: "CREDITS", message: "Out", details: nil)
            )
        )

        do {
            _ = try await client.send("Hi")
            Issue.record("Expected throw")
        } catch let error as APIError {
            #expect(error.statusCode == 402)
        }
    }

    @Test("send throws on tool-result submission failure instead of silently continuing")
    func sendSubmissionFailureThrows() async throws {
        let c = client
        c.tool("ping") { _ in .object(["ok": .bool(true)]) }

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"c1\",\"toolName\":\"ping\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        // submitToolResult retries 3x internally; exhaust all
        mockClient.respondWithError(APIError.invalidResponse)
        mockClient.respondWithError(APIError.invalidResponse)
        mockClient.respondWithError(APIError.invalidResponse)

        do {
            _ = try await c.send("Hi")
            Issue.record("Expected throw")
        } catch let error as APIError {
            if case .invalidResponse = error {} else {
                Issue.record("Expected invalidResponse, got \(error)")
            }
        }

        // Stream + 3 failed submits = 4. No continuation attempted.
        #expect(mockClient.requestCount == 4)
    }

    @Test("send throws when tool loop exceeds max steps")
    func sendToolLoopLimit() async throws {
        let c = client
        c.tool("loop") { _ in .object([:]) }

        // Each turn: one tool call, finishReason tool-calls. Submit succeeds. Never resolves.
        for _ in 0..<ChatbaseClient.maxToolLoopSteps {
            mockClient.respondWithSSE([
                "data: {\"type\":\"start\",\"messageId\":\"m\"}",
                "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"c\",\"toolName\":\"loop\",\"input\":{}}",
                "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
                "data: [DONE]"
            ])
            mockClient.respondWithRawJSON("""
            {"data": {"success": true}}
            """)
        }

        do {
            _ = try await c.send("Hi")
            Issue.record("Expected throw")
        } catch let error as ChatError {
            if case .toolLoopLimitExceeded = error {} else {
                Issue.record("Expected toolLoopLimitExceeded, got \(error)")
            }
        }
    }

    // MARK: - Session state tracking

    @Test("send updates currentConversationId and currentUserId from finish metadata")
    func sendTracksSessionState() async throws {
        let c = client
        #expect(c.currentConversationId == nil)
        #expect(c.currentUserId == nil)

        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"hi\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-9\",\"messageId\":\"m1\",\"userId\":\"user-42\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        _ = try await c.send("Hi")

        #expect(c.currentConversationId == "conv-9")
        #expect(c.currentUserId == "user-42")
    }

    @Test("send falls back to currentConversationId when conversationId omitted")
    func sendFallsBackToRememberedConversation() async throws {
        let c = client

        // Turn A: establish conversation
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"one\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])
        _ = try await c.send("first")
        #expect(c.currentConversationId == "conv-1")

        // Turn B: without passing conversationId; SDK should use remembered
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"two\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])
        let response = try await c.send("second")

        #expect(response.conversationId == "conv-1")
        let body = mockClient.lastRequest?.httpBody ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["conversationId"] as? String == "conv-1")
    }

    @Test("newConversation clears currentConversationId")
    func newConversationResets() async throws {
        let c = client
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])
        _ = try await c.send("hi")
        #expect(c.currentConversationId == "conv-1")

        c.newConversation()
        #expect(c.currentConversationId == nil)
    }

    @Test("logout clears currentConversationId and currentUserId")
    func logoutClearsSession() async throws {
        let c = client
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"userId\":\"user-1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])
        _ = try await c.send("hi")
        #expect(c.currentConversationId == "conv-1")
        #expect(c.currentUserId == "user-1")

        c.logout()
        #expect(c.currentConversationId == nil)
        #expect(c.currentUserId == nil)
    }

    // MARK: - Retry auto-loop

    @Test("retry auto-loop runs tools and returns ChatResponse")
    func retryAutoLoop() async throws {
        let c = client
        c.tool("step") { _ in .object(["ok": .bool(true)]) }

        // First turn: retry emits tool call
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"c1\",\"toolName\":\"step\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"tool-calls\"}}",
            "data: [DONE]"
        ])
        mockClient.respondWithRawJSON("""
        {"data": {"success": true}}
        """)
        // Continuation: final text
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"retried\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"messageId\":\"m2\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        let response = try await c.retry(conversationId: "conv-1", messageId: "orig-m")
        #expect(response.message.text == "retried")
        #expect(response.finishReason == .stop)
        // retry stream + submit + continue = 3
        #expect(mockClient.requestCount == 3)
    }

    @Test("retryStream returns raw ChatStream (no auto loop)")
    func retryStreamRaw() async throws {
        mockClient.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"raw\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"conv-1\",\"finishReason\":\"stop\"}}",
            "data: [DONE]"
        ])

        var texts: [String] = []
        for try await event in client.retryStream(conversationId: "conv-1", messageId: "m-orig") {
            if case .text(let chunk) = event { texts.append(chunk) }
        }
        #expect(texts == ["raw"])
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
        {"data": {"ok": true}}
        """)

        try await c.identify(token: "jwt-xyz")

        #expect(c.authState == .identified(token: "jwt-xyz"))
    }

    @Test("logout returns to anonymous")
    func logoutClears() async throws {
        let svc = ChatService(
            client: mockClient,
            agentId: "test-agent",
            baseURL: "https://test.api.com/v2",
            deviceId: "test-device",
            auth: .identified(token: "jwt")
        )
        let c = ChatbaseClient(service: svc)

        #expect(c.authState == .identified(token: "jwt"))
        c.logout()
        #expect(c.authState == .anonymous)
    }
}
