//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log
import ServiceManagement
import Settings

class MainPrefsViewController: NSViewController, SettingsPane {
  let paneIdentifier = Settings.PaneIdentifier.main
  let paneTitle: String = NSLocalizedString("General", comment: "Shown in the main prefs window")

  var toolbarItemIcon: NSImage {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: "switch.2", accessibilityDescription: "Display")!
    } else {
      return NSImage(named: NSImage.infoName)!
    }
  }

  @IBOutlet var startAtLogin: NSButton!
  @IBOutlet var automaticUpdateCheck: NSButton!
  @IBOutlet var allowZeroSwBrightness: NSButton!
  @IBOutlet var combinedBrightness: NSButton!
  @IBOutlet var enableSmooth: NSButton!
  @IBOutlet var enableBrightnessSync: NSButton!
  @IBOutlet var startupAction: NSPopUpButton!
  @IBOutlet var rowDoNothingStartupText: NSGridRow!
  @IBOutlet var rowWriteStartupText: NSGridRow!
  @IBOutlet var rowReadStartupText: NSGridRow!
  private var autoHideNoLGButton: NSButton?
  private var dynamicBrightnessButton: NSButton?

  private static func boolPref(_ key: PrefKey, default defaultValue: Bool) -> Bool {
    if prefs.object(forKey: key.rawValue) == nil {
      return defaultValue
    }
    return prefs.bool(forKey: key.rawValue)
  }

  func updateGridLayout() {
    if self.startupAction.selectedTag() == StartupAction.doNothing.rawValue {
      self.rowDoNothingStartupText.isHidden = false
      self.rowWriteStartupText.isHidden = true
      self.rowReadStartupText.isHidden = true
    } else if self.startupAction.selectedTag() == StartupAction.write.rawValue {
      self.rowDoNothingStartupText.isHidden = true
      self.rowWriteStartupText.isHidden = false
      self.rowReadStartupText.isHidden = true
    } else {
      self.rowDoNothingStartupText.isHidden = true
      self.rowWriteStartupText.isHidden = true
      self.rowReadStartupText.isHidden = false
    }
  }

  @available(macOS, deprecated: 10.10)
  override func viewDidLoad() {
    super.viewDidLoad()
    self.installAutoHideNoLGRowIfNeeded()
    self.installDynamicBrightnessRowIfNeeded()
    self.populateSettings()
  }

  @available(macOS, deprecated: 10.10)
  func populateSettings() {
    // This is marked as deprectated but according to the function header it still does not have a replacement as of macOS 12 Monterey and is valid to use.
    let startAtLogin = (SMCopyAllJobDictionaries(kSMDomainUserLaunchd).takeRetainedValue() as? [[String: AnyObject]])?.first { $0["Label"] as? String == "\(Bundle.main.bundleIdentifier!)Helper" }?["OnDemand"] as? Bool ?? false
    self.startAtLogin.state = startAtLogin ? .on : .off
    self.automaticUpdateCheck.state = prefs.bool(forKey: PrefKey.SUEnableAutomaticChecks.rawValue) ? .on : .off
    self.combinedBrightness.state = prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) ? .off : .on
    self.allowZeroSwBrightness.state = prefs.bool(forKey: PrefKey.allowZeroSwBrightness.rawValue) ? .on : .off
    self.enableSmooth.state = prefs.bool(forKey: PrefKey.disableSmoothBrightness.rawValue) ? .off : .on
    self.enableBrightnessSync.state = prefs.bool(forKey: PrefKey.enableBrightnessSync.rawValue) ? .on : .off
    self.startupAction.selectItem(withTag: prefs.integer(forKey: PrefKey.startupAction.rawValue))
    if let autoHideNoLGButton = self.autoHideNoLGButton {
      let autoHideEnabled = Self.boolPref(.autoHideWhenNoLG, default: true)
      autoHideNoLGButton.state = autoHideEnabled ? .on : .off
    }
    if let dynamicBrightnessButton = self.dynamicBrightnessButton {
      dynamicBrightnessButton.state = prefs.bool(forKey: PrefKey.dynamicBrightnessEnabled.rawValue) ? .on : .off
    }
    // Preload Display settings to some extent to properly set up size in orther that animation won't fail
    menuslidersPrefsVc?.view.layoutSubtreeIfNeeded()
    keyboardPrefsVc?.view.layoutSubtreeIfNeeded()
    displaysPrefsVc?.view.layoutSubtreeIfNeeded()
    aboutPrefsVc?.view.layoutSubtreeIfNeeded()
    self.updateGridLayout()
  }

  private func installAutoHideNoLGRowIfNeeded() {
    self.installCheckboxRowIfNeeded(
      button: &self.autoHideNoLGButton,
      title: NSLocalizedString("Hide menu bar item when no LG display is connected", comment: "General preference"),
      action: #selector(self.autoHideWhenNoLGClicked(_:))
    )
  }

  private func installDynamicBrightnessRowIfNeeded() {
    self.installCheckboxRowIfNeeded(
      button: &self.dynamicBrightnessButton,
      title: NSLocalizedString("Enable dynamic brightness (ambient + location fallback)", comment: "General preference"),
      action: #selector(self.dynamicBrightnessClicked(_:))
    )
  }

  private func installCheckboxRowIfNeeded(button: inout NSButton?, title: String, action: Selector) {
    guard button == nil else {
      return
    }
    guard let gridView = self.view.subviews.compactMap({ $0 as? NSGridView }).first else {
      return
    }
    let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
    checkbox.translatesAutoresizingMaskIntoConstraints = false

    let spacer = NSView(frame: .zero)
    spacer.translatesAutoresizingMaskIntoConstraints = false

    let row = gridView.addRow(with: [spacer, checkbox])
    row.bottomPadding = -13
    button = checkbox
  }

  @objc private func autoHideWhenNoLGClicked(_ sender: NSButton) {
    let enabled = sender.state == .on
    prefs.set(enabled, forKey: PrefKey.autoHideWhenNoLG.rawValue)
    app.configure()
  }

  @objc private func dynamicBrightnessClicked(_ sender: NSButton) {
    let enabled = sender.state == .on
    prefs.set(enabled, forKey: PrefKey.dynamicBrightnessEnabled.rawValue)
    DynamicBrightnessManager.shared.updateEnabledState()
  }

  @IBAction func startAtLoginClicked(_ sender: NSButton) {
    switch sender.state {
    case .on:
      app.setStartAtLogin(enabled: true)
    case .off:
      app.setStartAtLogin(enabled: false)
    default: break
    }
  }

  @IBAction func automaticUpdateCheck(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(true, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)
    case .off:
      prefs.set(false, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)
    default: break
    }
  }

  @IBAction func combinedBrightness(_ sender: NSButton) {
    for display in DisplayManager.shared.getDdcCapableDisplays() where !display.isSw() {
      _ = display.setDirectBrightness(1)
    }
    DisplayManager.shared.resetSwBrightnessForAllDisplays(async: false)
    switch sender.state {
    case .on:
      prefs.set(false, forKey: PrefKey.disableCombinedBrightness.rawValue)
    case .off:
      prefs.set(true, forKey: PrefKey.disableCombinedBrightness.rawValue)
    default: break
    }
    app.configure()
  }

  @IBAction func allowZeroSwBrightness(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(true, forKey: PrefKey.allowZeroSwBrightness.rawValue)
    case .off:
      prefs.set(false, forKey: PrefKey.allowZeroSwBrightness.rawValue)
    default: break
    }
    for display in DisplayManager.shared.getLGOtherDisplays() {
      _ = display.setDirectBrightness(1)
      _ = display.setSwBrightness(1)
    }
    self.updateGridLayout()
    app.configure()
  }

  @IBAction func enableSmooth(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(false, forKey: PrefKey.disableSmoothBrightness.rawValue)
    case .off:
      prefs.set(true, forKey: PrefKey.disableSmoothBrightness.rawValue)
    default: break
    }
  }

  @IBAction func enableBrightnessSync(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(true, forKey: PrefKey.enableBrightnessSync.rawValue)
    case .off:
      prefs.set(false, forKey: PrefKey.enableBrightnessSync.rawValue)
    default: break
    }
  }

  @IBAction func startupAction(_ sender: NSPopUpButton) {
    prefs.set(sender.selectedTag(), forKey: PrefKey.startupAction.rawValue)
    self.updateGridLayout()
  }

  @available(macOS, deprecated: 10.10)
  func resetSheetModalHander(modalResponse: NSApplication.ModalResponse) {
    if modalResponse == NSApplication.ModalResponse.alertFirstButtonReturn {
      app.settingsReset()
      self.populateSettings()
      menuslidersPrefsVc?.populateSettings()
      keyboardPrefsVc?.populateSettings()
      displaysPrefsVc?.populateSettings()
    }
  }

  @available(macOS, deprecated: 10.10)
  @IBAction func resetPrefsClicked(_: NSButton) {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Reset Settings?", comment: "Shown in the alert dialog")
    alert.informativeText = NSLocalizedString("Are you sure you want to reset all settings?", comment: "Shown in the alert dialog")
    alert.addButton(withTitle: NSLocalizedString("Yes", comment: "Shown in the alert dialog"))
    alert.addButton(withTitle: NSLocalizedString("No", comment: "Shown in the alert dialog"))
    alert.alertStyle = NSAlert.Style.warning
    if let window = self.view.window {
      alert.beginSheetModal(for: window, completionHandler: { modalResponse in self.resetSheetModalHander(modalResponse: modalResponse) })
    }
  }
}
