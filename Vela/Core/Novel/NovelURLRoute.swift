//
//  NovelURLRoute.swift
//  Vela
//
//  Chapter neighbours derived from the URL itself.
//
//  Not every novel site puts a usable href on its "next chapter" link. The
//  hash-routed sites in particular render the reader as a single-page app and
//  wire navigation to `javascript:urlpage('next')`, so the extraction script
//  correctly finds no URL at all — and the reader's buttons end up with
//  nothing to open. Their routes, however, are numbered: chapters advance by
//  one in the last route segment (`/#/book/2530/1.html` → `/#/book/2530/2.html`)
//  and the catalog is the book's directory (`/#/book/2530/`).
//
//  This helper derives both from a chapter URL. It is deliberately
//  conservative: it only touches the last route segment, only when that
//  segment looks like a chapter, and never produces a chapter below 1.
//

import Foundation

enum NovelURLRoute {
    /// The URL one chapter forward or back, derived from the route.
    static func shifted(_ urlString: String, by offset: Int) -> String? {
        guard offset != 0, let parts = routeParts(of: urlString) else { return nil }
        guard let route = shiftLastNumber(in: parts.route, by: offset) else { return nil }
        return parts.prefix + route + parts.suffix
    }

    /// The catalog URL for a chapter URL: the chapter segment dropped.
    ///
    /// `https://host/#/book/2530/1.html` → `https://host/#/book/2530/`
    /// `https://host/book/2530/12.html` → `https://host/book/2530/`
    static func catalogURL(for urlString: String) -> String? {
        guard let parts = routeParts(of: urlString) else { return nil }
        var components = parts.route.components(separatedBy: "/")
        guard let last = components.lastIndex(where: { !$0.isEmpty }),
              chapterSegment(components[last], numericComponentsInRoute: components) != nil else {
            return nil
        }
        components.remove(at: last)
        var route = components.joined(separator: "/")
        if !route.hasSuffix("/") { route += "/" }
        return parts.prefix + route + parts.suffix
    }

    /// The chapter number encoded in the URL's last segment, when there is one.
    ///
    /// Used to line a stored chapter URL up with a catalog entry when the two
    /// spellings differ (a trailing slash, a redirect, a different subdomain).
    static func chapterNumber(for urlString: String) -> Int? {
        guard let parts = routeParts(of: urlString) else { return nil }
        let components = parts.route.components(separatedBy: "/")
        guard let last = components.lastIndex(where: { !$0.isEmpty }),
              let segment = chapterSegment(components[last], numericComponentsInRoute: components) else {
            return nil
        }
        return segment.value
    }

    // MARK: - Route parsing

    private struct RouteParts {
        /// Everything before the route, including a `#` for hash routes.
        var prefix: String
        var route: String
        /// A query string, when the route is the path.
        var suffix: String
    }

    /// Splits a URL into the part the route lives in and the rest.
    ///
    /// Hash-routed SPAs put the whole route in the fragment; a plain site puts
    /// it in the path. The query is kept out of the route either way, because
    /// numbers there are parameters, not chapter numbers.
    private static func routeParts(of urlString: String) -> RouteParts? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }

        if let hash = trimmed.firstIndex(of: "#") {
            let fragment = String(trimmed[trimmed.index(after: hash)...])
            if !fragment.isEmpty {
                return RouteParts(
                    prefix: String(trimmed[...hash]),
                    route: fragment,
                    suffix: ""
                )
            }
        }

        guard let schemeRange = trimmed.range(of: "://"),
              let slash = trimmed[schemeRange.upperBound...].firstIndex(of: "/") else {
            return nil
        }
        let prefix = String(trimmed[..<slash])
        var route = String(trimmed[slash...])
        var suffix = ""
        if let query = route.firstIndex(of: "?") {
            suffix = String(route[query...])
            route = String(route[..<query])
        }
        return RouteParts(prefix: prefix, route: route, suffix: suffix)
    }

    // MARK: - Chapter segments

    private struct ChapterSegment {
        var value: Int
        /// Digit count, so a padded route (`001.html`) stays padded.
        var width: Int
        /// The extension, or whatever followed the digits in the segment.
        var suffix: String
        /// True when the segment is only a number (`/book/2530/12`). Such an
        /// id is a chapter only when another numeric segment precedes it.
        var isBare: Bool
    }

    private static func shiftLastNumber(in route: String, by offset: Int) -> String? {
        var components = route.components(separatedBy: "/")
        guard let last = components.lastIndex(where: { !$0.isEmpty }),
              let segment = chapterSegment(components[last], numericComponentsInRoute: components) else {
            return nil
        }
        let value = segment.value + offset
        guard value >= 1, value <= 99_999_999 else { return nil }
        let digits = String(value)
        let padded = digits.count >= segment.width
            ? digits
            : String(repeating: "0", count: segment.width - digits.count) + digits
        components[last] = padded + segment.suffix
        return components.joined(separator: "/")
    }

    private static func chapterSegment(
        _ component: String,
        numericComponentsInRoute components: [String]
    ) -> ChapterSegment? {
        guard !component.isEmpty else { return nil }

        // A query or fragment can leave a `;jsessionid` tail on a path
        // segment; it is not part of the chapter number.
        var base = component.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? component
        var suffix = ""
        if let dot = base.firstIndex(of: ".") {
            suffix = String(base[dot...])
            base = String(base[..<dot])
        }

        // `12_3.html` is page three of chapter twelve on sites that split long
        // chapters; the neighbour is the next chapter's first page.
        if let underscore = base.firstIndex(of: "_") {
            base = String(base[..<underscore])
        }

        let numberPart = String(base.reversed().prefix { $0.isNumber }.reversed())
        guard !numberPart.isEmpty, let value = Int(numberPart), value > 0 else { return nil }

        let isBare = suffix.isEmpty && numberPart == base
        if isBare {
            let numericCount = components.filter { component in
                !component.isEmpty && component.allSatisfy(\.isNumber)
            }.count
            // `/book/2530/` and `/read/12345` are ids, not chapters. A second
            // numeric segment is what makes the last one a chapter number.
            guard numericCount >= 2 else { return nil }
        }

        return ChapterSegment(
            value: value,
            width: numberPart.count,
            suffix: suffix,
            isBare: isBare
        )
    }
}
