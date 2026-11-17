import XCTest
import SwiftUI
@testable import Vela

@MainActor
final class ThemeMaterialRegressionTests: XCTestCase {
    func testRenderWelcomePagesOnPhoneAndPad() async throws {
        let window = UIWindow()
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        defer { window.isHidden = true }
        let layouts: [(String, CGSize, ColorScheme)] = [
            ("phone", CGSize(width: 390, height: 844), .light),
            ("landscape", CGSize(width: 844, height: 390), .light),
            ("pad-dark", CGSize(width: 768, height: 1024), .dark)
        ]
        for (name, size, scheme) in layouts {
            for step in 0..<5 {
                let content = BrowserWelcomeView(initialStep: step, onFinish: {})
                    .environment(\.browserPalette, BrowserPalette.default)
                    .transaction { $0.disablesAnimations = true }
                    .environment(\.colorScheme, scheme)
                let controller = UIHostingController(rootView: content)
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = controller
                window.frame = CGRect(origin: .zero, size: size)
                window.makeKeyAndVisible()
                controller.view.frame = window.bounds
                controller.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "welcome-\(name)-step-\(step + 1)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testLegacyPaletteConstructionKeepsDefaultVisualStyle() throws {
        let original = BrowserPalette.default
        let legacy = BrowserPalette(id: "legacy", displayName: "旧配色", light: original.light, dark: original.dark)
        XCTAssertEqual(legacy.visualStyle, .standard)
        XCTAssertEqual(BrowserBackgroundStyle.resolve(nil), .solid)
        XCTAssertEqual(Set(BrowserPalette.all.map(\.id)), Set(["default", "morandi", "ocean", "crimson", "iris", "jade", "amber", "rose", "cobalt", "slate"]))
    }

    func testPaletteSelectionDoesNotReplaceChosenBackgroundOrPhoto() throws {
        let suite = "ThemeChoice-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsService(defaults: defaults)
        settings.backgroundStyle = .nightSky
        settings.update { $0.backgroundImageStamp = 123 }
        for palette in BrowserPalette.all {
            settings.update { $0.themePaletteId = palette.id }
            XCTAssertEqual(settings.backgroundStyle, .nightSky)
            XCTAssertEqual(settings.preferences.backgroundImageStamp, 123)
        }
    }

    func testEveryThemeHasOpaqueAccessibilityFallback() {
        for palette in BrowserPalette.all {
            XCTAssertEqual(palette.visualStyle.cardOpacity(reduceTransparency: true), 1)
            XCTAssertEqual(palette.visualStyle.rowOpacity(reduceTransparency: true), 1)
        }
    }

    func testOpaqueSurfacePreferenceCannotDisableSystemAccessibility() {
        var environment = EnvironmentValues()
        environment.browserOpaqueSurfaces = true
        XCTAssertTrue(environment.browserReduceTransparency)
        environment.browserOpaqueSurfaces = false
        XCTAssertEqual(environment.browserReduceTransparency, environment.accessibilityReduceTransparency)
    }

    func testRenderThemeCharacterAndTransparentChrome() async throws {
        let env = AppEnvironment(services: AppServices(), windowId: "ThemeQA-" + UUID().uuidString)
        let model = OmniboxViewModel(settings: env.settings, history: env.history,
                                    bookmarks: env.bookmarks, searchHistory: env.searchHistory,
                                    tabManager: env.tabManager)
        model.currentPageUrl = "https://vela.example"
        model.text = "vela.example"
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 640))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        defer { window.isHidden = true }
        for id in ["default", "jade", "amber"] {
            let palette = try XCTUnwrap(BrowserPalette.all.first { $0.id == id })
            for scheme in [ColorScheme.light, .dark] {
                for reduced in [false, true] {
                    let content = ThemeCharacterFixture(model: model)
                        .environment(\.browserPalette, palette)
                        .environment(\.browserBackgroundStyle, palette.visualStyle.recommendedBackground)
                        .environment(\.colorScheme, scheme)
                        .environment(\.browserOpaqueSurfaces, reduced)
                    let controller = UIHostingController(rootView: content)
                    window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                    window.rootViewController = controller
                    window.makeKeyAndVisible()
                    window.frame = CGRect(x: 0, y: 0, width: 375, height: 640)
                    controller.view.frame = window.bounds
                    controller.view.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 350_000_000)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                        controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "theme-\(id)-\(scheme == .dark ? "dark" : "light")-\(reduced ? "opaque" : "glass")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        let jade = try XCTUnwrap(BrowserPalette.all.first { $0.id == "jade" })
        let largeScreens: [(String, AnyView)] = [
            ("theme-settings-large", AnyView(NavigationStack { SettingsView() }.environment(env))),
            ("theme-menu-large", AnyView(MenuPanelView(settings: env.settings, canActOnPage: true,
                isPrivateMode: false, isPrivateBrowsingOn: false, pageTitle: "菜单",
                onPerform: { _ in }, onOpenShortcut: { _ in })))
        ]
        for (name, view) in largeScreens {
            let content = view.environment(\.browserPalette, jade)
                .environment(\.browserBackgroundStyle, BrowserBackgroundStyle.forest)
                .environment(\.dynamicTypeSize, DynamicTypeSize.accessibility3)
                .environment(\.browserOpaqueSurfaces, true)
            let controller = UIHostingController(rootView: content)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = controller
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 350_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }

    }
}

private struct ThemeCharacterFixture: View {
    var model: OmniboxViewModel
    @Environment(\.browserPalette) private var palette

    var body: some View {
        ZStack {
            AmbientBackgroundView()
            VStack(alignment: .leading, spacing: 20) {
                Text(palette.displayName).font(.largeTitle.bold())
                Text("发现新意").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 12) {
                    Label("阅读清单", systemImage: "bookmark")
                        .symbolVariant(palette.visualStyle.icons == .filled ? .fill : .none)
                        .font(.headline)
                    Text("留一点空间，继续探索。")
                        .font(.body).foregroundStyle(palette.secondaryText)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .browserCard()
                BrowserActivityGrid()
                    .padding(12)
                    .browserCard()
                Spacer()
            }
            .padding(24).padding(.top, 52).padding(.bottom, 140)

            // Broad colors make actual background transmission visible beneath the field.
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    LinearGradient(colors: [Color(red: 0.93, green: 0.48, blue: 0.43),
                                            Color(red: 0.32, green: 0.64, blue: 0.95),
                                            Color(red: 0.32, green: 0.78, blue: 0.61)],
                                   startPoint: .leading, endPoint: .trailing)
                    OmniboxView(viewModel: model, isLoading: false, progress: 0,
                                placeholder: "搜索或输入网址", onReload: {}, onStop: {})
                        .padding(.horizontal, 20)
                }.frame(height: 140)
            }
        }
        .foregroundStyle(palette.primaryText)
        .ignoresSafeArea()
    }
}
