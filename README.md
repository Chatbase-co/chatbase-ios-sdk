# ChatbaseSDK

Swift SDK for the Chatbase SDK API. Streaming chat, client-side tools with an auto tool-loop, identity verification, conversation history with cursor-based pagination, and retry.

## Requirements

- iOS 17+ / macOS 14+
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

let response = try await client.send("Hello")
print(response.message.text)
print(response.conversationId)
```

A new client starts in an anonymous session scoped to a stable device identifier stored in `UserDefaults`. Anonymous conversations persist across launches.

## SwiftUI with `ConversationState`

`ConversationState` is an `@Observable` view model that holds messages, streams deltas into a placeholder bubble, renders tool-call cards, and persists the conversation id across sends. This is the recommended integration for UIs.

```swift
import SwiftUI
import ChatbaseSDK

@MainActor @Observable
final class ChatVM {
    let state: ConversationState
    var input = ""

    init(client: ChatbaseClient) {
        self.state = ConversationState(client: client)
    }

    func send() {
        let text = input; input = ""
        Task { [state] in await state.sendMessage(text) }
    }
}

struct ChatView: View {
    @State var vm: ChatVM
    var body: some View {
        List(vm.state.messages) { msg in
            // render msg.kind (.text or .toolCall)
        }
    }
}
```

`ConversationState` exposes `messages`, `isSending`, `isLoadingHistory`, `hasMoreHistory`, `conversationId`, and `error`, plus `sendMessage`, `retry`, `loadHistory`, `loadMoreHistory`, `clear`, and `clearError`.

## Identity Verification

Attach an end user with an HS256 JWT signed by your backend using the agent's identity verification secret. Payload must include `user_id` (or `sub`).

```swift
try await client.identify(token: jwt)

client.logout()           // back to anonymous
client.authState          // .anonymous or .identified(token:)
client.deviceId           // stable per-install identifier
```

The token is persisted in Keychain and reloaded on next launch — an identified session survives restarts.

## Streaming via Callbacks

`client.send(_:conversationId:configure:)` runs the full tool loop and returns the final `ChatResponse`. Pass `configure` to observe deltas while the stream is in flight.

```swift
let response = try await client.send("Tell me a story") { cb in
    cb.onTextDelta = { chunk in
        print(chunk, terminator: "")
    }
    cb.onToolCall   = { info in print("tool:", info.toolName) }
    cb.onToolResult = { info in print("result:", info.toolName) }
}
```

Callbacks are `@Sendable async`. `await` inside them to hop to any actor (e.g. `@MainActor`).

## Tools (Auto Tool-Loop)

Register a handler once. When the agent invokes the tool mid-stream, the SDK runs the handler, submits its output, and continues the conversation — all inside the same `send(...)` call. Unknown tools resolve with an error payload so the agent can recover.

```swift
client.tool("lookup_order") { input in
    guard let id = input["order_id"]?.stringValue else {
        throw ToolError("Missing order_id")
    }
    let order = try await OrderService.fetch(id: id)
    return .object(["status": .string(order.status)])
}

struct ToolError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
```

Handlers are async — they may suspend on UI (e.g. awaiting a user selection) before returning. Throwing surfaces an `{"error": "..."}` payload to the agent.

### Tool loop limit

The SDK caps tool-loop iterations to prevent runaways. Default is 10; override per client:

```swift
let client = ChatbaseClient(agentId: "id", maxToolLoopSteps: 20)
```

Exceeding the limit throws `ChatError.toolLoopLimitExceeded(limit:)`.

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

`loadMore()` carries the cursor needed for the next page.

## Retry

Regenerate an assistant message. Runs the full tool loop.

```swift
let response = try await client.retry(
    conversationId: "conv-id",
    messageId: "msg-id"
)
```

## Non-Streaming

Skips the tool loop and returns the whole reply in one shot. Registered tools do not run.

```swift
let response = try await client.sendNonStreaming("Hello", conversationId: "conv-id")
print(response.message.text)
print(response.finishReason)  // .stop, .error, or .toolCalls
print(response.usage.credits)
```

## Session State

```swift
client.currentConversationId   // last conversation id seen
client.currentUserId           // server-assigned user id (anonymous or identified)
client.newConversation()       // clear currentConversationId
```
