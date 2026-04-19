# ChatbaseSDK

Swift SDK for the Chatbase API v2. Supports streaming chat, client-side tool calls, conversations, message feedback, and retry.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/chatbase-co/chatbase-ios-sdk.git", from: "0.1.0")
]
```

Or in Xcode: File > Add Package Dependencies, paste the repository URL.

## Quick Start

```swift
import ChatbaseSDK

let client = ChatbaseClient(
    agentId: "your-agent-id",
    apiKey: "your-api-key",
    userId: "unique-user-id"
)

// Stream a message
for try await event in client.stream("Hello") {
    switch event {
    case .text(let chunk): print(chunk, terminator: "")
    case .finished(let info): print("\nConversation: \(info.conversationId ?? "")")
    default: break
    }
}
```

## Tool Calls

When the agent invokes a client-side tool, the stream emits a `.toolCall` event with a `ToolCallHandle`. Call `resolve`, `fail`, or `ignore` on it, then optionally continue the conversation.

```swift
var conversationId: String?

for try await event in client.stream("Change my background", conversationId: conversationId) {
    switch event {
    case .text(let chunk):
        print(chunk, terminator: "")
    case .toolCall(let call):
        // Execute the tool
        let result = doSomething(call.toolName, call.input)
        // Submit the result
        await call.resolve(["result": .string(result)])
    case .finished(let info):
        conversationId = info.conversationId
    default: break
    }
}

// If the tool call resolved with continue: true (default), continue the conversation
if let conversationId {
    for try await event in client.continue(conversationId: conversationId) {
        // Handle follow-up response
    }
}
```

### Tool Call Options

```swift
// Submit result, agent should respond (default)
await call.resolve(["status": .string("done")])

// Submit result, agent should NOT respond (pause conversation)
await call.resolve(["status": .string("started")], continue: false)

// Submit an error, agent responds to the failure
await call.fail("Permission denied")

// Submit an error, don't continue
await call.fail("Cancelled", continue: false)

// Don't submit anything, don't continue
call.ignore()
```

## Cancelling a Stream

```swift
let stream = client.stream("Tell me a story", conversationId: id)

Task {
    for try await event in stream {
        if case .text(let chunk) = event { print(chunk, terminator: "") }
    }
}

// Cancel from anywhere
stream.cancel()
stream.isCancelled  // true
```

## Conversations

```swift
// List conversations for this user
var page = try await client.listConversations()
// page.data     — [Conversation]
// page.hasMore  — Bool
// page.total    — Int

// Load the next page
if let next = try await page.loadMore() {
    page = next
}

// Recent messages in a conversation
let messages = try await client.listMessages(conversationId: "conv-id")
let older = try await messages.loadMore()  // nil if no more
```

## Retry

```swift
let retryStream = client.retry(conversationId: "conv-id", messageId: "msg-id")
for try await event in retryStream {
    // Handle regenerated response
}
```

## Non-Streaming

```swift
let response = try await client.send("Hello", conversationId: "conv-id")
print(response.message.text)
print(response.finishReason)  // .stop, .error, or .toolCalls
print(response.usage.credits)
```

## Low-Level Access

`ChatbaseClient` wraps `ChatService` which provides direct access to all API v2 endpoints. Use it if you need full control:

```swift
let service = ChatService(agentId: "id", apiKey: "key")
let stream = service.streamMessage("Hello", conversationId: "conv-id")

for try await event in stream {
    // Raw StreamEvent cases: .messageStarted, .textChunk, .toolCall, .finished
}
```

## Requirements

- iOS 16+ / macOS 13+
- Swift 6.0+
