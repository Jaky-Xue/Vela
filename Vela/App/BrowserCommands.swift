//
//  BrowserCommands.swift
//  Vela
//
//  The hardware-keyboard menu.
//
//  These are the standard browser shortcuts. The buttons only post a command;
//  `BrowserCommandCenter` hands it to the shell's registered handler, so the
//  menu does not need to know how a tab or a sheet is represented.
//

import SwiftUI

struct BrowserCommands: Commands {
    let center: BrowserCommandCenter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建标签页") {
                center.perform(.newTab)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("重新打开关闭的标签页") {
                center.perform(.reopenClosedTab)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("关闭标签页") {
                center.perform(.closeTab)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("聚焦地址栏") {
                center.perform(.focusAddressBar)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("重新载入") {
                center.perform(.reload)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("后退") {
                center.perform(.back)
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("查找网页") {
                center.perform(.findInPage)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("浏览器") {
            Button("上一个标签页") {
                center.perform(.previousTab)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("下一个标签页") {
                center.perform(.nextTab)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("无痕模式") {
                center.perform(.togglePrivate)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("书签") {
                center.perform(.bookmarks)
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Button("历史记录") {
                center.perform(.history)
            }
            .keyboardShortcut("y", modifiers: .command)

            Button("下载") {
                center.perform(.downloads)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Divider()

            Button("设置…") {
                center.perform(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
