import Foundation

public struct ToolCallInfo: Sendable {
    public let toolCallId: String
    public let toolName: String
    public let input: JSONValue
}

public struct ToolResultInfo: Sendable {
    public let toolCallId: String
    public let toolName: String
    public let output: JSONValue
}

/// Streaming hooks for `ChatbaseClient.send(_:conversationId:configure:)`.
/// Set only the closures you care about; unset ones are no-ops.
/// Callbacks are async: consumers may `await` inside them to hop to their
/// preferred actor (e.g. `@MainActor` for UI updates).
/// Start/finish/error: use the `async throws` return value + `do/catch`.
public struct StreamCallbacks: Sendable {
    public var onTextDelta: (@Sendable (String) async -> Void)?
    public var onToolCall: (@Sendable (ToolCallInfo) async -> Void)?
    public var onToolResult: (@Sendable (ToolResultInfo) async -> Void)?

    public init() {}
}
