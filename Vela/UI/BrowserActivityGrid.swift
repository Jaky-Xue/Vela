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
        // Long enough to fill the widest grid the app draws — a wide iPad
        // column shows twenty-six weeks — so the left of the graph is history
        // rather than cells that could never have data.
        let cutoff = calendar.date(byAdding: .day, value: -190, to: today)!.timeIntervalSince1970
        days = days.filter { (Double($0.key) ?? 0) >= cutoff }
        defaults.set(days, forKey: key)
        NotificationCenter.default.post(name: recordedNotification, object: nil)
    }
}

/// The activity heat map, as a grid of rounded squares.
///
/// The columns are chosen from the row's width, not fixed: the row has to be
/// filled edge to edge without the cells turning into wide bars, and a wide
/// settings column can hold many more days than a phone. Seven rows stay —
/// one per weekday — so a column still reads as a week.
struct BrowserActivityGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var days: [String: Int] = [:]
    @State private var visible = false
    @State private var glowing = false
    @State private var measuredWidth: CGFloat = 0
    @State private var hasLoaded = false
    private var animates: Bool { visible && !reduceMotion && scenePhase == .active }
    private let calendar = Calendar.current

    /// The square the columns are sized around. Small enough that a phone fits
    /// a fortnight, large enough to stay legible.
    private static let spacing: CGFloat = 4
    private static let rows = 7
    private static let targetSide: CGFloat = 18
    private static let maximumColumns = 26
    private static let minimumColumns = 8

    private var columns: Int {
        guard measuredWidth > 0 else { return 12 }
        let fit = Int((measuredWidth + Self.spacing) / (Self.targetSide + Self.spacing))
        return min(Self.maximumColumns, max(Self.minimumColumns, fit))
    }

    private var side: CGFloat {
        guard measuredWidth > 0 else { return Self.targetSide }
        let used = measuredWidth - Self.spacing * CGFloat(columns - 1)
        return max(6, used / CGFloat(columns))
    }

    private var cornerRadius: CGFloat {
        max(3, side * 0.22)
    }

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

    var body: some View {
        let today = calendar.startOfDay(for: Date())
        let cellSide = side
        let radius = cornerRadius
        let columnCount = columns
        HStack(spacing: Self.spacing) {
            ForEach(0..<columnCount, id: \.self) { week in
                VStack(spacing: Self.spacing) {
                    ForEach(0..<Self.rows, id: \.self) { day in
                        let offset = week * 7 + day - (columnCount * 7 - 1)
                        let date = calendar.date(byAdding: .day, value: offset, to: today)!
                        let count = days[String(Int(date.timeIntervalSince1970))] ?? 0
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(color(level(count)))
                            .frame(width: cellSide, height: cellSide)
                            .opacity(count > 0 && glowing ? 0.82 : 1)
                            .animation(animates ? .easeInOut(duration: 4).repeatForever(autoreverses: true).delay(Double((week + day) % 5) * 0.35) : nil, value: glowing)
                            .overlay {
                                if week == columnCount - 1 && day == Self.rows - 1 {
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
