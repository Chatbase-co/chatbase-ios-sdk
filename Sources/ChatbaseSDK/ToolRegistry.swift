import Foundation

public typealias ToolHandler = @Sendable (JSONValue) async throws -> JSONValue

public actor ToolRegistry {
    private var handlers: [String: ToolHandler] = [:]

    public init() {}

    public func register(_ name: String, handler: @escaping ToolHandler) {
        handlers[name] = handler
    }

    public func unregister(_ name: String) {
        handlers.removeValue(forKey: name)
    }

    public func handler(for name: String) -> ToolHandler? {
        handlers[name]
    }
}
