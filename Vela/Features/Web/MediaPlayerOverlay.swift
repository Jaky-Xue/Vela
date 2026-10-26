//
//  MediaPlayerOverlay.swift
//  Vela
//
//  The controls the shell draws over a page's fullscreen video.
//
//  The page still owns the picture. `WebPageScripts.mediaPlayerScript` promotes
//  the video — or the player container around it — to the viewport, and the
//  site's own JavaScript keeps playing it; this view is a transparent layer
//  over that picture. For a bare `<video>` it supplies the controls the page
//  no longer draws itself. For a site's own player it supplies only the way
//  out, because the site's chrome is already there and two control bars on one
//  film is one too many.
//
//  The layer is deliberately part of the shell's own hierarchy rather than a
//  presented controller: a presentation owns its geometry, and the previous
//  fullscreen work in this project already established that a layer rotates
//  with the window while a presented controller can wedge at the size it was
//  presented at.
//

import Foundation
import SwiftUI

struct MediaPlayerOverlay: View {
    var session: MediaFullscreenSession
    /// The window's status-bar inset, so the close button clears the clock.
    var safeTop: CGFloat
    /// The home-indicator inset, so the seek bar clears the gesture area.
    var safeBottom: CGFloat
    var onCommand: (MediaPlayerCommand) -> Void
    var onClose: () -> Void

    @State private var controlsVisible = true
    @State private var scrubValue: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if session.mode == .video {
                videoChrome
            } else {
                containerChrome
            }
        }
        .ignoresSafeArea()
        // A fullscreen film is the one surface that should own the whole
        // screen. This hides the home indicator and the status bar together
        // with the same API, rather than asking for each separately.
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleAutoHide() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: session.isPaused) { _, paused in
            if paused || session.isEnded {
                revealControls(keep: true)
            } else {
                scheduleAutoHide()
            }
        }
        .onChange(of: session.isEnded) { _, ended in
            if ended { revealControls(keep: true) }
        }
    }

    // MARK: - Bare video

    /// Controls for a video the page fullscreened on its own. The whole screen
    /// is the tap target, because the page's own controls are stood down while
    /// this layer is up — there is nothing else for the tap to mean.
    private var videoChrome: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .accessibilityLabel(controlsVisible ? "隐藏播放控制" : "显示播放控制")

            if controlsVisible {
                controlShade
                    .transition(.opacity)

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    centerControls
                    Spacer(minLength: 0)
                    bottomBar
                }
                .padding(.top, max(safeTop, 12) + 6)
                .padding(.bottom, max(safeBottom, 12) + 6)
                .padding(.horizontal, 18)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    /// A dark wash under the controls, so white ink and a white slider stay
    /// legible over a bright frame. It never takes a touch: the tap target
    /// above it is the one that shows and hides the layer.
    private var controlShade: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.62), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(safeTop, 12) + 92)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(safeBottom, 12) + 132)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton("xmark", label: "退出全屏") { onClose() }

            Text(session.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 1)

            Spacer(minLength: 8)

            circleButton(
                session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: session.isMuted ? "取消静音" : "静音"
            ) {
                onCommand(.setMuted(!session.isMuted))
                scheduleAutoHide()
            }
        }
    }

    private var centerControls: some View {
        HStack(spacing: 54) {
            skipButton(-10)

            Button {
                if session.isEnded {
                    onCommand(.seek(0))
                    onCommand(.play)
                } else {
                    onCommand(.togglePlay)
                }
                scheduleAutoHide()
            } label: {
                Image(systemName: playSymbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.black.opacity(0.42), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel(session.isPaused ? "播放" : "暂停")

            skipButton(10)
        }
    }

    private var playSymbol: String {
        if session.isEnded { return "arrow.counterclockwise" }
        return session.isPaused ? "play.fill" : "pause.fill"
    }

    private func skipButton(_ delta: Double) -> some View {
        Button {
            onCommand(.skip(delta))
            scheduleAutoHide()
        } label: {
            Image(systemName: delta < 0 ? "gobackward.10" : "goforward.10")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(delta < 0 ? "后退十秒" : "前进十秒")
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if session.duration > 0 {
                Slider(
                    value: seekBinding,
                    in: 0...max(session.duration, 1),
                    onEditingChanged: handleScrubbing
                )
                .tint(.white)
                .disabled(!session.canSeek)
                .accessibilityLabel("播放进度")
            }

            HStack {
                Text(timeText(session.currentTime))
                Spacer(minLength: 0)
                Text(timeText(session.duration))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
        }
        .padding(.horizontal, 2)
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: {
                let value = scrubValue ?? session.currentTime
                return min(max(value, 0), max(session.duration, 1))
            },
            set: { scrubValue = $0 }
        )
    }

    private func handleScrubbing(_ editing: Bool) {
        if editing {
            hideTask?.cancel()
            return
        }
        let target = scrubValue ?? session.currentTime
        onCommand(.seek(target))
        scrubValue = nil
        scheduleAutoHide()
    }

    // MARK: - Site player

    /// The way out of a site's own fullscreen player. Everything else on the
    /// screen belongs to the site — its progress bar, its settings menu, its
    /// captions — so this layer adds one control and intercepts nothing else.
    private var containerChrome: some View {
        ZStack(alignment: .topTrailing) {
            // The clearing layer is not hit-testable: every other touch on
            // this screen belongs to the site's player underneath.
            Color.clear
                .allowsHitTesting(false)

            circleButton("xmark", label: "退出全屏") { onClose() }
                .padding(.top, max(safeTop, 12) + 6)
                .padding(.trailing, 18)
        }
    }

    // MARK: - Shared

    private func circleButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }

    /// Hides the controls after a few seconds of playback. Paused and ended
    /// video keep them: the two states where the user is about to act.
    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard session.mode == .video, !session.isPaused, !session.isEnded else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(3500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                controlsVisible = false
            }
        }
    }

    private func revealControls(keep: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            controlsVisible = true
        }
        if keep {
            hideTask?.cancel()
        } else {
            scheduleAutoHide()
        }
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        } else {
            revealControls()
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
