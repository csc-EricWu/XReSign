//
//  AppDelegate.swift
//  XReSign
//
//  Copyright © 2017 xndrs. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    // MARK: - Actions

    @IBAction func actionCopyBundleID(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .copyBundleIDRequested, object: nil)
    }
}

extension Notification.Name {
    static let copyBundleIDRequested = Notification.Name("copyBundleIDRequested")
}
