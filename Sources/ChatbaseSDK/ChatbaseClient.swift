import Foundation

public final class ChatbaseClient: @unchecked Sendable {
    let service: ChatService
    let maxToolLoopSteps: Int
    private let toolRegistry = ToolRegistry()

    public init(
        agentId: String,
        baseURL: String = "https://www.chatbase.co/api/sdk",
        configuration: URLSessionConfiguration = .default,
        maxToolLoopSteps: Int = 10
    ) {
        self.service = ChatService(
            client: URLSessionClient(configuration: configuration),
            agentId: agentId,
            baseURL: baseURL,
            deviceId: DeviceId.get(),
            auth: Identity.load()
        )
        self.maxToolLoopSteps = maxToolLoopSteps
    }

    init(service: ChatService, maxToolLoopSteps: Int = 10) {
        self.service = service
        self.maxToolLoopSteps = maxToolLoopSteps
    }

    public var deviceId: String { service.deviceId }
    public var authState: AuthState { service.authState }
    public var currentConversationId: String? { service.currentConversationId }
    public var currentUserId: String? { service.currentUserId }

    public func newConversation() {
        service.updateCurrentConversation(nil)
    }

    public func identify(token: String) async throws {
        try await service.verify(token: token)
    }

    public func logout() {
        service.updateAuth(.anonymous)
    }

    // MARK: - Tools

    /// Register a tool handler. When the agent invokes `name` during `send(...)`,
    /// the handler runs, its output is submitted, and the stream resumes — all
    /// inside a single `send` call. Handlers are async and may suspend on UI
    /// (e.g. awaiting a user selection) before returning output.
    public func tool(_ name: String, handler: @escaping ToolHandler) {
        toolRegistry.register(name, handler: handler)
    }

    // MARK: - Send

    /// Send a message and stream the response, automatically running registered
    /// tools and continuing the conversation until a non-tool-call finish.
    ///
    /// `conversationId: nil` always starts a new conversation. For session
    /// continuity across sends, hold a `ConversationState` (recommended) or
    /// pass `client.currentConversationId` explicitly.
    ///
    /// Unknown tools (no handler registered) are resolved with an error payload
    /// so the agent can recover rather than hang.
    public func send(
        _ message: String,
        conversationId: String? = nil,
        configure: @Sendable (inout StreamCallbacks) -> Void = { _ in }
    ) async throws -> ChatResponse {
        try await runAutoLoop(
            firstStream: { self.service.streamMessage(message, conversationId: conversationId) },
            initialConversationId: conversationId,
            configure: configure
        )
    }

    /// Retry an assistant message with the auto tool loop.
    public func retry(
        conversationId: String,
        messageId: String,
        configure: @Sendable (inout StreamCallbacks) -> Void = { _ in }
    ) async throws -> ChatResponse {
        try await runAutoLoop(
            firstStream: { self.service.retryMessage(conversationId: conversationId, messageId: messageId) },
            initialConversationId: conversationId,
            configure: configure
        )
    }

    /// POST /chat without streaming and without the tool loop. Returns the full
    /// agent reply in one shot. Use when you don't need per-delta UI updates
    /// and don't need registered tools to run.
    public func sendNonStreaming(_ message: String, conversationId: String? = nil) async throws -> ChatResponse {
        try await service.sendMessage(message, conversationId: conversationId)
    }

    // MARK: - Conversations

    public func listConversations(cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Conversation> {
        try await service.listConversations(cursor: cursor, limit: limit)
    }

    public func listMessages(conversationId: String, cursor: String? = nil, limit: Int? = nil) async throws -> PaginatedResponse<Message> {
        try await service.listMessages(conversationId: conversationId, cursor: cursor, limit: limit)
    }

    // MARK: - Auto tool-loop

    private func runAutoLoop(
        firstStream: () -> AsyncThrowingStream<StreamEvent, Error>,
        initialConversationId: String?,
        configure: @Sendable (inout StreamCallbacks) -> Void
    ) async throws -> ChatResponse {
        var callbacks = StreamCallbacks()
        configure(&callbacks)

        var currentConvId = initialConversationId
        var isFirstTurn = true
        var accumulatedText = ""
        var lastMessageId: String?
        var lastFinish: StreamFinishInfo?
        var userMessageId: String?
        var steps = 0

        while true {
            if steps >= maxToolLoopSteps { throw ChatError.toolLoopLimitExceeded(limit: maxToolLoopSteps) }
            steps += 1

            let rawStream: AsyncThrowingStream<StreamEvent, Error>
            if isFirstTurn {
                rawStream = firstStream()
                isFirstTurn = false
            } else {
                // currentConvId is guaranteed non-nil here: the guard below
                // breaks the loop if it was missing after the first turn.
                rawStream = service.continueConversation(currentConvId!)
            }

            // Buffer tool calls until finish event resolves conversationId
            // (required for first-turn streams where the id isn't known yet).
            var pendingToolCalls: [ToolCall] = []

            for try await event in rawStream {
                switch event {
                case .messageStarted(let id):
                    lastMessageId = id
                case .textChunk(let chunk):
                    accumulatedText += chunk
                    await callbacks.onTextDelta?(chunk)
                case .toolCall(let tc):
                    pendingToolCalls.append(tc)
                case .finished(let info):
                    lastFinish = info
                    if let cid = info.conversationId { currentConvId = cid }
                    if let umid = info.userMessageId { userMessageId = umid }
                }
            }

            guard !pendingToolCalls.isEmpty else { break }

            guard let convIdForTools = currentConvId, !convIdForTools.isEmpty else {
                throw ChatError.noContent
            }

            for tc in pendingToolCalls {
                await callbacks.onToolCall?(ToolCallInfo(toolCallId: tc.toolCallId, toolName: tc.toolName, input: tc.input))
                let output = try await runTool(name: tc.toolName, input: tc.input)
                try await service.submitToolResult(conversationId: convIdForTools, toolCall: tc, output: output)
                await callbacks.onToolResult?(ToolResultInfo(toolCallId: tc.toolCallId, toolName: tc.toolName, output: output))
            }
        }

        if let cid = currentConvId, !cid.isEmpty {
            service.updateCurrentConversation(cid)
        }
        if let uid = lastFinish?.userId {
            service.updateCurrentUser(uid)
        }

        return ChatResponse(
            message: Message(
                id: lastFinish?.messageId ?? lastMessageId ?? "",
                text: accumulatedText,
                sender: .agent,
                date: .now
            ),
            conversationId: currentConvId ?? "",
            userMessageId: userMessageId,
            finishReason: lastFinish?.finishReason ?? .stop,
            usage: lastFinish?.usage ?? Usage(credits: 0)
        )
    }

    private func runTool(name: String, input: JSONValue) async throws -> JSONValue {
        guard let handler = toolRegistry.get(name) else {
            return .object(["error": .string("No handler registered for tool '\(name)'")])
        }
        do {
            return try await handler(input)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .object(["error": .string(error.localizedDescription)])
        }
    }
}
