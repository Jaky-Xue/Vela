//
//  NavigationTestSupport.swift
//  VelaTests
//
//  The scaffolding the navigation tests share: a tiny HTTP server, and a
//  production-shaped `TabManager` + `BrowserWebCoordinator` pair.
//
//  Two deliberate choices:
//
//    * The tests drive the *production* path — `TabManager.load(url:in:)` with
//      the real `BrowserWebCoordinator` as the delegate — rather than a stub
//      delegate written to agree with them. A stub would verify that the test
//      agrees with itself.
//    * Pages come from a local server rather than the public internet, so a
//      result means something about Vela and not about someone else's uptime.
//      `PublicWebSmokeTests` exists separately for the real-network half.
//

import XCTest
import Network
import WebKit
@testable import Vela

// MARK: - Local HTTP server

/// A single-purpose HTTP/1.1 server for the navigation tests.
///
/// One request per connection and `Connection: close` in the reply, which is all
/// a `WKWebView` needs and all these tests ask for. Routes are fixed at
/// construction, so the connection handler never mutates shared state.
final class LocalHTTPServer {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: String = ""
        /// A `Content-Type` the caller can override, e.g. to trigger a download.
        var contentType: String = "text/html; charset=utf-8"
        /// Held before the response is written. Used to observe a tab that is
        /// still loading.
        var delay: TimeInterval = 0

        static func html(_ body: String, status: Int = 200) -> Response {
            Response(status: status, body: body)
        }

