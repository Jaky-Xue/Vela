import SwiftUI

struct ScriptWorldSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    var scriptID: String
    @State private var consent = false
    var body: some View {
        List {
            if let script = env.userScripts.script(id: scriptID) {
                Section {
                    Toggle("页面模式", isOn: Binding(get: { env.userScripts.usesPageWorld(script) }, set: { value in
                        if value { consent = true } else { env.userScripts.setPageWorld(false, for: script) }
                    }))
                } footer: { Text("刷新后生效。更新脚本后需重新确认。") }
                Section {
                    Label("可访问页面变量", systemImage: "curlybraces")
                    Label("无原生特权", systemImage: "lock.shield")
                }
            }
        }.settingsList().navigationTitle("执行环境")
            .alert("允许访问页面变量？", isPresented: $consent) {
                Button("取消", role: .cancel) { }
                Button("允许") { if let script = env.userScripts.script(id: scriptID) { env.userScripts.setPageWorld(true, for: script) } }
            } message: { Text("脚本将与网页共享变量，可使用 unsafeWindow。页面模式不开放原生存储、Cookie、跨域请求和下载权限。") }
    }
}
