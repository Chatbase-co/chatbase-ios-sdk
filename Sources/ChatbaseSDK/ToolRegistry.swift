import Foundation

public typealias ToolHandler = @Sendable (JSONValue) async throws -> JSONValue

final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: ToolHandler] = [:]

    func register(_ name: String, handler: @escaping ToolHandler) {
        lock.lock(); defer { lock.unlock() }
        tools[name] = handler
    }

    func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        tools[name] = nil
    }

    func get(_ name: String) -> ToolHandler? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }
}
