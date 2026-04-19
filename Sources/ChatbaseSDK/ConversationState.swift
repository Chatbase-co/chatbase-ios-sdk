import Foundation
import Observation
import os

/// Observable chat state for SwiftUI: holds messages, streams deltas into an
/// in-flight assistant placeholder, renders tool-call cards, and manages
/// continuation placeholders across the tool loop.
///
/// Parallels Android's `ConversationState`. All mutation happens on the main
/// actor so bindings can drive views directly.
@MainActor
@Observable
public final class ConversationState {
    private static let logger = Logger(subsystem: "com.chatbase.sdk", category: "ConversationState")

    public struct ToolCallCard: Sendable {
        public enum Status: Sendable { case executing, success, failure }
        public var toolCallId: String
        public var toolName: String
        public var input: JSONValue
        public var output: JSONValue?
        public var status: Status

        /// Convention: an output object containing an `error` key is a failure;
        /// anything else (including non-object outputs) is success.
        static func status(for output: JSONValue) -> Status {
            if case .object(let dict) = output, dict["error"] != nil { return .failure }
            return .success
        }
    }

    public struct UiMessage: Identifiable, Sendable {
        public enum Kind: Sendable {
            case text(String)
            case toolCall(ToolCallCard)
        }

        public var id: String
        public var messageId: String?
        public var kind: Kind
        public var sender: MessageSender
        public var date: Date
        public var isStreaming: Bool
        public var isError: Bool
        public var feedback: MessageFeedback?

        public init(
            id: String,
            messageId: String? = nil,
            kind: Kind,
            sender: MessageSender,
            date: Date = .now,
            isStreaming: Bool = false,
            isError: Bool = false,
            feedback: MessageFeedback? = nil
        ) {
            self.id = id
            self.messageId = messageId
            self.kind = kind
            self.sender = sender
            self.date = date
            self.isStreaming = isStreaming
            self.isError = isError
            self.feedback = feedback
        }
    }

    public private(set) var messages: [UiMessage] = []
    public private(set) var isSending = false
    public private(set) var isLoadingHistory = false
    public private(set) var hasMoreHistory = false
    public private(set) var conversationId: String?
    public private(set) var error: Error?

    @ObservationIgnored private let client: ChatbaseClient
    @ObservationIgnored private var historyPage: PaginatedResponse<Message>?
    @ObservationIgnored private var activeStreamingId: String?
    @ObservationIgnored private var currentTurnIds: [String] = []

    public init(client: ChatbaseClient, conversationId: String? = nil) {
        self.client = client
        self.conversationId = conversationId
    }

    // MARK: - State mutation

    public func setConversationId(_ id: String?) {
        conversationId = id
    }

    public func clearError() {
        error = nil
    }

    public func clear() {
        messages = []
        conversationId = nil
        historyPage = nil
        hasMoreHistory = false
        error = nil
        currentTurnIds = []
        activeStreamingId = nil
    }

    // MARK: - History

