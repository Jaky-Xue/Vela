//
//  BrowserShellView+MediaPlayer.swift
//  Vela
//
//  The shell's side of the app's fullscreen video player.
//
//  The page owns the picture and `WebPageScripts.mediaPlayerScript` promotes
//  it; this layer only draws controls and turns them into commands. Keeping it
//  apart from the rest of the shell's overlays makes the boundary explicit: a
//  player is not a sheet, not a presented controller, and not part of the page
//  chrome — it is a layer over a page that has deliberately taken the screen.
//

import SwiftUI

extension BrowserShellView {
    /// The player layer, above every other overlay.
    @ViewBuilder
    var mediaPlayerLayer: some View {
        if let session = env.overlays.mediaFullscreen {
            MediaPlayerOverlay(
                session: session,
                safeTop: safeTop,
                safeBottom: safeBottom,
                onCommand: { command in
                    env.noteInteraction("全屏播放")
                    env.webCoordinator.sendMediaPlayerCommand(command)
                },
                onClose: {
                    env.noteInteraction("退出全屏播放")
                    env.webCoordinator.dismissMediaFullscreen()
                }
            )
            .zIndex(210)
            .transition(.opacity)
        }
    }
}
