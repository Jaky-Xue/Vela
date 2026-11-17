import SwiftUI

/// Local foreground sessions only. No browsing URLs or private activity are stored.
enum BrowserActivity {
    static let key = "org.vela.browser.activity.days"

    static func record() {
        let defaults = UserDefaults.standard
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        let stamp = String(Int(today.timeIntervalSince1970))
        days[stamp] = min(100, (days[stamp] ?? 0) + 1)
        let cutoff = calendar.date(byAdding: .day, value: -90, to: today)!.timeIntervalSince1970
        days = days.filter { (Double($0.key) ?? 0) >= cutoff }
        defaults.set(days, forKey: key)
    }
}

struct BrowserActivityGrid: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var days: [String: Int] = [:]
    @State private var visible = false
    @State private var glowing = false
    private var animates: Bool { visible && !reduceMotion && scenePhase == .active }
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近 12 周")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { day in
                            let date = calendar.date(byAdding: .day, value: week * 7 + day - 83,
                                                     to: calendar.startOfDay(for: Date()))!
                            let count = days[String(Int(date.timeIntervalSince1970))] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(count == 0 ? palette.secondaryText.opacity(0.12) : palette.accent.opacity(min(1, 0.35 + Double(count) * 0.13)))
                                .frame(height: 9)
                                .opacity(count > 0 && glowing ? 0.65 : 1)
                                .animation(animates ? .easeInOut(duration: 3.5).repeatForever(autoreverses: true).delay(Double((week + day) % 5) * 0.3) : nil, value: glowing)
                                .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted))，活跃 \(count) 次")
                        }
                    }
                }
            }
            Text("颜色越深，打开浏览器的次数越多。仅保存在本机，从此版本开始记录。")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.vertical, 4)
        .onAppear {
            visible = true
            days = UserDefaults.standard.dictionary(forKey: BrowserActivity.key) as? [String: Int] ?? [:]
        }
        .onDisappear { visible = false; glowing = false }
        .task(id: animates) {
            glowing = false
            guard animates else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            glowing = true
        }
    }
}
