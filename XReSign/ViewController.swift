//
//  ViewController.swift
//  XReSign
//
//  Copyright © 2019 xndrs. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers

class ViewController: NSViewController, NSControlTextEditingDelegate {
    let kLastProvisioningPathKey = "kLastProvisioningPathKey"
    let kEntitlementsPathKey = "kEntitlementsPathKey"
    let kLastBundleIdKey = "kLastBundleIdKey"
    let kLastCertificateKey = "kLastCertificateKey"

    @IBOutlet var textFieldIpaPath: NSTextField!
    @IBOutlet var textFieldProvisioningPath: NSTextField!
    @IBOutlet var textFieldEntitlementsPath: NSTextField!

    @IBOutlet var textFieldBundleId: NSTextField!
    @IBOutlet weak var textFieldBuild: NSTextField!
    @IBOutlet weak var textFieldVersion: NSTextField!
    @IBOutlet var comboBoxKeychains: NSComboBox!
    @IBOutlet var comboBoxCertificates: NSComboBox!
    @IBOutlet var buttonChangeBundleId: NSButton!
    @IBOutlet var buttonResign: NSButton!
    @IBOutlet var progressIndicator: NSProgressIndicator!
    @IBOutlet var textViewLog: NSTextView!

    fileprivate var certificates: [String] = []
    fileprivate var keychains: [String: String] = [:]
    fileprivate var tempDir: String?
    private var progressObserver: NSObjectProtocol!
    private var terminateObserver: NSObjectProtocol!
    private var copyBundleIDObserver: NSObjectProtocol?

    // MARK: - Main

    override func viewDidLoad() {
        super.viewDidLoad()

        copyBundleIDObserver = NotificationCenter.default.addObserver(forName: .copyBundleIDRequested, object: nil, queue: .main) { [weak self] _ in
            self?.copyBundleIDToPasteboard()
        }

        if let defaultProvisioning = UserDefaults.standard.string(forKey: kLastProvisioningPathKey) {
            textFieldProvisioningPath.stringValue = defaultProvisioning
        }
        if let defaultEntitlements = UserDefaults.standard.string(forKey: kEntitlementsPathKey) {
            textFieldEntitlementsPath.stringValue = defaultEntitlements
        }
        if let lastIdentifier = UserDefaults.standard.string(forKey: kLastBundleIdKey) {
            textFieldBundleId.stringValue = lastIdentifier
        }
        apppendLog(message: """
            XReSign allows you to (re)sign unencrypted ipa-file with certificate for which you hold the corresponding private key.

            1. Drag or browse .ipa file to the top box.
            2. Drag or browse provisioning profile to the second box. (Optional)
            3. Drag or browse entitlements plist to the third box. (Optional)
            4. In the next box your can change the app bundle identifier. (Optional)
            5. Select signing certificate from Keychain Access in the bottom box.
            6. Click ReSign! The resigned file will be saved in the same folder as the original file.

            NOTE: Pay attention to the right pair between signing certificate and provisioning profile.
            """)

        textFieldIpaPath.delegate = self
        loadKeychains()
    }

    deinit {
        copyBundleIDObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }

    private func copyBundleIDToPasteboard() {
        guard let textToCopy = textFieldBundleId.placeholderString, !textToCopy.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
    }

    private func clearLog() {
        DispatchQueue.main.async {
            self.textViewLog.string = ""
        }
    }

    private func apppendLog(message: String) {
        if message.count == 0 {
            return
        }

        DispatchQueue.main.async {
            var text: String
            if self.textViewLog.string.isEmpty {
                text = message
            } else {
                text = self.textViewLog.string.appending("\n")
                if let ch = message.last, ch.isNewline {
                    text.append(String(message.dropLast()))
                } else {
                    text.append(message)
                }
            }

            self.textViewLog.string = text
            self.textViewLog.scrollRangeToVisible(NSMakeRange(text.count, 0))
        }
    }

