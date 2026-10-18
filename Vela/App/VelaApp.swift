//
//  VelaApp.swift
//  Vela
//
//  The application entry point.
//
//  SwiftUI drives the lifecycle through `ScenePhase`, and three obligations
//  hang off it: persist the tab session when the app leaves the foreground, run
//  the private-session cleanup when it is backgrounded with private tabs open,
//  and hand an inbound URL to the browser instead of opening a second window.
//

import SwiftUI
import WebKit

@main
struct VelaApp: App {
    @State private var environment = AppEnvironment()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserShellView(environment: environment)
                .environment(environment)
                // The palette's accent is a dynamic colour, so it re-resolves
                // in both appearances; that is why the tint is read from the
                // palette rather than from a fixed constant.
                .tint(activePalette.accent)
                // nil means "follow the system", which is the whole of the
                // 跟随系统 mode. Applied at the root so the sheet, the alert and
                // every `UIColor` dynamic provider resolve against it.
                .preferredColorScheme(environment.settings.appearanceMode.colorScheme)
                .onOpenURL { url in
                    handleInboundUrl(url)
                }
                .task {
                    // A memory warning is the one signal iOS gives before it
                    // terminates a backgrounded app, and a browser holding six
                    // live web views is the app most likely to get it. Ported
                    // from `BrowserSystemMemoryPressureSignal`.
                    NotificationCenter.default.addObserver(
                        forName: UIApplication.didReceiveMemoryWarningNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        Task { @MainActor in
                            environment.tabManager.handleMemoryPressure()
                        }
                    }
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
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                environment.tabManager.persistSession()
                // A backgrounded app that still holds private tabs is the case
                // the cleanup exists for: the user has moved on, and the
                // ephemeral store must not be the thing that survives.
                if !environment.tabManager.privateTabs.isEmpty {
                    Task { await environment.endPrivateSession() }
                }
            case .inactive:
                environment.tabManager.persistSession()
            case .active:
                break
            @unknown default:
                break
            }
        }
    }

    /// The palette the user selected, or the shipped default when the stored id
    /// no longer resolves.
    private var activePalette: BrowserPalette {
        BrowserPalette.all.first { $0.id == environment.settings.preferences.themePaletteId }
            ?? BrowserPalette.default
    }

    /// Routes a URL the app was opened with.
    ///
    /// `BrowserAppUrlOpenCoordinator`. An `http(s)` URL opens in the active tab
    /// rather than a new one, which is what a user tapping a link in another app
    /// expects; a `vela://` URL is treated as a command.
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
