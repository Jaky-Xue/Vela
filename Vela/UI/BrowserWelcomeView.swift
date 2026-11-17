import SwiftUI

/// A self-contained tour: demonstrations never navigate or change preferences.
struct BrowserWelcomeView: View {
    static let completionKey = "org.vela.browser.welcome-completed"

    var onFinish: () -> Void
    @Environment(\.browserPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 0

    init(initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: min(4, max(0, initialStep)))
    }

    private let titles = ["从一次搜索开始", "让标签页井井有条", "把喜欢的网站留下", "按你的习惯浏览", "把 Vela 调成你的样子"]
    private let descriptions = [
        "轻点地址栏，输入关键词或网址。点搜索引擎图标，可以切换本次搜索使用的引擎。",
        "点工具栏的标签页按钮查看、切换或关闭页面，也可以新建一个标签页继续探索。",
        "在菜单里选择添加书签或收藏，把网站存进书签，或添加到主页，方便下次打开。",
        "在菜单中使用无痕模式；在设置中管理网站权限、广告拦截和用户脚本。",
        "从菜单进入设置，选择主题、背景与工具栏。历史与书签建议、已打开标签页建议默认关闭，需要时可在搜索引擎设置中开启。"
    ]
    private let symbols = ["magnifyingglass", "square.on.square", "bookmark", "hand.raised", "slider.horizontal.3"]

    var body: some View {
        GeometryReader { proxy in
            // A phone in landscape has far less height than the vertical tour
            // needs; switch to a two-column tour instead of letting the
            // scrollable column disappear behind the pager.
            let compact = proxy.size.height < 520 && proxy.size.width > proxy.size.height
            Group {
                if compact {
                    compactLayout
                } else {
                    regularLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { AmbientBackgroundView() }
        .foregroundStyle(palette.primaryText)
        .tint(palette.accent)
    }

    private var regularLayout: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 28) {
                    illustration(compact: false)
                        .frame(maxWidth: 340)
                        .padding(.top, 28)
                        .accessibilityHidden(true)

                    copy(compact: false)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            header

            HStack(alignment: .center, spacing: 24) {
                ScrollView {
                    illustration(compact: true)
                        .padding(.vertical, 8)
                        .accessibilityHidden(true)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: 300)

                VStack(spacing: 12) {
                    Spacer(minLength: 0)
                    copy(compact: true)
                    Spacer(minLength: 8)
                    pager
                    primaryButton(minHeight: 46)
                    backButton
                }
                .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text("Vela · 使用指南")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
            Spacer()
            Button("跳过", action: onFinish)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 24)
    }

    private func copy(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            Text(titles[step])
                .font(compact ? .title2.bold() : .largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(descriptions[step])
                .font(compact ? .footnote : .body)
                .foregroundStyle(palette.secondaryText)
                .lineSpacing(compact ? 3 : 5)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: compact ? 400 : 440)
        .id(step)
        .transition(.opacity)
    }

    private var footer: some View {
        VStack(spacing: 18) {
            pager
            primaryButton(minHeight: 52)
            backButton
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private var pager: some View {
        HStack(spacing: 8) {
            ForEach(0..<titles.count, id: \.self) { index in
                Capsule()
                    .fill(index == step ? palette.accent : palette.secondaryText.opacity(0.2))
                    .frame(width: index == step ? 24 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step + 1) 步，共 \(titles.count) 步")
    }

    private func primaryButton(minHeight: CGFloat) -> some View {
        Button {
            if step == titles.count - 1 { onFinish() }
            else { changeStep(by: 1) }
        } label: {
            Text(step == titles.count - 1 ? "开始浏览" : "下一步")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: minHeight)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
    }

    private var backButton: some View {
        Button("上一步") { changeStep(by: -1) }
            .frame(minHeight: 36)
            .disabled(step == 0)
            .opacity(step == 0 ? 0 : 1)
            .accessibilityHidden(step == 0)
    }

    private func changeStep(by delta: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            step = min(titles.count - 1, max(0, step + delta))
        }
    }

    private func illustration(compact: Bool) -> some View {
        VStack(spacing: compact ? 16 : 24) {
            if !reduceMotion && scenePhase == .active {
                heroGlyph(compact: compact)
                    .phaseAnimator([false, true]) { glyph, raised in
                        glyph.offset(y: raised ? -5 : 0)
                            .scaleEffect(raised ? 1.03 : 1)
                    } animation: { _ in .easeInOut(duration: 2.4) }
            } else {
                heroGlyph(compact: compact)
            }
            demonstration
                .padding(compact ? 14 : 18)
                .frame(maxWidth: .infinity, minHeight: compact ? 84 : 100)
                .browserCard()
        }
        .id(step)
        .transition(.opacity)
    }

    private func heroGlyph(compact: Bool) -> some View {
        Image(systemName: symbols[step])
            .font(.system(size: compact ? 30 : 38, weight: .medium))
            .foregroundStyle(palette.accent)
            .frame(width: compact ? 64 : 88, height: compact ? 64 : 88)
            .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 20 : 28))
    }

    @ViewBuilder private var demonstration: some View {
        switch step {
        case 0:
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.accent)
                Text("搜索或输入网址").font(.subheadline)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
            }
            .padding(14)
            .browserSearchField()
        case 1:
            HStack(spacing: 12) {
                ForEach(0..<3) { index in
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: index == 2 ? "plus" : "globe")
                            .foregroundStyle(palette.accent)
                        RoundedRectangle(cornerRadius: 3).fill(palette.accent.opacity(0.12))
                            .frame(height: 20)
                    }
                    .padding(12)
                    .browserCard(radius: 12)
                }
            }
        case 2:
            HStack(spacing: 22) {
                Label("书签", systemImage: "bookmark")
                Label("主页", systemImage: "house")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.accent)
        case 3:
            HStack(spacing: 24) {
                ForEach(["eyeglasses", "shield.lefthalf.filled", "curlybraces"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(palette.accent)
                        .frame(width: 44, height: 44)
                }
            }
        default:
            VStack(spacing: 14) {
                Label("外观与工具栏", systemImage: "paintpalette")
                HStack(spacing: 12) {
                    ForEach([Color.blue, .purple, .mint, .orange], id: \.self) { color in
                        Circle().fill(color.gradient).frame(width: 24, height: 24)
                    }
                }
            }
            .font(.subheadline.weight(.medium))
        }
    }
}
