import XCTest
import SwiftUI
import WebKit
@testable import Vela

@MainActor
final class UIAndFilterRegressionTests: XCTestCase {
    func testFavoriteSwapSurvivesReloadAndPreservesTileSettings() throws {
        let suite = "FavoriteSwap-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HomeFavoritesService(defaults: defaults)
        let a = try XCTUnwrap(service.add(url: "https://a.test", title: "A", showsTitle: false))
        let b = try XCTUnwrap(service.add(url: "https://b.test", title: "B", showsTitle: true))
        let c = try XCTUnwrap(service.add(url: "https://c.test", title: "C"))
        XCTAssertTrue(service.swap(a.id, with: c.id))
        let restored = HomeFavoritesService(defaults: defaults)
        XCTAssertEqual(restored.favorites.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(restored.favorites.last?.showsTitle, false)
        XCTAssertEqual(restored.favorites.last?.url, a.url)
        XCTAssertFalse(restored.swap(a.id, with: "missing"))
    }

    func testMenuDragKeepsHiddenAndShortcutTiles() {
        let shortcut = MenuShortcut(title: "Work", url: "https://work.test", symbolName: "star")
        let original = MenuLayout().adding(shortcut).settingVisible(false, id: VelaMenuAction.share.id)
        let moved = original.movingTile(shortcut.id, before: VelaMenuAction.addBookmark.id)
        XCTAssertEqual(moved.visibleTiles.first?.id, shortcut.id)
        XCTAssertEqual(moved.hidden, original.hidden)
        XCTAssertEqual(moved.shortcuts, original.shortcuts)
        XCTAssertEqual(Set(moved.order).count, moved.order.count)
        XCTAssertEqual(moved.movingTile("foreign", before: shortcut.id), moved)
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ x: CGFloat) -> Double { let v = Double(x); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    private func contrast(_ a: Color, _ b: Color) -> Double {
        let x = luminance(UIColor(a)), y = luminance(UIColor(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    func testNewPalettesAndIconColorsHaveReadableContrast() {
        XCTAssertEqual(Set(BrowserPalette.all.map(\.id)).count, BrowserPalette.all.count)
        XCTAssertGreaterThanOrEqual(BrowserPalette.all.count, 10)
        for palette in BrowserPalette.all where ["iris", "jade", "amber", "rose", "cobalt", "slate"].contains(palette.id) {
            for tokens in [palette.light, palette.dark] {
                XCTAssertGreaterThanOrEqual(contrast(tokens.primaryText, tokens.surface), 4.5, palette.id)
                XCTAssertGreaterThanOrEqual(contrast(tokens.secondaryText, tokens.surface), 4.5, palette.id)
                XCTAssertGreaterThanOrEqual(contrast(tokens.onAccent, tokens.accent), 4.5, palette.id)
            }
        }
        for hex in IconColorStyle.hexColors { XCTAssertGreaterThanOrEqual(contrast(.white, Color(velaHex: hex)), 4.5) }
    }

    func testInvalidFilterInputsAreRejectedWithoutNetwork() throws {
        for text in ["", "<html><body>error</body></html>", "!#include https://bad.test/list", String(repeating: "x", count: 2_000_001)] {
            XCTAssertThrowsError(try FilterValidation.validate(text))
        }
        XCTAssertNoThrow(try FilterValidation.validate("||tracker.test^\n##.ad-banner"))
    }

    func testInvalidCustomRuleDoesNotReplaceActiveSnapshot() async throws {
        let suite = "Filters-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsService(defaults: defaults)
        let blocker = ContentBlocker(settings: settings)
        let saved = await blocker.saveCustomRules("##.test-ad")
        XCTAssertTrue(saved)
        let snapshot = settings.contentBlocker.activeSnapshot
        let count = blocker.ruleCount
        let rejected = await blocker.saveCustomRules("##[")
        XCTAssertFalse(rejected)
        XCTAssertEqual(settings.contentBlocker.activeSnapshot, snapshot)
        XCTAssertEqual(settings.contentBlocker.customRules, "##.test-ad")
        XCTAssertEqual(blocker.ruleCount, count)
        XCTAssertTrue(blocker.isReady)
    }

    func testLocalScriptRulesAndDraftDoNotOverwriteActiveSource() async throws {
        let suite = "ScriptOverrides-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = UserScriptRepository(database: try SQLiteDatabase(path: ":memory:"))
        let settings = SettingsService(defaults: defaults)
        let service = UserScriptService(repository: repo, settings: settings)
        let source = "// ==UserScript==\n// @name Local\n// @match https://original.test/*\n// @grant none\n// ==/UserScript==\nwindow.ran = true;"
        guard case let .success(outcome) = await service.install(text: source, source: .paste, sourceUrl: "") else { return XCTFail("install failed") }
        try service.updateRules(matches: ["https://local.test/*"], includes: [], for: outcome.script)
        let local = try XCTUnwrap(service.script(id: outcome.script.id))
        try service.saveRawSource("unfinished {", for: local)
        XCTAssertEqual(service.script(id: local.id)?.source, "window.ran = true;")
        XCTAssertEqual(service.draftSource(for: local), "unfinished {")
        let result = await service.saveEditedSource(service.editableSource(for: local), for: local)
        guard case .saved = result else { return XCTFail("valid source save failed") }
        XCTAssertEqual(service.script(id: local.id)?.matches, ["https://local.test/*"])
        XCTAssertNil(service.draftSource(for: local))
        let restored = UserScriptService(repository: repo, settings: SettingsService(defaults: defaults))
        XCTAssertEqual(restored.script(id: local.id)?.matches, ["https://local.test/*"])
    }

    func testRenderMenuAndPalettePreviews() async throws {
        let env = AppEnvironment(services: AppServices(), windowId: "UIQA-" + UUID().uuidString)
        for (name, width, scheme) in [("menu-phone-light", 375.0, ColorScheme.light), ("menu-phone-dark", 375.0, .dark), ("menu-pad", 744.0, .light)] {
            let menu = MenuPanelView(canActOnPage: true, isPrivateMode: false, isPrivateBrowsingOn: false,
                pageTitle: "Vela · 当前页面", onPerform: { _ in }, onOpenShortcut: { _ in })
                .environment(env).environment(\.browserPalette, BrowserPalette.all.first { $0.id == "iris" }!)
                .environment(\.colorScheme, scheme).frame(width: width, height: 670)
            let controller = UIHostingController(rootView: menu)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 670))
            window.rootViewController = controller; window.isHidden = false
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }
}
