//
//  VelaApp.swift
//  Vela
//
//  The application entry point.
//
//  The app owns one `AppServices` — everything that is the same in every
//  window — and one `BrowserWindowRoot` per scene. The root builds that
//  window's `AppEnvironment`, which is where the tab session lives. Before
//  this split, the environment was a property of the app and every Stage
//  Manager window shared one tab strip.
//
//  Three obligations hang off the scene phase: persist the window's session
//  when it leaves the foreground, run private-session cleanup when it is
//  backgrounded with private tabs open, and let queued downloads continue on
//  the background URLSession.
//

import SwiftUI
import WebKit

@main
struct VelaApp: App {
    /// The call iOS makes for mid-flight background downloads.
    @UIApplicationDelegateAdaptor(VelaAppDelegate.self) private var appDelegate

    /// Built once for the process and shared by every window.
    @State private var services: AppServices

    /// Boots the shared services with the app, not with the first window.
    ///
    /// A launch caused by a background `URLSession` may never show a window;
    /// if boot waited for `BrowserWindowRoot` to render, the download registry
    /// would have no reconnector and the system's completion handler would
    /// never be released. `AppEnvironment` still calls `bootOnce`, but it is
    /// idempotent and will already have run here.
    @MainActor
    init() {
        let services = AppServices()
        services.bootOnce()
        _services = State(initialValue: services)
    }

    var body: some Scene {
        WindowGroup {
            BrowserWindowRoot(services: services)
        }
        .commands {
            BrowserCommands(center: services.commands)
        }
    }
}

// MARK: - One window

/// The root of one browser window.
///
/// `@StateObject` is what gives each scene its own store, and the store's lazy
/// environment is what gives each scene its own `TabManager`. The initializer
/// is deliberately cheap: SwiftUI may build the view struct more than once for
/// the same scene, and the expensive half must not run until the scene actually
/// needs it.
private struct BrowserWindowRoot: View {
    @StateObject private var store: WindowEnvironmentStore
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init(services: AppServices) {
        _store = StateObject(wrappedValue: WindowEnvironmentStore(services: services))
    }

    private var environment: AppEnvironment { store.environment }

    var body: some View {
        windowSurface
            .onOpenURL { url in
                handleInboundUrl(url)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )) { _ in
                // A memory warning is the one signal iOS gives before it
                // terminates a backgrounded app. Every open window handles it:
                // the pressure is the process's, not one scene's.
                environment.tabManager.handleMemoryPressure()
            }
            .alert(
                "无法打开数据库",
                isPresented: Binding(
                    get: { environment.startupError != nil },
                    set: { _ in }
                )
            ) {
                Button("好") {}
            } message: {
                if let error = environment.startupError {
                    Text("浏览记录和书签将不会保存。\n\n\(error)")
                }
            }
            // Two preferences have a per-window side effect even though they
            // are changed from one window: 不保留标签页 decides whether every
            // window's session is written, and 无痕模式 decides what every
            // window's next tab is. Reacting here keeps the other windows in
            // step with the one that owns the settings screen.
            .onChange(of: environment.settings.preferences.tabsNotRetained) { _, notRetained in
                let retained = !(notRetained ?? false)
                environment.tabManager.persistsSession = retained
                if !retained {
                    try? environment.tabSessions.removeSession(windowId: environment.windowId)
                }
            }
            .onChange(of: environment.settings.preferences.privateBrowsingMode) { _, _ in
                environment.refreshPrivateBrowsingRouting()
            }
            .onChange(of: environment.settings.navigationDiagnostics) { _, _ in
                // Each window's log holds its own copy of the switches.
                environment.applyNavigationDiagnosticsSettings()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    environment.tabManager.persistSession()
                    // The vault does not stay open behind a backgrounded app:
                    // unlocking again is the whole point of the lock.
                    environment.passwords.lock()
                    // A backgrounded app that still holds private tabs is the
                    // case the cleanup exists for: the user has moved on, and
                    // the ephemeral store must not be the thing that survives.
                    if !environment.tabManager.privateTabs.isEmpty {
                        let env = environment
                        Task { await env.endPrivateSession() }
                    }
                    // Queued transfers start now so they ride the background
                    // session instead of waiting for a foreground the user may
                    // not return to before the file is wanted.
                    environment.downloads.continueQueuedInBackground()
                case .inactive:
                    environment.tabManager.persistSession()
                case .active:
                    break
                @unknown default:
                    break
                }
            }
    }

    /// The shell and the appearance it is injected with.
    ///
    /// Split off the modifier chain below for the same reason the shell splits
    /// its own presentations: one long chain is a type-checker budget, and the
    /// failure lands on an unrelated modifier at the far end.
    private var windowSurface: some View {
        BrowserShellView(environment: environment)
            .environment(environment)
            // The palette's accent is a dynamic colour, so it re-resolves
            // in both appearances; that is why the tint is read from the
            // palette rather than from a fixed constant.
            .tint(activePalette.accent)
            // The palette is injected here, once, rather than defaulted in
            // the environment: every chrome and list reads it, and a
            // selected 配色 has to reach all of them without a relaunch.
            .environment(\.browserPalette, activePalette)
            .environment(\.browserBackgroundStyle, environment.settings.backgroundStyle)
            // nil means "follow the system", which is the whole of the
            // 跟随系统 mode. Applied at the root so the sheet, the alert and
            // every `UIColor` dynamic provider resolve against it.
            .preferredColorScheme(environment.settings.appearanceMode.colorScheme)
    }

    /// The palette the user selected, or the shipped default when the stored
    /// id no longer resolves.
    private var activePalette: BrowserPalette {
        BrowserPalette.all.first { $0.id == environment.settings.preferences.themePaletteId }
            ?? BrowserPalette.default
    }

    /// Routes a URL the app was opened with.
    ///
    /// An `http(s)` URL opens in the active tab rather than a new one, which is
    /// what a user tapping a link in another app expects; a `vela://` URL is
    /// treated as a command.
    private func handleInboundUrl(_ url: URL) {
        // A custom-scheme URL is a command, not a destination.
        if url.scheme?.lowercased() == "vela" {
            switch url.host?.lowercased() {
            case "private":
                environment.tabManager.createTab(privacyMode: .private, openSource: .user)
            case "newtab":
                environment.tabManager.createTab(openSource: .user)
            default:
                break
            }
            return
        }

        guard url.scheme == "http" || url.scheme == "https" else { return }

        // Opening from another app is a fresh intent, so it gets a new tab
        // rather than replacing what the user was reading.
        environment.tabManager.openTab(
            url: url,
            openSource: .externalShare
        )
    }
}

/// Holds a scene's environment.
///
/// A class rather than a `@State` value because `@StateObject` gives SwiftUI a
/// per-scene identity to hang the object on. The environment is lazy so that
/// building the view struct — which SwiftUI does on every pass — does not
/// restore a session or build a web-view manager.
@MainActor
private final class WindowEnvironmentStore: ObservableObject {
    private let services: AppServices
    private var created: AppEnvironment?

    init(services: AppServices) {
        self.services = services
    }

    var environment: AppEnvironment {
        if let created { return created }
        let environment = AppEnvironment(
            services: services,
            windowId: services.allocateWindowId()
        )
        created = environment
        return environment
    }
}
