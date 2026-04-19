import Testing
@testable import ChatbaseSDK

@Suite("ToolRegistry")
struct ToolRegistryTests {

    @Test("register then lookup returns handler")
    func registerThenLookup() async {
        let registry = ToolRegistry()
        await registry.register("echo") { input in input }
        let handler = await registry.handler(for: "echo")
        #expect(handler != nil)
    }

    @Test("unregister removes handler")
    func unregister() async {
        let registry = ToolRegistry()
        await registry.register("echo") { _ in .null }
        await registry.unregister("echo")
        let handler = await registry.handler(for: "echo")
        #expect(handler == nil)
    }

    @Test("handler invocation passes input and returns output")
    func handlerInvocation() async throws {
        let registry = ToolRegistry()
        await registry.register("echo") { input in input }
        let handler = try #require(await registry.handler(for: "echo"))
        let output = try await handler(.string("hello"))
        #expect(output == .string("hello"))
    }
}

@Suite("ChatbaseClient tool-loop")
struct ChatbaseClientToolLoopTests {

    @Test("send runs auto tool-loop and returns terminal response")
    func sendAutoToolLoop() async throws {
        let mock = MockAPIClient()
        // Turn 1: tool call
        mock.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"tc-1\",\"toolName\":\"echo\",\"input\":{\"v\":\"hi\"}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"c1\",\"messageId\":\"m1\",\"userMessageId\":null,\"userId\":null,\"finishReason\":\"tool-calls\",\"usage\":{\"credits\":0}}}",
            "data: [DONE]"
        ])
        // /tool-result ack
        mock.respondWithRawJSON("{\"data\":{\"success\":true}}")
        // Turn 2: text + stop
        mock.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m2\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"done\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"c1\",\"messageId\":\"m2\",\"userMessageId\":null,\"userId\":null,\"finishReason\":\"stop\",\"usage\":{\"credits\":0}}}",
            "data: [DONE]"
        ])

        let svc = ChatService(client: mock, agentId: "a", baseURL: "https://x", deviceId: "d")
        let client = ChatbaseClient(service: svc)
        await client.registerTool("echo") { input in input }

        let response = try await client.send("hi")

        #expect(response.message.text == "done")
        #expect(response.conversationId == "c1")
        #expect(response.finishReason == .stop)
        #expect(mock.requestCount == 3)
    }

    @Test("send throws toolHandlerMissing when no handler is registered")
    func sendToolHandlerMissing() async throws {
        let mock = MockAPIClient()
        mock.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"tool-input-available\",\"toolCallId\":\"tc-1\",\"toolName\":\"missing\",\"input\":{}}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"c1\",\"messageId\":\"m1\",\"userMessageId\":null,\"userId\":null,\"finishReason\":\"tool-calls\",\"usage\":{\"credits\":0}}}",
            "data: [DONE]"
        ])
        let svc = ChatService(client: mock, agentId: "a", baseURL: "https://x", deviceId: "d")
        let client = ChatbaseClient(service: svc)

        do {
            _ = try await client.send("hi")
            Issue.record("Expected toolHandlerMissing")
        } catch ChatError.toolHandlerMissing(let name) {
            #expect(name == "missing")
        }
    }

    @Test("send without tool calls returns collected text directly")
    func sendNoToolCalls() async throws {
        let mock = MockAPIClient()
        mock.respondWithSSE([
            "data: {\"type\":\"start\",\"messageId\":\"m1\"}",
            "data: {\"type\":\"text-delta\",\"delta\":\"Hello!\"}",
            "data: {\"type\":\"finish\",\"messageMetadata\":{\"conversationId\":\"c1\",\"messageId\":\"m1\",\"userMessageId\":null,\"userId\":null,\"finishReason\":\"stop\",\"usage\":{\"credits\":1}}}",
            "data: [DONE]"
        ])
        let svc = ChatService(client: mock, agentId: "a", baseURL: "https://x", deviceId: "d")
        let client = ChatbaseClient(service: svc)

        let response = try await client.send("Hi")
        #expect(response.message.text == "Hello!")
        #expect(response.finishReason == .stop)
        #expect(mock.requestCount == 1)
    }
}