    // MARK: - IPA/ZIP Path Change - Update Placeholders from Info.plist

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === textFieldIpaPath else { return }
        updatePlaceholdersFromPath(textFieldIpaPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func updatePlaceholdersFromPath(_ path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard (ext == "ipa" || ext == "zip") && FileManager.default.fileExists(atPath: path) else {
            restoreDefaultPlaceholders()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.extractAndApplyPlaceholders(from: path)
        }
    }


    private func extractAndApplyPlaceholders(from path: String) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try? FileManager.default.removeItem(at: tempDir)
        guard (try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else { return }

        let unzipTask = Process()
        unzipTask.launchPath = "/usr/bin/unzip"
        unzipTask.arguments = ["-j", "-o", "-q", "-d", tempDir.path, path, "Payload/*.app/Info.plist", "-x", "*/*/*/*"]
        unzipTask.launch()
        unzipTask.waitUntilExit()
        guard unzipTask.terminationStatus == 0 else { return }

        let plistURL = tempDir.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else { return }

        let bundleId = plist["CFBundleIdentifier"] as? String ?? ""
        let version = plist["CFBundleShortVersionString"] as? String ?? ""
        let build = plist["CFBundleVersion"] as? String ?? ""

        DispatchQueue.main.async { [weak self] in
            self?.textFieldBundleId.placeholderString = bundleId
            self?.textFieldVersion.placeholderString = version
            self?.textFieldBuild.placeholderString = build
        }
    }

    private func restoreDefaultPlaceholders() {
        textFieldBundleId.placeholderString = "com.domainname.appname"
        textFieldVersion.placeholderString = "1.0.0"
        textFieldBuild.placeholderString = "1"
    }

    // MARK: - Keychains

    private func loadKeychains() {
        DispatchQueue.global().async {
            let task: Process = Process()
            let pipe: Pipe = Pipe()

            task.launchPath = "/usr/bin/security"
            task.arguments = ["list-keychains"]
            task.standardOutput = pipe
            task.standardError = pipe

            let handle = pipe.fileHandleForReading
            task.launch()
            self.parseKeychainsFrom(data: handle.readDataToEndOfFile())
        }
    }

    private func parseKeychainsFrom(data: Data) {
        let buffer = String(data: data, encoding: String.Encoding.utf8)!
        var map: [String: String] = [:]
        let characterSet = NSMutableCharacterSet.whitespace()
        characterSet.addCharacters(in: "\"")

        buffer.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: characterSet as CharacterSet)
            let name = (trimmed as NSString).lastPathComponent
            map[name] = trimmed
        }

