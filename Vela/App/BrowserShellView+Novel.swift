import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    /// The novel reader layer.
    ///
    /// Kept out of the root modifier chain: that chain is already at the type
    /// checker's budget, and the reader's closures are large.
    @ViewBuilder
    var novelReaderLayer: some View {
        if let session = novelSession {
            NovelReaderView(
                book: session.book,
                initialChapter: session.chapter,
                runtime: session.runtime,
                isPrivateSession: session.isPrivateSession,
                sessionGeneration: session.sessionGeneration,
                onClose: {
                    if session.isCurrent(in: novelSession) {
                        closeNovelSession()
                    }
                },
                onOpenInBrowser: { url in
                    guard session.isCurrent(in: novelSession) else { return }
                    closeNovelSession()
                    openInBrowser(url, for: session)
                }
            )
            .transition(.opacity)
            .zIndex(40)
        }
    }

    /// Closes a reader or shelf left behind by an earlier private generation.
    ///
    /// A regular reader always answers false, so a private session's begin/end
    /// never dismisses it.
    func handlePrivateNovelGeneration(_ generation: Int) {
        if bookshelfIsPrivate, bookshelfGeneration != generation {
            showBookshelf = false
            bookshelfLibrary = nil
            bookshelfIsPrivate = false
        }
        guard let session = novelSession, session.shouldClose(for: generation) else { return }
        session.runtime.cancel()
        novelSession = nil
    }

    // MARK: - Novel mode

    /// Extracts the page as a novel chapter and opens it on the shelf.
    ///
    /// A page that does not yield a chapter is reported rather than silently
    /// ignored: the user pressed a button and is owed an answer. Extraction
    /// runs on the live web view, so the chapter it opens is the page that is
    /// actually on screen.
    func activateNovelMode() {
        guard NovelModeService.isLikelyNovel(activeTab?.url ?? ""),
              let tab = activeTab, !tab.isHome,
              let webView = tabManager.webView(for: tab.id) else {
            novelNotice = "这个页面看起来不是小说章节。打开一本小说的正文页后再试。"
            return
        }

        // Bind the shelf to the tab's session before extraction starts: the
        // private service belongs to this private session, and the reader
        // must keep using it even if the environment later drops its reference.
        let isPrivate = tab.privacyMode == .private
        let generation = env.privateNovelSessionGeneration
        let identity = TabDocumentIdentity(tab: tab)

        Task { @MainActor in
            guard let library = await env.novelLibrary(privateMode: isPrivate) else {
                novelNotice = "私密模式下无法创建独立的小说存储。"
                return
            }
            guard !isPrivate || generation == env.privateNovelSessionGeneration else { return }
            var extraction = await NovelModeService.extract(from: webView, url: tab.url)
            if extraction == nil {
                // A hash-routed chapter may still be painting after the user
                // opens the menu; one delayed retry catches that.
                try? await Task.sleep(nanoseconds: 700_000_000)
                extraction = await NovelModeService.extract(from: webView, url: tab.url)
            }
            guard let extraction else {
                novelNotice = "没能从这一页提取出正文。它可能不是章节页，或正文由脚本动态加载。"
                return
            }
            // The extraction may finish after the tab has navigated or the
            // user switched tabs; the result then belongs to another document.
            guard identity.matches(activeTab) else { return }
            // A private session that ended during extraction must not open a
            // reader into the next session's shelf.
            guard !isPrivate || generation == env.privateNovelSessionGeneration else { return }
            guard let opened = library.open(extraction) else {
                novelNotice = "这一章无法加入书架，请稍后再试。"
                return
            }
            openNovel(
                opened.book,
                chapter: opened.chapter,
                sourceTabId: tab.id,
                library: library,
                isPrivateSession: isPrivate,
                sessionGeneration: generation
            )
        }
    }

    func openNovel(
        _ book: NovelBook,
        chapter: NovelChapter?,
        sourceTabId: String,
        library: NovelLibraryService,
        isPrivateSession: Bool,
        sessionGeneration: Int
    ) {
        // A late open from an ended private session must not resurrect a
        // reader into the session that replaced it.
        guard !isPrivateSession || sessionGeneration == env.privateNovelSessionGeneration else { return }
        novelSession = NovelSession(
            book: book,
            chapter: chapter,
            sourceTabId: sourceTabId,
            isPrivateSession: isPrivateSession,
            sessionGeneration: sessionGeneration,
            library: library
        )
    }

    /// Opens the shelf for the active tab's session.
    ///
    /// The library is captured now so a tab switch behind the sheet cannot
    /// swap the database under it, and a private shelf never falls back to the
    /// regular one when its in-memory database cannot be created.
    func openBookshelf() {
        let isPrivate = activeTab?.privacyMode == .private
        let generation = env.privateNovelSessionGeneration
        let sourceTabId = activeTab?.id ?? ""
        Task { @MainActor in
            guard let library = await env.novelLibrary(privateMode: isPrivate) else {
                novelNotice = "私密模式下无法创建独立的小说存储。"
                return
            }
            guard !isPrivate || generation == env.privateNovelSessionGeneration else { return }
            bookshelfIsPrivate = isPrivate
            bookshelfGeneration = generation
            bookshelfSourceTabId = sourceTabId
            bookshelfLibrary = library
            showBookshelf = true
        }
    }

    /// Opens a chapter in the browser on behalf of a novel session.
    ///
    /// The target is decided from the session, not from whatever tab happens
    /// to be active: a private reader may only use its own live private source
    /// tab or a new private tab. A stale private session is refused. The
    /// regular path keeps the previous behaviour exactly.
    func openInBrowser(_ url: URL, for session: NovelSession) {
        let target = NovelBrowserRouting.target(
            isPrivateSession: session.isPrivateSession,
            sessionGeneration: session.sessionGeneration,
            currentGeneration: env.privateNovelSessionGeneration,
            sourceTabId: session.sourceTabId,
            tabs: tabManager.tabs.map { (id: $0.id, privacyMode: $0.privacyMode) },
            activeTabId: activeTab?.id
        )
        switch target {
        case .refuse:
            return
        case let .existingTab(id):
            guard let tab = tabManager.tab(id: id) else { return }
            // Issue the request before activation: activating a cold tab would
            // otherwise fetch its old URL first, only for this load to replace it.
            navigate(to: url, in: tab)
            tabManager.activateTab(id: tab.id)
        case .newPrivateTab:
            tabManager.openTab(url: url, privacyMode: .private, openSource: .user)
        case let .activeTab(id):
            guard let tab = tabManager.tab(id: id) else { return }
            navigate(to: url, in: tab)
        case .newRegularTab:
            let tab = tabManager.createTab(openSource: .user)
            navigate(to: url, in: tab)
        }
    }

    /// Runs the failed navigation again.
    ///
    /// Deliberately not `reloadActiveTab`: a tab showing the error surface may
    /// have no committed document at all, in which case `reload()` is a no-op on
    /// its web view and the button would appear to do nothing. `TabManager.reload`
    /// decides between re-requesting and re-displaying; this only has to say
    /// which tab.
    func retry(_ tab: BrowserTabState) {
        _ = tabManager.reload(tab: tab)
    }
}
