import SwiftUI

/// Local foreground sessions only. No browsing URLs or private activity are stored.
enum BrowserActivity {
    static let key = "org.vela.browser.activity.days"

    /// Posted after a day's count changes, so a grid on screen can redraw the
    /// cell that moved instead of waiting for the next appearance.
    static let recordedNotification = Notification.Name("org.vela.browser.activity.recorded")

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
        NotificationCenter.default.post(name: recordedNotification, object: nil)
    }
}

struct BrowserActivityGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var days: [String: Int] = [:]
    @State private var visible = false
    @State private var glowing = false
    private var animates: Bool { visible && !reduceMotion && scenePhase == .active }
    private let calendar = Calendar.current

    private var blue: Color {
        colorScheme == .dark ? Color(red: 0.55, green: 0.69, blue: 1) : Color(red: 0.24, green: 0.46, blue: 0.85)
    }

    private func level(_ count: Int) -> Int {
        switch count {
        case ...0: return 0
        case 1...2: return 1
        case 3...5: return 2
        case 6...9: return 3
        default: return 4
        }
    }

    private func color(_ level: Int) -> Color {
        if level == 0 {
            return colorScheme == .dark
                ? Color(red: 0.14, green: 0.18, blue: 0.23)
                : Color(red: 0.90, green: 0.93, blue: 0.97)
        }
        return blue.opacity([0, 0.28, 0.48, 0.72, 1][level])
    }

    /// The heat map is a grid of rounded squares, the way every contribution
    /// graph is read: a square says "one day, one cell", and a rectangle lying
    /// on its side reads as a bar chart instead. The side follows the row's
    /// width so the grid fills it — a capped grid left grown-up columns with
    /// empty margins on both sides.
    private static let spacing: CGFloat = 5
    private static let columns = 12
    private static let rows = 7
    private static let minimumSide: CGFloat = 10

    @State private var measuredWidth: CGFloat = 0
    @State private var hasLoaded = false

    private var side: CGFloat {
        let fit = (measuredWidth - Self.spacing * CGFloat(Self.columns - 1))
            / CGFloat(Self.columns)
        guard measuredWidth > 0 else { return Self.minimumSide * 2 }
        return max(Self.minimumSide, fit)
    }

    private var gridHeight: CGFloat {
        side * CGFloat(Self.rows) + Self.spacing * CGFloat(Self.rows - 1)
    }

    var body: some View {
        let cellSide = side
        let radius = max(3, cellSide * 0.22)
        HStack(spacing: Self.spacing) {
            ForEach(0..<Self.columns, id: \.self) { week in
                VStack(spacing: Self.spacing) {
                    ForEach(0..<Self.rows, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day - 83,
                                                 to: calendar.startOfDay(for: Date()))!
                        let count = days[String(Int(date.timeIntervalSince1970))] ?? 0
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(color(level(count)))
                            .frame(width: cellSide, height: cellSide)
                            .opacity(count > 0 && glowing ? 0.82 : 1)
                            .animation(animates ? .easeInOut(duration: 4).repeatForever(autoreverses: true).delay(Double((week + day) % 5) * 0.35) : nil, value: glowing)
                            .overlay {
                                if week == 11 && day == 6 {
                                    RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                                        .strokeBorder(blue.opacity(0.9), lineWidth: 1.5)
                                        .padding(-2.5)
                                }
                            }
                            .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted))，活跃 \(count) 次")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: gridHeight)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ActivityGridWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(ActivityGridWidthKey.self) { measuredWidth = $0 }
        // A sign-in records a day. The cell moves from its empty tone towards
        // the blue over the animation, so the tap is answered where it
        // happened rather than only after the next visit to this screen.
        .onReceive(NotificationCenter.default.publisher(for: BrowserActivity.recordedNotification)) { _ in
            let updated = UserDefaults.standard.dictionary(forKey: BrowserActivity.key) as? [String: Int] ?? [:]
            withAnimation(.easeInOut(duration: 0.9)) {
                days = updated
            }
        }
        .onAppear {
            let loaded = UserDefaults.standard.dictionary(forKey: BrowserActivity.key) as? [String: Int] ?? [:]
            if hasLoaded {
                // Back from a sign-in window: the day gained a level while
                // this screen was behind it, and the cell should be seen
                // arriving rather than appear already bright.
                withAnimation(.easeInOut(duration: 0.9)) { days = loaded }
            } else {
                days = loaded
                hasLoaded = true
            }
            visible = true
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

private struct ActivityGridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
