import Foundation
import CryptoKit

public struct PendingScriptUpdate: Codable, Equatable, Sendable {
    public var candidateHash: String
    public var baseUpdatedAt: Date
    public var fromVersion: String
    public var toVersion: String
    public var changes: [String]
}
public struct PreviousScriptVersion: Codable, Equatable, Sendable {
    public var snapshotHash: String
    public var version: String
}

/// Immutable snapshots stay off UserDefaults. Leases protect staged files
/// while an operation awaits database work or user-confirmation metadata.
actor UserScriptVersionStore {
    let directory: URL
    private var leases: [String: Int] = [:]
    init(directory: URL) { self.directory = directory }

    func save<T: Encodable & Sendable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 100_000_000 else { throw UserScriptServiceError.writeFailed("版本快照超过上限") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(hash), options: .atomic)
        leases[hash, default: 0] += 1
        return hash
    }
    func load<T: Decodable & Sendable>(_ type: T.Type, hash: String) throws -> T {
        let url = try file(hash)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100_000_000 else { throw UserScriptServiceError.parseFailed("版本快照超限") }
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw UserScriptServiceError.parseFailed("版本快照校验失败")
        }
        return try JSONDecoder().decode(type, from: data)
    }
    func release(_ hash: String) {
        if let count = leases[hash], count > 1 { leases[hash] = count - 1 }
        else { leases.removeValue(forKey: hash) }
    }
    func prune(keeping hashes: Set<String>) {
        let keep = hashes.union(leases.keys)
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.deletingPathExtension().lastPathComponent
            if url.pathExtension == "json", name.count == 64, name.allSatisfy(\.isHexDigit), !keep.contains(name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    private func file(_ hash: String) throws -> URL {
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw UserScriptServiceError.parseFailed("版本标识无效") }
        return directory.appendingPathComponent(hash + ".json")
    }
}
