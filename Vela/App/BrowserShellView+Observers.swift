import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    /// The effects and observers that keep the chrome in step with the page.
    ///
    /// The chain is split every few modifiers on purpose: a single expression
    /// carrying the whole hierarchy, the layers, the notices and every observer
    /// outgrew the type checker's budget, and the failure surfaced at whichever
    /// modifier happened to be last. Each group below is a moderate expression.
    var shellInteractions: some View {
        shellNotices
        // The keyboard never rearranges the shell. Keyboard avoidance applied
        // to the bar itself does not hold: the bottom-aligned overlay resolves
        // its position against the container's safe area, which still contains
        // the keyboard, so a site's own search field lifted the bar to sit
        // above the keyboard — the browser's controls parked mid-screen over
        // the page. Ignoring the keyboard here, at the root the inset enters
        // through, takes it out of the equation for the whole subtree: the bar
        // stays on its edge and is simply covered while the keyboard is up.
        // The two surfaces that do track the keyboard measure it themselves —
        // the search page ends at its top edge, and the find bar lifts above
        // it by the same measurement.
        .ignoresSafeArea(.keyboard)
        .animation(BrowserMotion.chrome(reduceMotion), value: omnibox.isEditing)
        .onAppear {
            wireOmnibox()
            syncAddressText()
            // The hardware-keyboard menu is built by the app; this is the one
            // handler it can call into.
            env.commands.register(owner: env.windowId) { command in
                handleBrowserCommand(command)
            }
            env.commands.setActive(owner: env.windowId, active: scenePhase == .active)
            // The one deferred destination that needs the environment: the
            // shelf captures the active tab's privacy mode and the current
            // private generation before it fetches a library.
            shell.onBookshelfRequested = { openBookshelf() }
            syncSurface()
            // The environment ends a private session from the app's background
            // hook as well as from this view. Taking the reader down here,
            // synchronously before the tabs close, is what makes the reader's
            // loader cancellation part of the shutdown order.
            env.onPrivateSessionWillEnd = {
                if novelSession?.isPrivateSession == true {
                    closeNovelSession()
                }
                if bookshelfIsPrivate {
                    shell.dismiss(kind: .bookshelf)
                }
                if env.currentPrivacyMode == .private {
                    shell.dismiss(kind: .addBookmarkChoice)
                }
            }
        }
        .onDisappear {
            env.commands.unregister(owner: env.windowId)
            env.onPrivateSessionWillEnd = nil
            shell.onBookshelfRequested = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillChangeFrameNotification)) { note in
            handleKeyboardFrameChange(note)
        }
    }

    /// The observers that follow the active document.
    var shellTabObservers: some View {
        shellInteractions
        .onChange(of: tabManager.activeTabId) { _, _ in
            handleActiveTabChanged()
        }
        .onChange(of: env.privateNovelSessionGeneration) { _, generation in
            handlePrivateNovelGeneration(generation)
        }
        .onChange(of: tabManager.sessionSaveError) { _, error in
            if let error { env.persistenceNotice = "标签会话保存失败：" + error }
        }
        .onChange(of: activeTab?.url) { _, _ in
            handleActiveTabUrlChanged()
        }
        .onChange(of: activeTab?.pendingUrl) { _, _ in
            syncAddressText()
        }
        // The surface is derived from the tab as well as stored; these two
        // observers keep the stored value honest for anything that animates on
        // it or asks it a question outside `body`.
        .onChange(of: activeTab?.isHome) { _, _ in
            syncSurface()
        }
        .onChange(of: activeTab?.loadState) { _, _ in
            syncSurface()
        }
    }

    /// The observers that follow appearance and scene state rather than the
    /// document.
    var shellAppearanceObservers: some View {
        shellTabObservers
        .onChange(of: omnibox.isEditing) { _, editing in
            // The iPad top bar yields to the search page, and an open tab
            // drawer must not sit over that page.
            if editing {
                withAnimation(BrowserMotion.jelly(reduceMotion)) {
                    showPadSidebar = false
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChanged(phase)
        }
        .onChange(of: edgeSwipeBackEnabled) { _, enabled in
            // A navigation can retire the step a tracked swipe was going to
            // take. Do not leave the arrow parked on screen.
            guard !enabled, !isSwipeBackCompleting else { return }
            isSwipeBackTracking = false
            swipeBackArmed = false
            withAnimation(BrowserMotion.settle(reduceMotion)) {
                swipeBackTranslation = 0
            }
        }
    }

    var shellRoot: some View {
        shellAppearanceObservers
            .overlay(alignment: .top) { searchPageLayer }
            // The search page has an opacity transition; without an animation
            // tied to the editing state it was inserted and removed in one
            // frame while the command bar below faded.
            .animation(BrowserMotion.chrome(reduceMotion), value: omnibox.isEditing)
    }

    // MARK: - Shell observers

    /// The keyboard's rise and fall. The card tracks it; the chrome ignores it.
    func handleKeyboardFrameChange(_ note: Notification) {
        let end = (note.userInfo?[UIApplication.keyboardFrameEndUserInfoKey] as? NSValue)?
            .cgRectValue ?? .zero
        let screenHeight = max(UIScreen.main.bounds.height, end.maxY)
        // Only a docked keyboard should resize the page. A floating iPad
        // keyboard is draggable: it sends a frame notification on every drag
        // frame, and treating each one as a new bottom inset made the search
        // page follow the keyboard and stutter. A floating panel covers only
        // itself; the page stays put underneath it.
        let occlusion: CGFloat
        if end.isEmpty {
            occlusion = 0
        } else if screenHeight - end.maxY < 40 {
            // Docked: the keyboard runs from its top edge to the bottom.
            occlusion = max(0, screenHeight - end.minY)
        } else {
            occlusion = 0
        }
        guard abs(occlusion - keyboardHeight) > 0.5 else { return }
        // No implicit animation here: this notification can arrive many times
        // while the keyboard is dragged, and animating every frame compounds
        // into the stall the report describes.
        keyboardHeight = occlusion
    }

    /// The shell state that belongs to the tab on screen, not to the window.
    func handleActiveTabChanged() {
        // A swipe belongs to the page it started on.
        isSwipeBackTracking = false
        swipeBackArmed = false
        if !isSwipeBackCompleting {
            swipeBackTranslation = 0
        }
        showFindBar = false
        findQuery = ""
        chromeHidden = false
        resetChromeDrag()
        scrollTracker.lastOffset = 0
        scrollTracker.accumulation = 0
        scrollTracker.upwardTravel = 0
        env.webCoordinator.clearFindInPage()
        omnibox.endEditing()
        env.webCoordinator.refreshNavigationAvailability()
        syncAddressText()
        syncSurface()
    }

    func handleActiveTabUrlChanged() {
        chromeHidden = false
        resetChromeDrag()
        scrollTracker.lastOffset = 0
        scrollTracker.accumulation = 0
        scrollTracker.upwardTravel = 0
        syncAddressText()
        syncSurface()
    }

    /// Yields the iPad sidebar's page and dismisses the overview before a
    /// background transition ends the private session whose tabs it shows.
    @MainActor
    func handleScenePhaseChanged(_ phase: ScenePhase) {
        env.commands.setActive(owner: env.windowId, active: phase == .active)
        guard phase == .background, showTabsOverview else { return }
        homePreview = nil
        homePreviewTabId = nil
        if !tabManager.privateTabs.isEmpty || tabManager.activeTab == nil {
            showTabsOverview = false
        }
    }
}