        static func redirect(to location: String) -> Response {
            Response(
                status: 302,
                headers: ["Location": location],
                body: ""
            )
        }
    }

    let routes: [String: Response]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.vela.tests.http-server")

    /// How many times each path has been asked for.
    ///
    /// Guarded rather than atomic because connections arrive on `queue` and the
    /// assertions read it from the test's main actor.
    private let counterLock = NSLock()
    private var requestCounts: [String: Int] = [:]

    private(set) var port: UInt16 = 0

    /// The number of requests received for a path.
    func requestCount(for path: String) -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return requestCounts[path] ?? 0
    }

    /// Every path asked for, in arrival order.
    var requestedPaths: [String] {
        counterLock.lock()
        defer { counterLock.unlock() }
        return requestOrder
    }

    private var requestOrder: [String] = []

    init(routes: [String: Response]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        // Loopback only: nothing outside this process can reach it, and no
        // local-network permission is involved.
        parameters.requiredInterfaceType = .loopback
        self.listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening and returns the base URL.
    @MainActor
    func start() async throws -> URL {
        let rawPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                case let .failed(error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection, buffer: Data())
            }

            listener.start(queue: queue)
        }

        port = rawPort
        guard port != 0, let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw XCTSkip("the local http server did not start")
        }
        return url
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            // The request head ends at the first blank line; nothing here sends a
            // body, so that is the whole request.
            if let head = String(data: accumulated, encoding: .utf8),
               let range = head.range(of: "\r\n\r\n") {
                let path = Self.path(of: head)
                self.respond(on: connection, path: path, head: String(head[..<range.lowerBound]))
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private static func path(of head: String) -> String {
        guard let line = head.split(separator: "\r\n").first else { return "/" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        let target = String(parts[1])
        // The route table is keyed by path, without the query.
        return target.split(separator: "?").first.map(String.init) ?? target
    }

    private func respond(on connection: NWConnection, path: String, head: String) {
        counterLock.lock()
        requestCounts[path, default: 0] += 1
        requestOrder.append(path)
        counterLock.unlock()

        let response = routes[path] ?? Response.html(
            "<!doctype html><html><body><h1>404</h1></body></html>",
            status: 404
        )

        let write: () -> Void = {
            var text = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
            text += "Content-Type: \(response.contentType)\r\n"
            let body = Data(response.body.utf8)
            text += "Content-Length: \(body.count)\r\n"
            for (name, value) in response.headers {
                text += "\(name): \(value)\r\n"
            }
            text += "Connection: close\r\n\r\n"

            var payload = Data(text.utf8)
            payload.append(body)

            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }

        if response.delay > 0 {
            queue.asyncAfter(deadline: .now() + response.delay, execute: write)
        } else {
            write()
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 302: return "Found"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    /// A loopback port that nothing is listening on.
    ///
    /// Taken from a server that is started and then stopped, so the port is
    /// genuinely free: a number picked by hand is only probably closed, and a low
    /// privileged port turns out not to be refused the way an ordinary closed
    /// port is.
    static func closedLoopbackPort() async throws -> UInt16 {
        let server = try LocalHTTPServer(routes: [:])
        _ = try await server.start()
        let port = server.port
        server.stop()
        // Give the socket a moment to be released, so the connection is refused
        // rather than accepted by a socket that is on its way out.
        try? await Task.sleep(nanoseconds: 100_000_000)
        return port
    }
}

// MARK: - Pages

enum TestPages {
    /// A plain page whose title the test can assert on.
    static func titled(_ title: String, body: String = "<p>hello</p>") -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>\(title)</title></head>
        <body>\(body)</body>
        </html>
        """
    }

    /// A page that rewrites its own title from script, which is how "does
    /// JavaScript actually run" is answered without a console.
    static let javascript = """
    <!doctype html>
    <html>
    <head><meta charset="utf-8"><title>before</title></head>
    <body>
      <div id="marker">static</div>
      <script>
        document.title = 'after';
        document.getElementById('marker').textContent = 'ran';
      </script>
    </body>
    </html>
    """

    /// A page with a link for each way a page can open something.
    static func links() -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>links</title></head>
        <body>
          <a id="same" href="/two">same frame</a>
          <a id="blank" href="/two" target="_blank">new window</a>
          <a id="external" href="mailto:someone@example.com">mail</a>
        </body>
        </html>
        """
    }

    /// A page carrying an element the shipped cosmetic rules hide, plus a body
    /// the test can prove is still visible.
    static let withAdSlot = """
    <!doctype html>
    <html>
    <head><meta charset="utf-8"><title>ads</title></head>
    <body>
      <div id="content">content</div>
      <div class="ad-banner" id="slot">buy something</div>
    </body>
    </html>
    """
}

// MARK: - Harness

/// A `TabManager` wired to the real coordinator, with an in-memory database.
@MainActor
final class BrowserHarness {
    let settings: SettingsService
    let coordinator: BrowserWebCoordinator
    let tabManager: TabManager
    let adBlock: AdBlockEngine
    let navigationLog: NavigationLog
    let history: HistoryService

    init() throws {
        // A defaults suite of its own, so a test run cannot read or write the
        // developer's settings.
        let suiteName = "org.vela.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let settings = SettingsService(defaults: defaults)
        self.settings = settings

        let database = try SQLiteDatabase(path: ":memory:")
        let history = HistoryService(repository: HistoryRepository(database: database), settings: settings)
        self.history = history
        let bookmarks = BookmarkService(repository: BookmarkRepository(database: database))
        let downloads = DownloadService(repository: DownloadRepository(database: database), settings: settings)
        let userScripts = UserScriptRepository(database: database)
        let searchHistory = SearchHistoryRepository(database: database)
        let sessions = TabSessionRepository(database: database)

        // The same store the app uses. A temporary store of the test's own would
        // be tidier, but the point of these tests is to exercise what ships, and
        // a rule list WebKit refuses to compile into one store is not evidence
        // about the store that matters.
        //
        // `WKContentRuleListStore.default()` is failable in the Swift interface,
        // and the app's own default argument would trap on nil rather than
        // reporting it; a test that crashes on that is a test that hides the
        // reason.
        guard let store = WKContentRuleListStore.default() else {
            throw XCTSkip("WebKit returned no default content rule list store")
        }
        let adBlock = AdBlockEngine(store: store)
        self.adBlock = adBlock

        let navigationLog = NavigationLog()
        self.navigationLog = navigationLog

        let overlays = WebPageOverlays()
        let coordinator = BrowserWebCoordinator(
            overlays: overlays,
            settings: settings,
            adBlock: adBlock,
            history: history,
            downloads: downloads,
            userScripts: userScripts,
            navigationLog: navigationLog
        )
        self.coordinator = coordinator

        let tabManager = TabManager(configurationProvider: coordinator, sessionRepository: sessions)
        self.tabManager = tabManager
        coordinator.attach(tabManager: tabManager)

        _ = tabManager.createTab()
    }

    /// Compiles the shipped filter lists, which is what the app does at launch.
    ///
    /// Returns whether WebKit accepted them. The answer is returned rather than
    /// asserted so that only the tests *about* ad blocking fail when it does not:
    /// a smoke test asking whether the network works should not be reported as a
    /// failure because a rule list did not compile.
    @discardableResult
    func installShippedAdBlockRules(enabled: Bool = true) async -> Bool {
        do {
            let compiled = try await adBlock.compile(
                filterLists: AdBlockBuiltInRules.filterLists,
                orderedSourceIds: AdBlockBuiltInRules.sources.map(\.id),
                exceptedHosts: [],
                includeCosmetic: true,
                enabled: enabled
            )
            guard enabled else {
                return !adBlock.isReady && adBlock.attachedRuleLists().isEmpty
            }
            return compiled.ruleCount > 0
                && !compiled.cosmeticSelectors.isEmpty
                && adBlock.isReady
                && !adBlock.attachedRuleLists().isEmpty
        } catch {
            return false
        }
    }

    /// Why the last ad-block install did not produce a usable rule list.
    var adBlockCompileError: String? {
        adBlock.lastError
    }

    /// The navigation log for one tab, as text.
    ///
    /// Used in assertion messages so a failure says which callbacks actually
    /// arrived rather than only which state was expected.
    func trace(for tab: BrowserTabState) -> String {
        let lines = navigationLog.entries
            .filter { $0.tabId == tab.id }
            .map(\.displayLine)
        return lines.isEmpty ? "（无导航记录）" : lines.joined(separator: " | ")
    }

    /// Opens a URL in a fresh tab, which is how every navigation test starts.
    @discardableResult
    func open(_ url: URL) -> BrowserTabState {
        tabManager.openTab(url: url)
    }
}

// MARK: - Waiting

/// Waits for a bounded time for a condition, without failing when it does not
/// arrive.
///
/// For the questions that are being *asked* rather than asserted — a retry loop,
/// or a wait whose timeout means "no" rather than "broken".
@MainActor
func pollUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Waits for a bounded time for a condition the main actor will make true.
///
/// Polling rather than a fixed sleep: a sleep long enough to cover the slowest
/// machine is a suite that takes a minute to prove nothing, and a sleep short
/// enough to be quick is a race. Every caller passes a real deadline, and a
/// timeout reports what the tab actually looked like.
@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 15,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async -> Bool {
    let arrived = await pollUntil(timeout: timeout, condition)
    if !arrived {
        XCTFail("timed out after \(timeout)s waiting for: \(description)", file: file, line: line)
    }
    return arrived
}

/// Waits for a tab's navigation to settle — finished, failed or crashed — and,
/// when a title is expected, for the title to arrive.
///
/// The title is a separate wait because it legitimately arrives a moment after
/// `didFinish`: WebKit updates `WKWebView.title` from an observer that can lose
/// the race against a small document, and the coordinator fills the gap by
/// asking the document. Waiting for the settle alone would assert against a tab
/// that is still about to be given its title.
@MainActor
@discardableResult
func waitForSettled(
    _ tab: BrowserTabState,
    expectingTitle title: String? = nil,
    timeout: TimeInterval = 20
) async -> Bool {
    await waitUntil(
        "tab to settle (state=\(tab.loadState.rawValue), loading=\(tab.isLoading))"
            + (title.map { " and report the title \($0)" } ?? ""),
        timeout: timeout
    ) {
        guard !tab.loadState.isInFlight, !tab.isLoading else { return false }
        guard let title else { return true }
        return tab.title == title
    }
}
