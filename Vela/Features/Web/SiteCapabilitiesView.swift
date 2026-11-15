import SwiftUI

/// Page-specific controls live behind the address badge, outside the menu grid.
struct SiteCapabilitiesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var tab: BrowserTabState
    private var url: URL? { URL(string: tab.url) }
    private var host: String { url?.host ?? "" }
    private var scripts: [InstalledUserScriptState] {
        guard tab.privacyMode != .private, let url else { return [] }
        return env.userScripts.scripts.filter { $0.enabled && (UserScriptMatcher.matches($0, url: url) || env.webCoordinator.hasScriptFrame(id: $0.id, tabId: tab.id)) }
    }
    var body: some View {
        List {
            Section {
                Label(host, systemImage: url?.scheme == "https" ? "lock" : "globe")
                if tab.privacyMode == .private { Label("无痕会话", systemImage: "eyeglasses") }
            }
            Section("页面保护") {
                LabeledContent("过滤状态", value: !env.settings.contentBlocker.enabled ? "已关闭" : env.settings.contentBlocker.isExcepted(host: host) ? "站点放行" : env.services.contentBlocker.isReady ? "已就绪" : "准备中")
                NavigationLink("过滤管理") { ContentBlockerSettingsView() }
                Toggle("暂停隐藏", isOn: Binding(get: { (env.settings.manualElementHide.pausedHosts ?? []).contains(host) }, set: { paused in
                    env.settings.updateManualElementHide {
                        var hosts = Set($0.pausedHosts ?? [])
                        if paused { hosts.insert(host) } else { hosts.remove(host) }
                        $0.pausedHosts = Array(hosts).sorted()
                    }
                    env.webCoordinator.applyManualElementHides(to: env.tabManager.webView(for: tab.id), host: host)
                }))
                NavigationLink("隐藏元素") { ElementHideSettingsView() }
                Toggle("站点放行", isOn: Binding(get: { env.settings.contentBlocker.whitelistedHosts.contains(host) }, set: { value in
                    env.settings.updateContentBlocker {
                        $0.whitelistedHosts.removeAll { $0 == host }
                        if value { $0.whitelistedHosts.append(host) }
                    }
                    env.applyContentBlockerSettings()
                }))
            }
            Section("页面脚本") {
                if tab.privacyMode == .private { Text("无痕停用脚本") }
                else if !env.settings.preferences.userScriptsEnabled { Text("脚本已关闭") }
                else if scripts.isEmpty { Text("暂无匹配脚本") }
                ForEach(scripts) { script in
                    if !script.runAt.injectsOnLoad {
                        Button { env.webCoordinator.runMenuScript(id: script.id, tabId: tab.id); dismiss() } label: {
                            Label(script.displayName, systemImage: "play.circle")
                        }
                    } else { LabeledContent(script.displayName, value: env.webCoordinator.hasScriptFrame(id: script.id, tabId: tab.id) ? "已匹配" : "等待刷新") }
                }
                ForEach(env.overlays.userScriptMenuCommands.filter { $0.tabId == tab.id }) { command in
                    Button { env.webCoordinator.runUserScriptMenuCommand(command); dismiss() } label: {
                        VStack(alignment: .leading) { Text(command.name); Text(command.scriptName).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ForEach(env.overlays.userScriptRuntimeErrors.filter { $0.key.hasPrefix(tab.id + "|") }.sorted { $0.key < $1.key }, id: \.key) { item in
                    DisclosureGroup("运行异常") { Text(item.value).font(.footnote) }
                }
            }
            Section {
                Button("刷新页面", systemImage: "arrow.clockwise") { _ = env.tabManager.reload(tab: tab); dismiss() }
            }
        }.settingsList().navigationTitle("站点详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
