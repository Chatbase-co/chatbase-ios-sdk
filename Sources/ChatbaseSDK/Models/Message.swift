import Foundation

public enum MessageSender: Sendable { case user, agent }

public enum MessageFeedback: String, Codable, Sendable {
    case positive
    case negative
}

public enum FinishReason: String, Sendable {
    case stop
    case error
    case toolCalls = "tool-calls"
}

public struct Usage: Sendable {
    public let credits: Double
    public init(credits: Double) { self.credits = credits }
}

public enum MessagePart: Sendable {
    case text(String)
    case toolCall(toolCallId: String, toolName: String, input: JSONValue)
    case toolResult(toolCallId: String, toolName: String, output: JSONValue)
}

public struct Message: Identifiable, Sendable {
    public var id: String
    public var text: String
    public var sender: MessageSender
    public var date: Date
    public var feedback: MessageFeedback?
    public var score: Double?
    public var parts: [MessagePart]

    public init(
        id: String,
        text: String,
        sender: MessageSender,
        date: Date,
        feedback: MessageFeedback? = nil,
        score: Double? = nil,
        parts: [MessagePart] = []
    ) {
        self.id = id
        self.text = text
        self.sender = sender
        self.date = date
        self.feedback = feedback
        self.score = score
        self.parts = parts
    }
}
