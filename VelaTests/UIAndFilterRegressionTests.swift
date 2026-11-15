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

    func testRuleOptionsAndInvalidScriptPatterns() {
        let exclusion = AdBlockRuleCompiler.compile(filterList: "||ad.test^$~image")
        XCTAssertFalse(exclusion.rules.first?.trigger.resourceType?.contains("image") ?? true)
        let caseSensitive = AdBlockRuleCompiler.compile(filterList: "||ad.test^$match-case")
        XCTAssertEqual(caseSensitive.rules.first?.trigger.urlFilterIsCaseSensitive, true)
        let unknown = AdBlockRuleCompiler.compile(filterList: "||ad.test^$unknown-option")
        XCTAssertTrue(unknown.rules.isEmpty)
        XCTAssertEqual(unknown.unsupportedRuleCount, 1)
        XCTAssertNil(UserScriptMatcher.ruleError("https://*.example.com/*", isMatch: true))
        XCTAssertNotNil(UserScriptMatcher.ruleError("bad pattern", isMatch: true))
        XCTAssertNotNil(UserScriptMatcher.ruleError("/[broken/", isMatch: false))
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
        let database = try SQLiteDatabase(path: ":memory:")
        for statement in BrowserSchema.creationStatements { try database.execute(statement) }
        let repo = UserScriptRepository(database: database)
        let settings = SettingsService(defaults: defaults)
        let service = UserScriptService(repository: repo, settings: settings)
        let source = "// ==UserScript==\n// @name Local\n// @match https://original.test/*\n// @grant none\n// ==/UserScript==\nwindow.ran = true;"
        guard case let .success(outcome) = await service.install(text: source, source: .paste, sourceUrl: "") else { return XCTFail("install failed") }
        try service.updateRules(matches: ["https://local.test/*"], includes: [], for: outcome.script)
        let local = try XCTUnwrap(service.script(id: outcome.script.id))
        let exported = UserScriptParser.parse(service.exportSource(for: local, includingLocalRules: true))
        XCTAssertEqual(exported.candidate?.matches, ["https://local.test/*"])
        let original = UserScriptParser.parse(service.exportSource(for: local, includingLocalRules: false))
        XCTAssertEqual(original.candidate?.matches, ["https://original.test/*"])
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

    func testRenderSettingsLayoutsAndUpdateReview() async throws {
        let env = AppEnvironment(services: AppServices(), windowId: "SettingsQA-" + UUID().uuidString)
        let namespace = UUID().uuidString
        let first = "// ==UserScript==\n// @name 更新预览\n// @namespace " + namespace + "\n// @version 1\n// @match https://example.test/*\n// @grant none\n// ==/UserScript==\nwindow.qa = 1;"
        guard case let .success(outcome) = await env.userScripts.install(text: first, source: .paste, sourceUrl: "") else { return XCTFail("preview fixture failed") }
        defer { env.userScripts.delete(id: outcome.script.id) }
        let current = try XCTUnwrap(env.userScripts.script(id: outcome.script.id))
        let second = first.replacingOccurrences(of: "@version 1", with: "@version 2")
            .replacingOccurrences(of: "@grant none", with: "@grant GM_xmlhttpRequest\n// @connect api.example.test")
        let candidate = try XCTUnwrap(UserScriptParser.parse(second).candidate)
        _ = try await env.userScripts.stageUpdate(candidate, for: current)
        let screens: [(String, AnyView)] = [
            ("settings-root", AnyView(NavigationStack { SettingsView() })),
            ("settings-filters", AnyView(NavigationStack { FilterSourcesSettingsView() })),
            ("settings-input", AnyView(NavigationStack { List {
                Section { SettingsInputRow(title: "订阅名称", prompt: "常用过滤", text: .constant(""))
                          SettingsInputRow(title: "订阅地址", prompt: "https://example.com/filter.txt", text: .constant(""), keyboard: .URL) }
            }.settingsList().navigationTitle("添加订阅").navigationBarTitleDisplayMode(.inline) })),
            ("update-review", AnyView(PendingScriptUpdateView(scriptID: current.id)))
        ]
        for (name, screen) in screens {
            let content = screen.environment(env).environment(\.browserPalette, BrowserPalette.default).environment(\.colorScheme, .light)
            let controller = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 780))
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = controller; window.makeKeyAndVisible()
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 780)
            controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 350_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment); window.isHidden = true
        }
    }

    func testRenderBrightTabOverviewAndPrivateHome() async throws {
        let server = try LocalHTTPServer(routes: [
            "/one": .html("<title>阅读 · 测试页面</title><body style='background:#f7faff;color:#20314b;font:24px system-ui;padding:24px'><h1>阅读时刻</h1><p>保持专注，轻松浏览。</p>"),
            "/two": .html("<title>灵感 · 测试页面</title><body style='background:#fff8ef;color:#4e342e;font:24px system-ui;padding:24px'><h1>灵感笔记</h1><p>让好想法留下来。</p>"),
            "/three": .html("<title>探索 · 测试页面</title><body style='background:#f2fbf5;color:#244235;font:24px system-ui;padding:24px'><h1>发现新意</h1><p>开启下一段旅程。</p>")
        ])
        let base = try await server.start(); defer { server.stop() }
        let env = AppEnvironment(services:AppServices(),windowId:"OverviewQA-"+UUID().uuidString)
        let window = UIWindow(frame:CGRect(x:0,y:0,width:375,height:780))
        window.windowScene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first
        window.frame=CGRect(x:0,y:0,width:375,height:780); window.overrideUserInterfaceStyle = .light
        window.rootViewController=UIViewController(); window.makeKeyAndVisible()
        for path in ["one","two","three"] {
            let tab=env.tabManager.openTab(url:base.appendingPathComponent(path),privacyMode:.regular)
            let web=try XCTUnwrap(env.tabManager.webView(for:tab.id))
            web.frame=window.bounds;window.rootViewController!.view.addSubview(web)
            try await Task.sleep(nanoseconds:700_000_000)
            let config=WKSnapshotConfiguration();config.snapshotWidth=375
            let image: UIImage? = await withCheckedContinuation { c in web.takeSnapshot(with:config){image,_ in c.resume(returning:image)} }
            if let image { env.tabManager.storePreview(image,for:tab.id) }
            web.removeFromSuperview()
        }
        let screens:[(String,AnyView,Double,ColorScheme)] = [
            ("tabs-overview-light",AnyView(TabsOverviewView(onClose:{})),375,.light),
            ("tabs-overview-dark",AnyView(TabsOverviewView(onClose:{})),375,.dark),
            ("tabs-overview-pad",AnyView(TabsOverviewView(onClose:{})),744,.light),
            ("private-home",AnyView(NewTabHomeView(isPrivate:true,onNavigate:{_ in})),375,.light)
        ]
        for (name,view,width,scheme) in screens {
            let content=view.environment(env).environment(\.browserPalette,BrowserPalette.default).environment(\.colorScheme,scheme)
            let controller=UIHostingController(rootView:content)
            window.overrideUserInterfaceStyle=scheme == .dark ? .dark : .light
            window.rootViewController=controller;window.frame=CGRect(x:0,y:0,width:width,height:780)
            controller.view.frame=window.bounds;controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds:700_000_000)
            let format=UIGraphicsImageRendererFormat();format.scale=1
            let image=UIGraphicsImageRenderer(size:window.bounds.size,format:format).image{_ in controller.view.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
            let attachment=XCTAttachment(image:image);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
        }
        window.isHidden=true
        for tab in Array(env.tabManager.tabs) { env.tabManager.closeTab(id:tab.id) }
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
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = controller
            window.makeKeyAndVisible()
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
