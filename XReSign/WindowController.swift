//
//  WindowController.swift
//  XReSign
//
//  Copyright © 2019 xndrs. All rights reserved.
//

import Cocoa

class WindowController: NSWindowController {

    override func windowDidLoad() {
        super.windowDidLoad()

        var title = "XReSign"
        if let versionShort = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String{
            title += " - \(versionShort).\(version)"
        }
        self.window?.title = title
        self.window?.center()
        // self.window?.appearance = NSAppearance(named: .aqua)
        // 使用经典 Aqua 灰，macOS 11+ 的 windowBackgroundColor 偏白
        self.window?.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
    }
}
