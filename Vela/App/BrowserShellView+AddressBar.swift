import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    /// The tallest the suggestion card may grow.
    ///
    /// Measured from the card's bottom edge (just above the command bar) up to
    /// the keyboard: a card that ignored the keyboard would put its last rows
    /// where they can never be tapped, which is the "list cut off" failure this
    /// budget exists to prevent. The card still sizes to its content — this is
    /// only the ceiling.
    var omniboxCardHeight: CGFloat {
        let screenHeight = safeRectHeight + safeTop + safeBottom
        let spaceAboveBar = screenHeight - keyboardHeight
            - safeBottom - BrowserChrome.barHeight - BrowserChrome.barGap - 6
        return min(max(200, spaceAboveBar), BrowserMetrics.omniboxCardMaxHeight)
    }

    var omniboxPlaceholder: String {
        let engine = env.settings.preferences.searchEngine.activeEngine.name
        return "用 \(engine) 搜索或输入网址"
    }

    var displayUrl: String {
        guard let tab = activeTab else { return "" }
        if tab.isHome { return "" }
        // A redirect updates `pendingUrl` before the new document commits.
        // Showing only `url` left the field on the address the user typed
        // while the browser was already somewhere else (R-23).
        return tab.pendingUrl.isEmpty ? tab.url : tab.pendingUrl
    }

    /// Pushes the active tab's address into the omnibox.
    ///
    /// The field shows the page's URL while the omnibox is closed — which the
    /// pre-refactor bar did not, leaving the placeholder on screen instead of
    /// the address of the page being read.
    func syncAddressText() {
        omnibox.currentPageUrl = displayUrl
        guard !omnibox.isEditing else { return }
        if omnibox.text != displayUrl {
            omnibox.text = displayUrl
        }
    }

    // MARK: - Omnibox wiring

    func wireOmnibox() {
        omnibox.onSelectSuggestion = { suggestion in
            commitSuggestion(suggestion)
        }
        omnibox.onCommitText = { input in
            submitAddressBar(input)
        }
    }

    // MARK: - Navigation

    /// The tab an omnibox submission lands in.
    ///
    /// An empty tab strip is a state the user can reach — closing everything
    /// leaves none — and a query typed into an address bar with no tabs must
    /// not evaporate. The submission opens the tab it needs.
    var submissionTab: BrowserTabState {
        activeTab ?? tabManager.createTab(openSource: .user)
    }

        /// Writes a search query into the suggestion history unless the user has
    /// asked the browser not to keep history at all.
    func recordSearchQuery(
        _ query: String,
        engineId: SearchEngineId,
        boundary: BrowserDataBoundary
    ) {
        guard !(env.settings.preferences.historyNotRetained ?? false) else { return }
        try? env.searchHistory.record(
            query: query,
            searchEngineId: engineId,
            boundary: boundary
        )
    }

    func submitAddressBar(_ input: String) {
        let tab = submissionTab
        let engine = env.settings.preferences.searchEngine.activeEngine

        switch BrowserUrlResolver.resolve(input: input, searchEngine: engine) {
        case let .navigate(url):
            omnibox.endEditing()
            navigate(to: url, in: tab)

        case let .handOff(url):
            // A scheme that belongs to another app. Handing it to the system
            // without touching the tab is what keeps the page the user is on
            // where it was — the same reason the web engine does not navigate to
            // one either.
            omnibox.endEditing()
            UIApplication.shared.open(url)

        case let .search(url):
            recordSearchQuery(input, engineId: engine.id, boundary: tab.dataBoundary)
            omnibox.endEditing()
            navigate(to: url, in: tab)

        case let .rejected(reason):
            // An input the browser will not act on is reported. Silently closing
            // the omnibox — which is what used to happen for every one of these —
            // makes a refused scheme look like a browser that lost the keystroke.
            omnibox.endEditing()
            addressNotice = Self.message(for: reason, input: input)
            rejectedInput = input
        }
    }

    static func message(for reason: AddressBarRejection, input: String) -> String {
        switch reason {
        case .empty:
            return "请输入网址或搜索内容。"
        case let .unsupportedScheme(scheme):
            return "Vela 无法打开 \(scheme): 开头的地址。"
        case .noUsableSearchEngine:
            return "当前搜索引擎没有配置搜索地址模板，无法搜索。"
        }
    }

    /// Searches for an input that was refused, which is what the refusal alert
    /// offers as the way forward.
    func searchRefusedInput(_ input: String) {
        let tab = submissionTab
        let engine = env.settings.preferences.searchEngine.activeEngine
        guard let url = engine.searchUrl(for: input) else { return }
        recordSearchQuery(input, engineId: engine.id, boundary: tab.dataBoundary)
        navigate(to: url, in: tab)
    }

    func navigate(to url: URL, in tab: BrowserTabState) {
        // An external scheme cannot be loaded, so it is handed to the system.
        if let scheme = url.scheme?.lowercased(),
           BrowserUrlResolver.externalSchemes.contains(scheme) {
            UIApplication.shared.open(url)
            return
        }

        // `TabManager` owns the load, so an address-bar navigation and a link
        // opened into a new tab go through the same path — including the one
        // that decides whether to create the tab's web view yet. It also clears
        // the home flag and writes the URL onto the tab.
        chromeHidden = false
        resetChromeDrag()
        scrollTracker.accumulation = 0
        scrollTracker.upwardTravel = 0
        tabManager.load(url: url, in: tab)
        // The transition is recorded by the navigation delegate, which is the
        // only place that sees the navigation type.
        syncAddressText()
    }

    func commitSuggestion(_ suggestion: OmniboxSuggestion) {
        switch suggestion.kind {
        case .openTab(let tabId):
            omnibox.endEditing()
            tabManager.activateTab(id: tabId)

        case let .search(engineId), let .remote(engineId):
            var engine = env.settings.preferences.searchEngine.activeEngine
            if engine.id != engineId {
                env.settings.setDefaultSearchEngine(id: engineId)
                engine = env.settings.preferences.searchEngine.activeEngine
            }
            guard let url = engine.searchUrl(for: suggestion.title) else {
                omnibox.endEditing()
                return
            }
            recordSearchQuery(
                suggestion.title,
                engineId: engine.id,
                boundary: activeTab?.dataBoundary ?? .persistent
            )
            omnibox.endEditing()
            navigate(to: url, in: submissionTab)

        case .pastQuery:
            // A past query is re-run, not loaded: the row's completion is the
            // query text, not a URL.
            let engine = env.settings.preferences.searchEngine.activeEngine
            guard let url = engine.searchUrl(for: suggestion.completion) else {
                omnibox.endEditing()
                return
            }
            recordSearchQuery(
                suggestion.completion,
                engineId: engine.id,
                boundary: activeTab?.dataBoundary ?? .persistent
            )
            omnibox.endEditing()
            navigate(to: url, in: submissionTab)

        default:
            guard let url = URL(string: suggestion.completion) else {
                omnibox.endEditing()
                return
            }
            omnibox.endEditing()
            navigate(to: url, in: submissionTab)
        }
    }
}