        DispatchQueue.main.sync {
            self.keychains = map
            self.comboBoxKeychains.reloadData()
            // load default for login.keychain-db
            map.enumerated().forEach { arg0 in
                let (offset, (key, _)) = arg0
                if key.localizedStandardContains("login.") {
                    self.comboBoxKeychains.selectItem(at: offset)
                }
            }
        }
    }

    // MARK: - Certificates

    private func loadCertificatesFromKeychain(_ keychain: String) {
        DispatchQueue.global().async {
            let task: Process = Process()
            let pipe: Pipe = Pipe()

            task.launchPath = "/usr/bin/security"
            task.arguments = ["find-identity", "-v", "-p", "codesigning", keychain]
            task.standardOutput = pipe
            task.standardError = pipe

            let handle = pipe.fileHandleForReading
            task.launch()
            self.parseCertificatesFrom(data: handle.readDataToEndOfFile())
        }
    }

    private func parseCertificatesFrom(data: Data) {
        let buffer = String(data: data, encoding: String.Encoding.utf8)!
        var names: [String] = []

        buffer.enumerateLines { line, _ in
            // default output line format for security command:
            // 1) E00D4E3D3272ABB655CDE0C1CF53891210BAF4B8 "iPhone Developer: XXXXXXXXXX (YYYYYYYYYY)"
            let components = line.components(separatedBy: "\"")
            if components.count > 2 {
                let commonName = components[components.count - 2]
                names.append(commonName)
            }
        }

        names.sort(by: { $0 < $1 })
        DispatchQueue.main.sync {
            self.certificates.removeAll()
            self.certificates.append(contentsOf: names)
            self.comboBoxCertificates.reloadData()
            if let lastCert = UserDefaults.standard.string(forKey: self.kLastCertificateKey),
               let index = self.certificates.firstIndex(of: lastCert) {
                self.comboBoxCertificates.selectItem(at: index)
            } else {
                self.comboBoxCertificates.deselectItem(at: self.comboBoxCertificates.indexOfSelectedItem)
            }
        }
    }

    private func organizationUnitFromCertificate(by name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                    kSecAttrLabel as String: name,
                                    kSecReturnRef as String: kCFBooleanTrue!]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        let certificate = item as! SecCertificate

        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let subjectValue = SecCertificateCopyValues(certificate, keys, nil) else {
            return nil
        }

        if let subjectDict = subjectValue as? [String: Any] {
            let rootDict = subjectDict["\(kSecOIDX509V1SubjectName)"] as? [String: Any]
            if let values = rootDict?["value"] as? [Any] {
                for value in values {
                    if let dict = value as? [String: Any] {
                        if let label = dict["label"] as? String, let value = dict["value"] as? String {
                            if label.compare("\(kSecOIDOrganizationalUnitName)") == .orderedSame {
                                return value
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    private func teamIdentifierFromProvisioning(path provisioningPath: String) -> String? {
        guard let launchPath = Bundle.main.path(forResource: "entitlements", ofType: "sh") else {
            showAlertWith(title: nil, message: "Can not find entitlements script to run", style: .critical)
            return nil
        }

        guard let _ = tempDir else {
            showAlertWith(title: nil, message: "Internal error. No temporary directory for script.", style: .critical)
            return nil
        }

        let task: Process = Process()
        let pipe: Pipe = Pipe()

        task.launchPath = "/bin/sh"
        task.arguments = [launchPath, provisioningPath, tempDir!]
        task.standardOutput = pipe
        task.standardError = pipe

        let handle = pipe.fileHandleForReading
        task.launch()

        let data = handle.readDataToEndOfFile()
        let buffer = String(data: data, encoding: String.Encoding.utf8)!

        if let _ = buffer.range(of: "SUCCESS") {
            let path = "\(tempDir!)/entitlements.plist"
            if FileManager.default.fileExists(atPath: path) {
                if let plist = NSDictionary(contentsOfFile: path) {
                    if let teamIdentifier = plist["com.apple.developer.team-identifier"] as? String {
                        return teamIdentifier
                    }
                }
            }
        }
        return nil
    }

    private func signIpaWith(path ipaPath: String, developer: String, provisioning: String, bundle: String?, entitlementsPath: String?, version: String?, build: String?) {
        guard let launchPath = Bundle.main.path(forResource: "xresign", ofType: "sh") else {
            showAlertWith(title: nil, message: "Can not find resign script to run", style: .critical)
            return
        }

        clearLog()

        buttonResign.isEnabled = false
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)

        var args = [launchPath, "-s", ipaPath, "-c", developer, "-p", provisioning, "-b", bundle ?? "", "-e", entitlementsPath ?? ""]
        if let v = version, !v.isEmpty {
            args.append(contentsOf: ["-v", v])
        }
        if let n = build, !n.isEmpty {
            args.append(contentsOf: ["-n", n])
        }

        let task: Process = Process()
        let pipe: Pipe = Pipe()

        task.launchPath = "/bin/sh"
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.waitForDataInBackgroundAndNotify()

        progressObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.NSFileHandleDataAvailable,
                                                                  object: handle, queue: nil) {  notification -> Void in
            let data = handle.availableData
            if data.count > 0 {
                if let message = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
                    self.apppendLog(message: message as String)
                }
                handle.waitForDataInBackgroundAndNotify()
            } else {
                NotificationCenter.default.removeObserver(self.progressObserver!)
            }
        }

        terminateObserver = NotificationCenter.default.addObserver(forName: Process.didTerminateNotification,
                                                                   object: task, queue: nil) { notification -> Void in
            NotificationCenter.default.removeObserver(self.terminateObserver!)
            DispatchQueue.main.async {
                self.buttonResign.isEnabled = true
                self.progressIndicator.stopAnimation(nil)
                self.progressIndicator.isHidden = true
            }
        }

        task.launch()
    }

    // MARK: - Entitlements

    func codesignEntitlementsDataFromApp(bundlePath: String) -> Data? {
//          // get entitlements: codesign -d <AppBinary> --entitlements :-
        let codesignTask: Process = Process()
        let pipe: Pipe = Pipe()

        codesignTask.launchPath = "/usr/bin/codesign"
        codesignTask.standardOutput = pipe
//        codesignTask.standardError = pipe
        codesignTask.arguments = ["-d", bundlePath, "--entitlements", ":-"]

        codesignTask.launch()
        let pipeData = pipe.fileHandleForReading.readDataToEndOfFile()
        codesignTask.waitUntilExit()
        return pipeData
    }

    // MARK: - Actions

    @IBAction func actionBrowseIpa(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .zip, .zip]
        openPanel.begin { (result) -> Void in
            if result == .OK, let path = openPanel.url?.path {
                self.textFieldIpaPath.stringValue = path
                self.updatePlaceholdersFromPath(path)
            }
        }
    }

    @IBAction func actionGetEntitlements(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .zip, UTType(filenameExtension: "mobileprovision") ?? .data]
        openPanel.begin { (result) -> Void in
            if result == .OK {
                if let path = openPanel.url?.path {
                    handleSelectedFile(path: path)
                }
            }
        }

        func handleSelectedFile(path: String) {
            let filePath = path as NSString
            let ipaDir = URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString
            let entitlementsDir = ipaDir.appendingPathComponent("entitlements") as NSString
            let entitlementsPath = entitlementsDir.appendingPathComponent("entitlements.plist")

            if !FileManager.default.fileExists(atPath: String(entitlementsDir)) {
                //            try? FileManager.default.removeItem(atPath: String(currentTempDirFolder))
                try? FileManager.default.createDirectory(atPath: String(entitlementsDir), withIntermediateDirectories: true, attributes: nil)
            }

            if filePath.pathExtension.lowercased() == "ipa" {
                var unzipTask: Process = Process()
                unzipTask.launchPath = "/usr/bin/unzip"

                unzipTask.arguments = ["-u", "-j", "-o", "-q", "-d", String(entitlementsDir), path, "Payload/*.app/embedded.mobileprovision", "Payload/*.app/Info.plist", "-x", "*/*/*/*"]

                unzipTask.launch()
                unzipTask.waitUntilExit()

                let plistPath = entitlementsDir.appendingPathComponent("Info.plist")
                guard let appPlist = try? Data(contentsOf: URL(fileURLWithPath: plistPath)) else {
                    return
                }
                guard let appPropertyList = try? PropertyListSerialization.propertyList(from: appPlist, options: PropertyListSerialization.ReadOptions(), format: nil) else {
                    return
                }
                guard let pListDict = appPropertyList as? Dictionary<String, AnyObject> else {
                    return
                }
                guard let bundleExecutable = pListDict["CFBundleExecutable"] as? String else {
                    return
                }
                let bundlePath = NSString("Payload/*.app/").appendingPathComponent(bundleExecutable)

                unzipTask = Process()
                unzipTask.launchPath = "/usr/bin/unzip"
                unzipTask.arguments = ["-u", "-j", "-o", "-q", "-d", String(entitlementsDir), path, bundlePath, "-x", "*/*/*/*"]
                unzipTask.launch()
                unzipTask.waitUntilExit()

                if let codesignEntitlementsData = codesignEntitlementsDataFromApp(bundlePath: entitlementsDir.appendingPathComponent(bundleExecutable)) {
                    // read the entitlements directly from the codesign output
                    guard let entitlements = try? PropertyListSerialization.propertyList(from: codesignEntitlementsData, options: PropertyListSerialization.ReadOptions(), format: nil) as? NSDictionary else {
                        return
                    }
                    if entitlements.write(toFile: entitlementsPath, atomically: true) {
                        showAlertWith(title: nil, message: String(format: "get entitlements to %@", entitlementsPath), style: .informational)
                        NSWorkspace.shared.open(URL(fileURLWithPath: entitlementsDir as String))
                    }
                } else {
                    // read the entitlements from the provisioning profile instead
                    guard let entitlements = pListDict["Entitlements"] as? NSDictionary else {
                        return
                    }
                    if entitlements.write(toFile: entitlementsPath, atomically: true) {
                        showAlertWith(title: nil, message: String(format: "get entitlements to %@", entitlementsPath), style: .informational)
                        NSWorkspace.shared.open(URL(fileURLWithPath: entitlementsDir as String))
                    }
                }
            } else if filePath.pathExtension.lowercased() == "mobileprovision" {
                guard let launchPath = Bundle.main.path(forResource: "entitlements", ofType: "sh") else {
                    showAlertWith(title: nil, message: "Can not find entitlements script to run", style: .critical)
                    return
                }

                DispatchQueue.global().async {
                    let task: Process = Process()
                    let pipe: Pipe = Pipe()

                    task.launchPath = "/bin/sh"
                    task.arguments = [launchPath, path, entitlementsDir as String]
                    task.standardOutput = pipe
                    task.standardError = pipe

                    let handle = pipe.fileHandleForReading
                    task.launch()

                    let data = handle.readDataToEndOfFile()
                    let buffer = String(data: data, encoding: String.Encoding.utf8)!
                    print("\(buffer)")

                    var success = false
                    if let _ = buffer.range(of: "SUCCESS") {
                        success = true
                    }
                    DispatchQueue.main.async {
                        if success {
                            self.showAlertWith(title: nil, message: String(format: "get entitlements to %@", entitlementsDir), style: .informational)
                            NSWorkspace.shared.open(URL(fileURLWithPath: entitlementsDir as String))
                        } else {
                            return
                        }
                    }
                }
                return
            } else {
                showAlertWith(title: nil, message: "Please select mobileprovision or IPA file", style: .critical)
            }
        }
    }

    @IBAction func actionBrowsEntitlements(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.propertyList]
        openPanel.begin { (result) -> Void in
            if result == .OK {
                self.textFieldEntitlementsPath.stringValue = openPanel.url?.path ?? ""
            }
        }
    }

    @IBAction func actionBrowseProvisioning(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [UTType(filenameExtension: "mobileprovision") ?? .data]
        openPanel.begin { (result) -> Void in
            if result == .OK {
                self.textFieldProvisioningPath.stringValue = openPanel.url?.path ?? ""
            }
        }
    }

    @IBAction func actionChangeBundleId(_ sender: Any) {
        textFieldBundleId.isEnabled = buttonChangeBundleId.state == .on
    }

    @IBAction func actionSign(_ sender: Any) {
        let ipaPath = textFieldIpaPath.stringValue
        let provisioningPath = textFieldProvisioningPath.stringValue
        let entitlementsPath = textFieldEntitlementsPath.stringValue

        let bundleId: String? = buttonChangeBundleId.state == .on ? textFieldBundleId.stringValue : nil
        let index = comboBoxCertificates.indexOfSelectedItem
        let certificateName: String? = index >= 0 ? certificates[index] : nil

        if ipaPath.isEmpty {
            showAlertWith(title: nil, message: "IPA file not selected", style: .critical)
            return
        }

        guard let commonName = certificateName else {
            showAlertWith(title: nil, message: "Signing certificate not selected", style: .critical)
            return
        }

        tempDir = URL(fileURLWithPath: ipaPath).deletingLastPathComponent().path
        tempDir?.append("/tmp")
        if let path = tempDir {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }

        if !entitlementsPath.isEmpty {
            if !FileManager.default.fileExists(atPath: entitlementsPath) {
                showAlertWith(title: nil,
                              message: "Entitlements not exists!",
                              style: .critical)
                return
            }
        }
        UserDefaults.standard.setValue(entitlementsPath, forKey: kEntitlementsPathKey)

        // if there is a path to provisioning profile, check right pair with signing certificate
        if !provisioningPath.isEmpty {
            guard let organizationUnit = organizationUnitFromCertificate(by: commonName) else {
                showAlertWith(title: nil,
                              message: "Can not retrieve organization unit value for certificate \(commonName)",
                              style: .critical)
                return
            }
            if !FileManager.default.fileExists(atPath: provisioningPath) {
                showAlertWith(title: nil,
                              message: "Provisioning not exists!",
                              style: .critical)
                return
            }
            guard let teamIdentifier = teamIdentifierFromProvisioning(path: provisioningPath) else {
                showAlertWith(title: nil,
                              message: "Can not retrieve team identifier from provisioning profile",
                              style: .critical)
                return
            }

            if organizationUnit.compare(teamIdentifier) != .orderedSame {
                showAlertWith(title: nil,
                              message: "There is a problem!\n" +
                                  "Different team identifiers\n" +
                                  "Provisioing team identifier: \(teamIdentifier)\n" +
                                  "Certificate team identifier: \(organizationUnit)\n" +
                                  "Check it and select the right pair.",
                              style: .critical)
                return
            }
        }

        UserDefaults.standard.setValue(provisioningPath, forKey: kLastProvisioningPathKey)
        if buttonChangeBundleId.state == .on {
            UserDefaults.standard.setValue(bundleId, forKey: kLastBundleIdKey)
        }
        UserDefaults.standard.setValue(commonName, forKey: kLastCertificateKey)
        let version = textFieldVersion.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = textFieldBuild.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        signIpaWith(path: ipaPath, developer: commonName, provisioning: provisioningPath, bundle: bundleId, entitlementsPath: entitlementsPath.isEmpty ? nil : entitlementsPath, version: version.isEmpty ? nil : version, build: build.isEmpty ? nil : build)
    }

    // MARK: - Alert

    private func showAlertWith(title: String?, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title ?? "XReSign"
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "Close")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSComboBoxDelegate

extension ViewController: NSComboBoxDelegate {
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let comboBox = notification.object as? NSComboBox, comboBox === comboBoxKeychains {
            guard comboBox.indexOfSelectedItem < keychains.count else { return }
            loadCertificatesFromKeychain(Array(keychains.values)[comboBox.indexOfSelectedItem])
        }
    }
}

// MARK: - NSComboBoxDataSource

extension ViewController: NSComboBoxDataSource {
    func numberOfItems(in comboBox: NSComboBox) -> Int {
        if comboBox === comboBoxKeychains {
            return keychains.count
        } else if comboBox === comboBoxCertificates {
            return certificates.count
        }
        return 0
    }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        if comboBox === comboBoxKeychains {
            return Array(keychains.keys)[index]
        } else if comboBox === comboBoxCertificates {
            return certificates[index]
        }
        return nil
    }
}
