# ChatbaseSDK

Swift SDK for the Chatbase SDK API. Provides streaming chat, client-side tool calls, identity verification, conversation history with cursor-based pagination, retry, and cancellation.

## Requirements

- iOS 16+ / macOS 13+
- Swift 6.0+

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Chatbase-co/chatbase-ios-sdk.git", from: "0.1.0")
]
```

In Xcode: File > Add Package Dependencies and paste the repository URL.

## Quick Start

```swift
import ChatbaseSDK

let client = ChatbaseClient(agentId: "your-agent-id")

for try await event in client.stream("Hello") {
    switch event {
    case .text(let chunk):
        print(chunk, terminator: "")
    case .finished(let info):
        print("\nconversation:", info.conversationId ?? "")
    default:
        break
    }
}
```

A new client starts in an anonymous session scoped to a stable device identifier stored in `UserDefaults`. Anonymous conversations persist across launches.

## Identity Verification

Attach an end user to the session with an HS256 JWT signed by your backend using the agent's identity verification secret. The payload must include `user_id` (or `sub`).

```swift
try await client.identify(token: jwt)

// Return to anonymous
client.logout()

// Inspect
client.authState   // .anonymous or .identified(token:)
client.deviceId    // stable per-install identifier
```

The token is persisted in the Keychain and reloaded on next launch, so an identified session survives app restarts.

## Streaming Chat

`client.stream(_:conversationId:)` returns a `ChatStream`, an `AsyncSequence` of `ChatEvent` values.

```swift
var conversationId: String?

for try await event in client.stream("Change my background", conversationId: conversationId) {
    switch event {
    case .messageStarted(let id):
        print("message started:", id)
    case .text(let chunk):
        print(chunk, terminator: "")
    case .toolCall(let call):
        await handle(call)
    case .finished(let info):
        conversationId = info.conversationId
    }
}
```

### Cancellation

```swift
let stream = client.stream("Tell me a story")

Task {
    for try await event in stream {
        if case .text(let chunk) = event { print(chunk, terminator: "") }
    }
}

stream.cancel()
stream.isCancelled  // true
```

## Tool Calls

When the agent invokes a client-side tool, the stream emits a `.toolCall` event carrying a `ToolCallHandle`. Call `resolve`, `fail`, or `ignore` on the handle. If the agent should respond to the result, call `client.continue(conversationId:)` after the current stream completes.

```swift
var shouldContinue = false

for try await event in client.stream("Look up my order", conversationId: conversationId) {
    switch event {
    case .text(let chunk):
        print(chunk, terminator: "")
    case .toolCall(let call):
        switch call.toolName {
        case "lookup_order":
            let order = findOrder(id: call.input["order_id"]?.stringValue)
            await call.resolve(["status": .string(order.status)])
            shouldContinue = true
        case "open_checkout":
            await call.resolve(["status": .string("started")])
            shouldContinue = false
        default:
            await call.ignore()
        }
    case .finished(let info):
        conversationId = info.conversationId
    default:
        break
    }
}

if shouldContinue, let conversationId {
    for try await event in client.`continue`(conversationId: conversationId) {
        // handle follow-up response
    }
}
```

### Handle Methods

```swift
await call.resolve(["status": .string("done")])  // submit a result
await call.fail("Permission denied")             // submit an error the agent can read
await call.ignore()                              // do not submit anything
```

`ToolCallHandle` is an actor. Each handle accepts exactly one terminal call; subsequent calls are no-ops.

## Conversations

```swift
var page = try await client.listConversations()
// page.data     [Conversation]
// page.hasMore  Bool
// page.total    Int

if let next = try await page.loadMore() {
    page = next
}

let messages = try await client.listMessages(conversationId: "conv-id")
let older = try await messages.loadMore()  // nil when hasMore is false
```

`loadMore()` is available on any paginated response and internally carries the cursor needed for the next page.

## Retry

Regenerate the assistant response for a given message.

```swift
for try await event in client.retry(conversationId: "conv-id", messageId: "msg-id") {
    // handle regenerated response
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

`ChatbaseClient.service` exposes the underlying `ChatService` for direct access to each endpoint, including the raw SSE stream of `StreamEvent` values.

```swift
let stream = client.service.streamMessage("Hello", conversationId: "conv-id")

for try await event in stream {
    // .messageStarted, .textChunk, .toolCall, .finished
}
```