    public func loadHistory(conversationId: String, limit: Int = 20) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await client.listMessages(conversationId: conversationId, limit: limit)
            messages = page.data.flatMap(Self.uiMessages(from:))
            self.conversationId = conversationId
            hasMoreHistory = page.hasMore
            historyPage = page
        } catch {
            self.error = error
        }
    }

    public func loadMoreHistory() async {
        guard let page = historyPage, page.hasMore, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            guard let next = try await page.loadMore() else {
                hasMoreHistory = false
                return
            }
            let existingIds = Set(messages.compactMap(\.messageId))
            let older = next.data.flatMap { msg -> [UiMessage] in
                if existingIds.contains(msg.id) { return [] }
                return Self.uiMessages(from: msg)
            }
            messages.insert(contentsOf: older, at: 0)
            hasMoreHistory = next.hasMore
            historyPage = next
        } catch {
            self.error = error
        }
    }

    // MARK: - Send

    public func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        error = nil
        isSending = true
        currentTurnIds = []
        defer {
            isSending = false
            activeStreamingId = nil
        }

        let userMsgId = UUID().uuidString
        append(UiMessage(id: userMsgId, kind: .text(trimmed), sender: .user, date: .now))

        let placeholderId = UUID().uuidString
        append(UiMessage(id: placeholderId, kind: .text(""), sender: .agent, date: .now, isStreaming: true))
        activeStreamingId = placeholderId

        do {
            let response = try await client.send(trimmed, conversationId: conversationId, configure: wireCallbacks)
            finalize(response: response)
        } catch {
            markTurnAsError(error)
        }
    }

    // MARK: - Retry

    public func retry(messageId: String) async {
        guard !isSending else {
            Self.logger.warning("retry ignored: already sending")
            return
        }
        guard let cid = conversationId else {
            Self.logger.warning("retry ignored: no conversationId")
            return
        }
        guard let idx = messages.firstIndex(where: { $0.messageId == messageId }) else {
            Self.logger.warning("retry ignored: messageId \(messageId, privacy: .public) not found")
            return
        }

        error = nil
        isSending = true
        currentTurnIds = []
        defer {
            isSending = false
            activeStreamingId = nil
        }

        messages.removeSubrange(idx...)

        let placeholderId = UUID().uuidString
        append(UiMessage(id: placeholderId, kind: .text(""), sender: .agent, date: .now, isStreaming: true))
        activeStreamingId = placeholderId

        do {
            let response = try await client.retry(conversationId: cid, messageId: messageId, configure: wireCallbacks)
            finalize(response: response)
        } catch {
            markTurnAsError(error)
        }
    }

    // MARK: - Callback wiring

    private nonisolated func wireCallbacks(_ cb: inout StreamCallbacks) {
        cb.onTextDelta = { [weak self] delta in await self?.handleTextDelta(delta) }
        cb.onToolCall = { [weak self] info in await self?.handleToolCall(info) }
        cb.onToolResult = { [weak self] info in await self?.handleToolResult(info) }
    }

    // MARK: - Stream event handlers

    private func handleTextDelta(_ delta: String) {
        guard let id = activeStreamingId,
              let i = messages.firstIndex(where: { $0.id == id }),
              case .text(let existing) = messages[i].kind else { return }
        messages[i].kind = .text(existing + delta)
    }

    private func handleToolCall(_ info: ToolCallInfo) {
        if let id = activeStreamingId, let i = messages.firstIndex(where: { $0.id == id }) {
            if case .text(let existing) = messages[i].kind, existing.isEmpty {
                messages.remove(at: i)
            } else {
                messages[i].isStreaming = false
            }
        }
        activeStreamingId = nil
        append(UiMessage(
            id: info.toolCallId,
            kind: .toolCall(ToolCallCard(
                toolCallId: info.toolCallId,
                toolName: info.toolName,
                input: info.input,
                output: nil,
                status: .executing
            )),
            sender: .agent,
            date: .now
        ))
    }

    private func handleToolResult(_ info: ToolResultInfo) {
        if let i = messages.firstIndex(where: { $0.id == info.toolCallId }),
           case .toolCall(var card) = messages[i].kind {
            card.output = info.output
            card.status = ToolCallCard.status(for: info.output)
            messages[i].kind = .toolCall(card)
        }
        let nextId = UUID().uuidString
        append(UiMessage(id: nextId, kind: .text(""), sender: .agent, date: .now, isStreaming: true))
        activeStreamingId = nextId
    }

    // MARK: - Finalize / error

    private func finalize(response: ChatResponse) {
        // Stamp the remaining streaming placeholder (or any final empty agent
        // text slot) with the server-assigned messageId; drop leftover empty
        // continuation placeholders.
        if let id = activeStreamingId, let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].isStreaming = false
            if case .text(let existing) = messages[i].kind, existing.isEmpty {
                messages.remove(at: i)
            } else {
                messages[i].messageId = response.message.id
            }
        }
        // Stamp user message id too if we know it.
        if let userId = response.userMessageId,
           let i = currentTurnIds.first.flatMap({ uid in messages.firstIndex(where: { $0.id == uid }) }),
           messages[i].sender == .user {
            messages[i].messageId = userId
        }
        if conversationId == nil { conversationId = response.conversationId }
    }

    private func markTurnAsError(_ err: Error) {
        error = err
        if let id = activeStreamingId, let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].isStreaming = false
            messages[i].isError = true
        }
    }

    // MARK: - Helpers

    private func append(_ msg: UiMessage) {
        messages.append(msg)
        currentTurnIds.append(msg.id)
    }

    private static func uiMessages(from msg: Message) -> [UiMessage] {
        // Expand each part into its own UiMessage; fold tool-result parts into
        // the matching tool-call card so history renders like live streaming.
        var out: [UiMessage] = []
        for part in msg.parts {
            switch part {
            case .text(let text):
                guard !text.isEmpty else { continue }
                out.append(UiMessage(
                    id: "\(msg.id)#text-\(out.count)",
                    messageId: msg.id,
                    kind: .text(text),
                    sender: msg.sender,
                    date: msg.date,
                    feedback: msg.feedback
                ))
            case .toolCall(let id, let name, let input):
                out.append(UiMessage(
                    id: id,
                    messageId: msg.id,
                    kind: .toolCall(ToolCallCard(
                        toolCallId: id,
                        toolName: name,
                        input: input,
                        output: nil,
                        status: .executing
                    )),
                    sender: .agent,
                    date: msg.date
                ))
            case .toolResult(let id, _, let output):
                if let i = out.lastIndex(where: {
                    if case .toolCall(let card) = $0.kind { return card.toolCallId == id }
                    return false
                }), case .toolCall(var card) = out[i].kind {
                    card.output = output
                    card.status = ToolCallCard.status(for: output)
                    out[i].kind = .toolCall(card)
                }
            }
        }
        // Fallback: no parts produced anything (shouldn't happen) → single text bubble.
        if out.isEmpty, !msg.text.isEmpty {
            out.append(UiMessage(
                id: msg.id,
                messageId: msg.id,
                kind: .text(msg.text),
                sender: msg.sender,
                date: msg.date,
                feedback: msg.feedback
            ))
        }
        return out
    }
}
