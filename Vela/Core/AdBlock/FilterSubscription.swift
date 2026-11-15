import Foundation

public struct FilterSubscription: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var url: String
    public var enabled = true
    public var cacheHash: String?
    public var etag: String?
    public var lastModified: String?
    public var lastSuccess: Date?
    public var error: String?
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public struct FilterSnapshotInfo: Codable, Equatable, Sendable {
    public var identifier: String
    public var networkCount: Int
    public var hiddenCount: Int
    public var skippedCount: Int
    public var createdAt: Date
}

enum FilterValidation {
    static let sourceByteLimit = 2_000_000
    static let combinedByteLimit = 8_000_000
    static func validate(_ text: String, limit: Int = sourceByteLimit) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty, text.utf8.count <= limit,
              !lower.hasPrefix("<!doctype"), !lower.hasPrefix("<html"), !lower.contains("<body"),
              !text.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("!#include") }) else {
            throw FilterError.invalid("过滤文本为空、超限、包含 HTML 或未支持的 include 指令")
        }
        let result = AdBlockRuleCompiler.compile(filterList: text)
        guard !result.rules.isEmpty, result.invalidRuleCount == 0 else {
            throw FilterError.invalid("过滤文本没有有效规则或含无效行，旧版本已保留")
        }
    }
}

enum FilterError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}
