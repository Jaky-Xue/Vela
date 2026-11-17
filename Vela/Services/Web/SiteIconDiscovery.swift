//
//  SiteIconDiscovery.swift
//  Vela
//
//  The icon renditions a site names in its own markup.
//
//  A host's icon is otherwise guessed at a few fixed paths —
//  `/apple-touch-icon.png`, `/favicon.ico` — which covers the sites that
//  follow the convention and misses the rest. Most apps publish a 192- or
//  512-pixel icon at a hashed or versioned path and declare it in
//  `<link rel="icon" sizes="512x512">` or in their web app manifest. Reading
//  those declarations is what lets a tile fetch the picture the site actually
//  drew instead of upscaling a 32-pixel `.ico` found at a guess.
//
//  Only the site's own pages are read: the document at `/` and the manifest it
//  points at. Nothing here talks to a third party.
//

import Foundation

/// Reads a site's declared icons, once per host, and keeps the answer.
///
/// The document is fetched at most once per host per process: a home shelf can
/// ask for the same host from several tiles, and a history list would ask on
/// every row. Concurrent callers share one in-flight discovery, and a host
/// that answered nothing is remembered for a while so a page-less site is not
/// re-fetched on every appearance.
actor SiteIconDiscovery {
    static let shared = SiteIconDiscovery()

    /// Fetches a URL and answers the bytes together with the URL they came
    /// from — redirects included, so a relative `href` resolves against the
    /// document it was actually found in.
    typealias Fetch = (URL) async -> (data: Data, url: URL)?

    /// One icon a document declared, with the size it claimed. A document
    /// that declares no size answers `0` and sorts after the ones that did.
    struct DeclaredIcon {
        var url: URL
        var size: Int
    }

    private struct Entry {
        var urls: [URL]
        var at: Date
    }

    private let fetch: Fetch
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<[URL], Never>] = [:]

    /// How long a host that declared nothing is left alone. A site that has
    /// an icon today is not asked again this session; one that does not is
    /// re-read when the user comes back later.
    private let emptyLifetime: TimeInterval = 10 * 60
    private let maximumHosts = 128
    private static let maximumDocumentBytes = 1_500_000
    private static let maximumManifestBytes = 1_000_000

    init(fetch: @escaping Fetch = SiteIconDiscovery.defaultFetch) {
        self.fetch = fetch
    }

    /// Every icon the host declares, largest first. Empty when the site
    /// answers nothing usable — a page with no declarations, or no page.
    func iconUrls(forHost host: String) async -> [URL] {
        let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }

        if let entry = entries[key] {
            if !entry.urls.isEmpty { return entry.urls }
            if Date().timeIntervalSince(entry.at) < emptyLifetime { return [] }
        }
        if let task = inFlight[key] { return await task.value }

        let task = Task<[URL], Never> { [weak self] in
            guard let self else { return [] }
            return await self.discover(host: key)
        }
        inFlight[key] = task
        let urls = await task.value
        inFlight[key] = nil
        entries[key] = Entry(urls: urls, at: Date())
        prune()
        return urls
    }

    private func discover(host: String) async -> [URL] {
        guard let home = URL(string: "https://\(host)/"),
              let page = await fetch(home),
              page.data.count <= Self.maximumDocumentBytes else { return [] }

        let html = String(decoding: page.data, as: UTF8.self)
        var icons = Self.declaredIcons(inHTML: html, baseURL: page.url)

        if let manifest = Self.manifestURL(inHTML: html, baseURL: page.url),
           let document = await fetch(manifest),
           document.data.count <= Self.maximumManifestBytes {
            icons.append(contentsOf: Self.declaredIcons(inManifest: document.data, baseURL: document.url))
        }
        return Self.sorted(icons)
    }

    private func prune() {
        guard entries.count > maximumHosts else { return }
        let keep = entries
            .sorted { $0.value.at > $1.value.at }
            .prefix(maximumHosts)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: - Reading a document

    /// The icons a page declares, in document order.
    ///
    /// `rel` is a space-separated list, so `rel="shortcut icon"` and
    /// `rel="apple-touch-icon-precomposed"` are read the way browsers read
    /// them. An SVG is skipped: it has no pixels to decode and the tile would
    /// fall through to it only to draw nothing.
    nonisolated static func declaredIcons(inHTML html: String, baseURL: URL) -> [DeclaredIcon] {
        var icons: [DeclaredIcon] = []
        for tag in linkTags(in: html) {
            guard let rel = attribute("rel", in: tag)?.lowercased() else { continue }
            let relations = Set(rel.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            // `mask-icon` is deliberately absent: it is defined as an SVG,
            // which has no pixels for a tile to draw.
            guard relations.contains("icon")
                || relations.contains("apple-touch-icon")
                || relations.contains("apple-touch-icon-precomposed") else { continue }
            guard let href = attribute("href", in: tag),
                  let url = resolved(href, base: baseURL) else { continue }
            if let type = attribute("type", in: tag)?.lowercased(), type.contains("svg") { continue }
            icons.append(DeclaredIcon(url: url, size: declaredSize(attribute("sizes", in: tag))))
        }
        return icons
    }

    /// The icons a web app manifest declares.
    nonisolated static func declaredIcons(inManifest data: Data, baseURL: URL) -> [DeclaredIcon] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = object["icons"] as? [[String: Any]] else { return [] }
        return icons.compactMap { icon in
            guard let source = icon["src"] as? String else { return nil }
            let type = (icon["type"] as? String)?.lowercased() ?? ""
            guard !type.contains("svg") else { return nil }
            guard let url = resolved(source, base: baseURL) else { return nil }
            return DeclaredIcon(url: url, size: declaredSize(icon["sizes"] as? String))
        }
    }

    /// Where the page's web app manifest lives, when it names one.
    nonisolated static func manifestURL(inHTML html: String, baseURL: URL) -> URL? {
        for tag in linkTags(in: html) {
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(whereSeparator: { $0.isWhitespace }).contains("manifest"),
                  let href = attribute("href", in: tag) else { continue }
            return resolved(href, base: baseURL)
        }
        return nil
    }

    /// Largest declared size first, undeclared last, duplicates removed.
    nonisolated static func sorted(_ icons: [DeclaredIcon]) -> [URL] {
        var seen = Set<String>()
        return icons
            .enumerated()
            .sorted { left, right in
                if left.element.size != right.element.size {
                    return left.element.size > right.element.size
                }
                return left.offset < right.offset
            }
            .compactMap { pair in
                let key = pair.element.url.absoluteString
                guard seen.insert(key).inserted else { return nil }
                return pair.element.url
            }
    }

    // MARK: - Reading a tag

    /// The `<link …>` tags in a document, without their angle brackets.
    ///
    /// A scanner rather than an HTML parser: this runs on a remote document
    /// whose markup is not trusted, and the only thing wanted from it is a
    /// handful of attributes. A tag cut off by the end of the document is
    /// dropped rather than read past.
    private nonisolated static func linkTags(in html: String) -> [Substring] {
        var tags: [Substring] = []
        var searchStart = html.startIndex
        while let open = html.range(of: "<link", options: [.caseInsensitive], range: searchStart..<html.endIndex) {
            guard let close = html[open.upperBound...].firstIndex(of: ">") else { break }
            tags.append(html[open.upperBound..<close])
            searchStart = html.index(after: close)
        }
        return tags
    }

    /// One attribute's value, quoted or bare.
    ///
    /// The name has to start a word, so `rel` is not found inside `hreflang`
    /// and a value that happens to spell an attribute name is not mistaken
    /// for one.
    private nonisolated static func attribute(_ name: String, in tag: Substring) -> String? {
        var searchStart = tag.startIndex
        while let range = tag.range(of: name, options: [.caseInsensitive], range: searchStart..<tag.endIndex) {
            let startsWord = range.lowerBound == tag.startIndex
                || tag[tag.index(before: range.lowerBound)].isWhitespace
            var cursor = range.upperBound
            while cursor < tag.endIndex, tag[cursor].isWhitespace {
                cursor = tag.index(after: cursor)
            }
            guard startsWord, cursor < tag.endIndex, tag[cursor] == "=" else {
                searchStart = range.upperBound
                continue
            }
            cursor = tag.index(after: cursor)
            while cursor < tag.endIndex, tag[cursor].isWhitespace {
                cursor = tag.index(after: cursor)
            }
            guard cursor < tag.endIndex else { return nil }
            if tag[cursor] == "\"" || tag[cursor] == "'" {
                let quote = tag[cursor]
                let valueStart = tag.index(after: cursor)
                guard let end = tag[valueStart...].firstIndex(of: quote) else { return nil }
                return String(tag[valueStart..<end])
            }
            let valueStart = cursor
            var end = cursor
            while end < tag.endIndex, !tag[end].isWhitespace, tag[end] != "/" {
                end = tag.index(after: end)
            }
            return String(tag[valueStart..<end])
        }
        return nil
    }

    /// An `href`/`src` as an absolute http(s) URL, or `nil` for anything the
    /// tile could not fetch — `data:`, `javascript:`, `file:`.
    private nonisolated static func resolved(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute: URL?
        if trimmed.hasPrefix("//"), let scheme = base.scheme {
            absolute = URL(string: scheme + ":" + trimmed)
        } else {
            absolute = URL(string: trimmed, relativeTo: base)?.absoluteURL
        }
        guard let url = absolute,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// The largest edge a `sizes` attribute claims. `any` and a missing
    /// attribute answer `0`, which sorts them after the sized renditions.
    private nonisolated static func declaredSize(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        var largest = 0
        for token in raw.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            let parts = token.split(separator: "x")
            guard parts.count == 2,
                  let width = Int(parts[0]),
                  let height = Int(parts[1]) else { continue }
            largest = max(largest, max(width, height))
        }
        return largest
    }

    // MARK: - Network

    private static func defaultFetch(_ url: URL) async -> (data: Data, url: URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "text/html,application/xhtml+xml,application/manifest+json;q=0.9,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return (data, http.url ?? url)
    }
}
