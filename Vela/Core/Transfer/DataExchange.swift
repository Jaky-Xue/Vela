//
//  DataExchange.swift
//  Vela
//
//  Bookmark and history interchange formats.
//
//  The bookmark format is Netscape's bookmark file, which Safari, Chrome,
//  Firefox and Edge all import and export; the history format is this app's
//  own JSON. Both are parsed without WebKit or the database so a test can
//  exercise the format on its own.
//

import Foundation

// MARK: - Bookmarks

/// One node read out of an imported bookmark file.
public struct ImportedBookmarkNode: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var url: String?
    public var children: [ImportedBookmarkNode]

    public init(
        id: String = UUID().uuidString,
        title: String,
        url: String? = nil,
        children: [ImportedBookmarkNode] = []
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
    }

}

public enum BookmarkExchange {
    /// Writes the Netscape bookmark document every desktop browser reads.
    public static func netscapeHTML(roots: [(title: String, items: [BookmarkTreeItem])]) -> String {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>"
        ]
        for root in roots {
            lines.append("    <DT><H3>\(escape(root.title))</H3>")
            lines.append("    <DL><p>")
            append(root.items, indent: 2, into: &lines)
            lines.append("    </DL><p>")
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func append(_ items: [BookmarkTreeItem], indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "    ", count: indent)
        for item in items {
            if let url = item.node.url, !url.isEmpty {
                lines.append("\(pad)<DT><A HREF=\"\(escape(url))\">\(escape(item.node.title))</A>")
            } else {
                lines.append("\(pad)<DT><H3>\(escape(item.node.title))</H3>")
                lines.append("\(pad)<DL><p>")
                append(item.children, indent: indent + 1, into: &lines)
                lines.append("\(pad)</DL><p>")
            }
        }
    }

    /// Reads a Netscape bookmark document into a tree. Unknown markup is
    /// ignored rather than failing the import: a hand-edited file that keeps
    /// its anchors is still worth importing.
    public static func parseNetscapeHTML(_ text: String) -> [ImportedBookmarkNode] {
        final class Builder {
            var title: String
            var url: String?
            var children: [Builder] = []
            init(title: String, url: String? = nil) {
                self.title = title
                self.url = url
            }
            func freeze() -> ImportedBookmarkNode {
                ImportedBookmarkNode(
                    title: title,
                    url: url,
                    children: children.map { $0.freeze() }
                )
            }
        }

        let root = Builder(title: "")
        var stack: [(node: Builder, childDepth: Int)] = []
        var depth = 0

        func parent(for level: Int) -> Builder {
            if let top = stack.last, top.childDepth == level { return top.node }
            return root
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
            let lowered = line.lowercased()
            if lowered.contains("<dl") {
                depth += 1
            }
            while let top = stack.last, depth < top.childDepth {
                stack.removeLast()
            }

            if let title = firstGroup(folderPattern, in: line) {
                let node = Builder(title: unescape(stripTags(title)))
                parent(for: depth).children.append(node)
                stack.append((node, depth + 1))
            } else if let anchor = anchor(in: line) {
                let node = Builder(title: unescape(stripTags(anchor.title)), url: anchor.url)
                parent(for: depth).children.append(node)
            }

            if lowered.contains("</dl") {
                depth = max(0, depth - 1)
            }
        }

        return root.children.map { $0.freeze() }
    }

    // MARK: Parsing helpers

    private static let folderPattern = try? NSRegularExpression(
        pattern: "<H3[^>]*>(.*?)</H3>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let anchorPattern = try? NSRegularExpression(
        pattern: "<A\\s+[^>]*?HREF\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</A>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func firstGroup(_ pattern: NSRegularExpression?, in line: String) -> String? {
        guard let pattern else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = pattern.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[group])
    }

    private static func anchor(in line: String) -> (url: String, title: String)? {
        guard let pattern = anchorPattern else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = pattern.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 2,
              let urlRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 2), in: line) else { return nil }
        let url = unescape(String(line[urlRange]))
        let lowered = url.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
        return (url, String(line[titleRange]))
    }

    private static func stripTags(_ value: String) -> String {
        value.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func unescape(_ value: String) -> String {
        var text = value
        let named = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if let pattern = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = pattern.matches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            )
            for match in matches.reversed() {
                guard let full = Range(match.range, in: text),
                      let digits = Range(match.range(at: 1), in: text),
                      let scalar = UInt32(text[digits]),
                      let unicode = UnicodeScalar(scalar) else { continue }
                text.replaceSubrange(full, with: String(Character(unicode)))
            }
        }
        return text
    }
}

// MARK: - History

/// One history row in the interchange document.
public struct HistoryExchangeEntry: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var lastVisitAt: Date
    public var visitCount: Int

    public init(url: String, title: String, lastVisitAt: Date, visitCount: Int) {
        self.url = url
        self.title = title
        self.lastVisitAt = lastVisitAt
        self.visitCount = visitCount
    }
}

public enum HistoryExchange {
    public static func json(from items: [HistoryUrl]) -> Data {
        let entries = items.map {
            HistoryExchangeEntry(
                url: $0.url,
                title: $0.title,
                lastVisitAt: $0.lastVisitAt,
                visitCount: $0.visitCount
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }

    public static func parse(_ data: Data) throws -> [HistoryExchangeEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HistoryExchangeEntry].self, from: data)
    }
}
