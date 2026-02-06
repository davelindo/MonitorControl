//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import CoreGraphics
import os.log

class DisplayManager {
  static let shared = DisplayManager()

  var displays: [Display] = []
  var audioControlTargetDisplays: [OtherDisplay] = []
  let globalDDCQueue = DispatchQueue(label: "Global DDC queue")
  private let shadeUpdateQueue = DispatchQueue(label: "Shade update queue")
  let gammaActivityEnforcer = NSWindow(contentRect: .init(origin: NSPoint(x: 0, y: 0), size: .init(width: DEBUG_GAMMA_ENFORCER ? 15 : 1, height: DEBUG_GAMMA_ENFORCER ? 15 : 1)), styleMask: [], backing: .buffered, defer: false)
  var gammaInterferenceCounter = 0
  var gammaInterferenceWarningShown = false
  /// LG vendor code "GSM" is commonly reported as 0x1E6D.
  private let lgVendorIDs: Set<UInt32> = [0x1E6D]
  // Keep the menu visible briefly after launch even with no LG display.
  private let launchDate = Date()
  private let launchMenuGracePeriod: TimeInterval = 60

  func createGammaActivityEnforcer() {
    self.gammaActivityEnforcer.title = "Monitor Control Gamma Activity Enforcer"
    self.gammaActivityEnforcer.isMovableByWindowBackground = false
    self.gammaActivityEnforcer.backgroundColor = DEBUG_GAMMA_ENFORCER ? .red : .black
    self.gammaActivityEnforcer.alphaValue = 1 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01)
    self.gammaActivityEnforcer.ignoresMouseEvents = true
    self.gammaActivityEnforcer.level = .screenSaver
    self.gammaActivityEnforcer.orderFrontRegardless()
    self.gammaActivityEnforcer.collectionBehavior = [.stationary, .canJoinAllSpaces]
    os_log("Gamma activity enforcer created.", type: .info)
  }

  func enforceGammaActivity() {
    if self.gammaActivityEnforcer.alphaValue == 1 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01) {
      self.gammaActivityEnforcer.alphaValue = 2 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01)
    } else {
      self.gammaActivityEnforcer.alphaValue = 1 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01)
    }
  }

  func moveGammaActivityEnforcer(displayID: CGDirectDisplayID) {
    if let screen = DisplayManager.getByDisplayID(displayID: DisplayManager.resolveEffectiveDisplayID(displayID)) {
      self.gammaActivityEnforcer.setFrameOrigin(screen.frame.origin)
    }
    self.gammaActivityEnforcer.orderFrontRegardless()
  }

  var shades: [CGDirectDisplayID: NSWindow] = [:]
  var shadeGrave: [NSWindow] = []
  private var pendingShadeAlpha: [CGDirectDisplayID: Float] = [:]
  private var shadeUpdateScheduled: Set<CGDirectDisplayID> = []

  private func onMainSync<T>(_ work: () -> T) -> T {
    if Thread.isMainThread {
      return work()
    }
    return DispatchQueue.main.sync(execute: work)
  }

  private func applyPendingShadeAlpha(displayID: CGDirectDisplayID) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.applyPendingShadeAlpha(displayID: displayID)
      }
      return
    }
    var pending: Float?
    self.shadeUpdateQueue.sync {
      pending = self.pendingShadeAlpha[displayID]
      self.pendingShadeAlpha.removeValue(forKey: displayID)
      self.shadeUpdateScheduled.remove(displayID)
    }
    guard let pending else {
      return
    }
    if let shade = self.getShade(displayID: displayID) {
      shade.contentView?.alphaValue = CGFloat(pending)
    }
    // If more updates arrived while we were applying, schedule another pass.
    self.shadeUpdateQueue.async(flags: .barrier) {
      guard self.pendingShadeAlpha[displayID] != nil, !self.shadeUpdateScheduled.contains(displayID) else {
        return
      }
      self.shadeUpdateScheduled.insert(displayID)
      DispatchQueue.main.async {
        self.applyPendingShadeAlpha(displayID: displayID)
      }
    }
  }

  func isDisqualifiedFromShade(_ displayID: CGDirectDisplayID) -> Bool {
    if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
      if displayID == DisplayManager.resolveEffectiveDisplayID(displayID), DisplayManager.isVirtual(displayID: displayID) || DisplayManager.isDummy(displayID: displayID) {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displayIDs, &displayCount) == .success else {
          return true
        }
        for displayId in displayIDs where CGDisplayMirrorsDisplay(displayId) == displayID && !DisplayManager.isVirtual(displayID: displayID) {
          return true
        }
        return false
      }
      return true
    }
    return false
  }

  func createShadeOnDisplay(displayID: CGDirectDisplayID) -> NSWindow? {
    self.onMainSync {
      if let screen = DisplayManager.getByDisplayID(displayID: displayID) {
        let shade = NSWindow(contentRect: .init(origin: NSPoint(x: 0, y: 0), size: .init(width: 10, height: 1)), styleMask: [], backing: .buffered, defer: false)
        shade.title = "Monitor Control Window Shade for Display " + String(displayID)
        shade.isMovableByWindowBackground = false
        shade.backgroundColor = .clear
        shade.ignoresMouseEvents = true
        shade.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        shade.orderFrontRegardless()
        shade.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        shade.setFrame(screen.frame, display: true)
        shade.contentView?.wantsLayer = true
        shade.contentView?.alphaValue = 0.0
        shade.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        shade.contentView?.setNeedsDisplay(shade.frame)
        os_log("Window shade created for display %{public}@", type: .info, String(displayID))
        return shade
      }
      return nil
    }
  }

  func getShade(displayID: CGDirectDisplayID) -> NSWindow? {
    self.onMainSync {
      guard !self.isDisqualifiedFromShade(displayID) else {
        return nil
      }
      if let shade = self.shades[displayID] {
        return shade
      }
      if let shade = self.createShadeOnDisplay(displayID: displayID) {
        self.shades[displayID] = shade
        return shade
      }
      return nil
    }
  }

  func destroyAllShades() -> Bool {
    self.onMainSync {
      var ret = false
      for displayID in self.shades.keys {
        os_log("Attempting to destory shade for display  %{public}@", type: .info, String(displayID))
        if self.destroyShade(displayID: displayID) {
          ret = true
        }
      }
      if ret {
        os_log("Destroyed all shades.", type: .info)
      } else {
        os_log("No shades were found to be destroyed.", type: .info)
      }
      return ret
    }
  }

  func destroyShade(displayID: CGDirectDisplayID) -> Bool {
    self.shadeUpdateQueue.async(flags: .barrier) {
      self.pendingShadeAlpha.removeValue(forKey: displayID)
      self.shadeUpdateScheduled.remove(displayID)
    }
    return self.onMainSync {
      if let shade = self.shades[displayID] {
        os_log("Destroying shade for display %{public}@", type: .info, String(displayID))
        self.shadeGrave.append(shade)
        self.shades.removeValue(forKey: displayID)
        shade.close()
        return true
      }
      return false
    }
  }

  func updateShade(displayID: CGDirectDisplayID) -> Bool {
    self.onMainSync {
      guard !self.isDisqualifiedFromShade(displayID) else {
        return false
      }
      if let screen = DisplayManager.getByDisplayID(displayID: displayID), let shade = self.getShade(displayID: displayID) {
        shade.setFrame(screen.frame, display: true)
        return true
      }
      return false
    }
  }

  func getShadeAlpha(displayID: CGDirectDisplayID) -> Float? {
    guard !self.isDisqualifiedFromShade(displayID) else {
      return 1
    }
    var pending: Float?
    self.shadeUpdateQueue.sync {
      pending = self.pendingShadeAlpha[displayID]
    }
    if let pending {
      return pending
    }
    return self.onMainSync {
      if let shade = self.getShade(displayID: displayID) {
        return Float(shade.contentView?.alphaValue ?? 1)
      }
      return 1
    }
  }

  func setShadeAlpha(value: Float, displayID: CGDirectDisplayID) -> Bool {
    guard !self.isDisqualifiedFromShade(displayID) else {
      return false
    }
    let clamped = max(0, min(1, value))
    self.shadeUpdateQueue.async(flags: .barrier) {
      self.pendingShadeAlpha[displayID] = clamped
      guard !self.shadeUpdateScheduled.contains(displayID) else {
        return
      }
      self.shadeUpdateScheduled.insert(displayID)
      DispatchQueue.main.async {
        self.applyPendingShadeAlpha(displayID: displayID)
      }
    }
    return true
  }

  func configureDisplays() {
    self.clearDisplays()
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineDisplayIDs, &displayCount) == .success else {
      os_log("Unable to get display list.", type: .info)
      return
    }
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      let name = DisplayManager.getDisplayNameByID(displayID: onlineDisplayID)
      let id = onlineDisplayID
      let vendorNumber = CGDisplayVendorNumber(onlineDisplayID)
      let modelNumber = CGDisplayModelNumber(onlineDisplayID)
      let serialNumber = CGDisplaySerialNumber(onlineDisplayID)
      let isDummy: Bool = DisplayManager.isDummy(displayID: onlineDisplayID)
      let isVirtual: Bool = DisplayManager.isVirtual(displayID: onlineDisplayID)
      if !DEBUG_SW, DisplayManager.isAppleDisplay(displayID: onlineDisplayID) { // MARK: (point of interest for testing)

        let appleDisplay = AppleDisplay(id, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isVirtual: isVirtual, isDummy: isDummy)
        os_log("Apple display found - %{public}@", type: .info, "ID: \(appleDisplay.identifier), Name: \(appleDisplay.name) (Vendor: \(appleDisplay.vendorNumber ?? 0), Model: \(appleDisplay.modelNumber ?? 0))")
        self.addDisplay(display: appleDisplay)
      } else {
        let otherDisplay = OtherDisplay(id, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isVirtual: isVirtual, isDummy: isDummy)
        os_log("Other display found - %{public}@", type: .info, "ID: \(otherDisplay.identifier), Name: \(otherDisplay.name) (Vendor: \(otherDisplay.vendorNumber ?? 0), Model: \(otherDisplay.modelNumber ?? 0))")
        self.addDisplay(display: otherDisplay)
      }
    }
  }

  private func isLikelyLG(display: Display) -> Bool {
    if let vendor = display.vendorNumber, self.lgVendorIDs.contains(vendor) {
      return true
    }
    let lowerName = display.name.lowercased()
    return lowerName.contains("lg") || lowerName.contains("ultrafine")
  }

  func isLGDisplay(_ display: Display) -> Bool {
    let isExternal = CGDisplayIsBuiltin(display.identifier) == 0
    return isExternal && !display.isDummy && self.isLikelyLG(display: display)
  }

  func hasLGDisplaysConnected() -> Bool {
    self.displays.contains { self.isLGDisplay($0) }
  }

  private func autoHideEnabled() -> Bool {
    prefs.object(forKey: PrefKey.autoHideWhenNoLG.rawValue) == nil
      ? true
      : prefs.bool(forKey: PrefKey.autoHideWhenNoLG.rawValue)
  }

  func isLGActive() -> Bool {
    // Opt-out: keep running even when no LG displays are present.
    if !self.autoHideEnabled() {
      return true
    }
    return self.hasLGDisplaysConnected()
  }

  func isInLaunchMenuGracePeriod() -> Bool {
    guard self.autoHideEnabled(), !self.hasLGDisplaysConnected() else {
      return false
    }
    return Date().timeIntervalSince(self.launchDate) < self.launchMenuGracePeriod
  }

  func shouldKeepMenuVisible() -> Bool {
    self.isLGActive() || self.isInLaunchMenuGracePeriod()
  }

  func setupOtherDisplays(firstrun: Bool = false) {
    for otherDisplay in self.getLGOtherDisplays() {
      for command in [Command.audioSpeakerVolume, Command.contrast] where !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: command) && !otherDisplay.isSw() {
        otherDisplay.setupCurrentAndMaxValues(command: command, firstrun: firstrun)
      }
      if (!otherDisplay.isSw() && !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .brightness)) || otherDisplay.isSw() {
        otherDisplay.setupCurrentAndMaxValues(command: .brightness, firstrun: firstrun)
        otherDisplay.brightnessSyncSourceValue = otherDisplay.readPrefAsFloat(for: .brightness)
      }
    }
  }

  func restoreOtherDisplays() {
    for otherDisplay in self.getDdcCapableDisplays() {
      for command in [Command.contrast, Command.brightness] where !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: command) {
        otherDisplay.restoreDDCSettingsToDisplay(command: command)
      }
    }
  }

  func normalizedName(_ name: String) -> String {
    var normalizedName = name.replacingOccurrences(of: "(", with: "")
    normalizedName = normalizedName.replacingOccurrences(of: ")", with: "")
    normalizedName = normalizedName.replacingOccurrences(of: " ", with: "")
    for i in 0 ... 9 {
      normalizedName = normalizedName.replacingOccurrences(of: String(i), with: "")
    }
    return normalizedName
  }

  func updateAudioControlTargetDisplays(deviceName: String) -> Int {
    self.audioControlTargetDisplays.removeAll()
    os_log("Detecting displays for audio control via audio device name matching...", type: .info)
    var numOfAddedDisplays = 0
    for ddcCapableDisplay in self.getDdcCapableDisplays() {
      var displayAudioDeviceName = ddcCapableDisplay.readPrefAsString(key: .audioDeviceNameOverride)
      if displayAudioDeviceName == "" {
        displayAudioDeviceName = DisplayManager.getDisplayRawNameByID(displayID: ddcCapableDisplay.identifier)
      }
      if self.normalizedName(displayAudioDeviceName) == self.normalizedName(deviceName) {
        self.audioControlTargetDisplays.append(ddcCapableDisplay)
        numOfAddedDisplays += 1
        os_log("Added display for audio control - %{public}@", type: .info, ddcCapableDisplay.name)
      }
    }
    return numOfAddedDisplays
  }

  func getOtherDisplays() -> [OtherDisplay] {
    self.displays.compactMap { $0 as? OtherDisplay }
  }

  func sortDisplays() {
    let before = self.displays.map(\.name)
    os_log("Displays before sorting: %{public}@", before)

    self.displays.sort { lhs, rhs in
      lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    let after = self.displays.map(\.name)
    os_log("Displays after sorting: %{public}@", after)
  }

  func sortDisplaysByFriendlyName(_ displayList: [Display]? = nil) -> [Display] {
    let list = displayList ?? self.displays

    func title(for display: Display) -> String {
      let friendly = display.readPrefAsString(key: .friendlyName)
      return friendly.isEmpty ? display.name : friendly
    }

    return list.sorted { lhs, rhs in
      let lhsTitle = title(for: lhs)
      let rhsTitle = title(for: rhs)
      return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedDescending
    }
  }

  /// Returns the current display list.
  func getAllDisplays() -> [Display] {
    self.displays
  }

  func getDdcCapableDisplays() -> [OtherDisplay] {
    self.displays.compactMap { display in
      guard let otherDisplay = display as? OtherDisplay else {
        return nil
      }
      guard !otherDisplay.isSw(), self.isLGDisplay(otherDisplay) else {
        return nil
      }
      return otherDisplay
    }
  }

  func getAppleDisplays() -> [AppleDisplay] {
    self.displays.compactMap { $0 as? AppleDisplay }
  }

  func getLGDisplays() -> [Display] {
    self.displays.filter { self.isLGDisplay($0) }
  }

  func getLGOtherDisplays() -> [OtherDisplay] {
    self.displays.compactMap { display in
      guard let otherDisplay = display as? OtherDisplay, self.isLGDisplay(otherDisplay) else {
        return nil
      }
      return otherDisplay
    }
  }

  func getLGAppleDisplays() -> [AppleDisplay] {
    self.displays.compactMap { display in
      guard let appleDisplay = display as? AppleDisplay, self.isLGDisplay(appleDisplay) else {
        return nil
      }
      return appleDisplay
    }
  }

  func getBuiltInDisplay() -> Display? {
    self.displays.first { CGDisplayIsBuiltin($0.identifier) != 0 }
  }

  func isBuiltInDisplayActive() -> Bool {
    NSScreen.screens.contains { CGDisplayIsBuiltin($0.displayID) != 0 }
  }

  func getCurrentDisplay(byFocus: Bool = false) -> Display? {
    if byFocus {
      guard let mainDisplayID = NSScreen.main?.displayID else {
        return nil
      }
      return self.displays.first { $0.identifier == mainDisplayID }
    } else {
      let mouseLocation = NSEvent.mouseLocation
      let screens = NSScreen.screens
      if let screenWithMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }) {
        return self.displays.first { $0.identifier == screenWithMouse.displayID }
      }
      return nil
    }
  }

  func getCurrentLGDisplay(byFocus: Bool = false) -> Display? {
    if let current = self.getCurrentDisplay(byFocus: byFocus), self.isLGDisplay(current) {
      return current
    }
    return self.getLGDisplays().first
  }

  func addDisplay(display: Display) {
    self.displays.append(display)
  }

  func clearDisplays() {
    self.displays = []
  }

  func addDisplayCounterSuffixes() {
    var nameDisplays: [String: [Display]] = [:]
    for display in self.displays {
      if nameDisplays[display.name] != nil {
        nameDisplays[display.name]?.append(display)
      } else {
        nameDisplays[display.name] = [display]
      }
    }
    for nameDisplayKey in nameDisplays.keys where nameDisplays[nameDisplayKey]?.count ?? 0 > 1 {
      for i in 0 ... (nameDisplays[nameDisplayKey]?.count ?? 1) - 1 {
        if let display = nameDisplays[nameDisplayKey]?[i] {
          display.name = "" + display.name + " (" + String(i + 1) + ")"
        }
      }
    }
  }

  func updateArm64AVServices() {
    if Arm64DDC.isArm64 {
      os_log("arm64 AVService update requested", type: .info)
      var displayIDs: [CGDirectDisplayID] = []
      for otherDisplay in self.getLGOtherDisplays() {
        displayIDs.append(otherDisplay.identifier)
      }
      for serviceMatch in Arm64DDC.getServiceMatches(displayIDs: displayIDs) {
        for otherDisplay in self.getLGOtherDisplays() where otherDisplay.identifier == serviceMatch.displayID && serviceMatch.service != nil {
          otherDisplay.arm64avService = serviceMatch.service
          os_log("Display service match successful for display %{public}@", type: .info, String(serviceMatch.displayID))
          if serviceMatch.discouraged {
            os_log("Display %{public}@ is flagged as discouraged by Arm64DDC.", type: .info, String(serviceMatch.displayID))
            otherDisplay.isDiscouraged = true
          } else if serviceMatch.dummy {
            os_log("Display %{public}@ is flagged as dummy by Arm64DDC.", type: .info, String(serviceMatch.displayID))
            otherDisplay.isDiscouraged = true
            otherDisplay.isDummy = true
          } else {
            otherDisplay.arm64ddc = DEBUG_SW ? false : true // MARK: (point of interest when testing)
          }
        }
      }
      os_log("AVService update done", type: .info)
    }
  }

  func resetSwBrightnessForAllDisplays(prefsOnly: Bool = false, noPrefSave: Bool = false, async: Bool = false) {
    for otherDisplay in self.getLGOtherDisplays() {
      if !prefsOnly {
        _ = otherDisplay.setSwBrightness(1, smooth: async, noPrefSave: noPrefSave)
        if !noPrefSave {
          otherDisplay.smoothBrightnessTransient = 1
        }
      } else if !noPrefSave {
        otherDisplay.savePref(1, key: .SwBrightness)
        otherDisplay.smoothBrightnessTransient = 1
      }
      if otherDisplay.isSw(), !noPrefSave {
        otherDisplay.savePref(1, for: .brightness)
      }
    }
  }

  func restoreSwBrightnessForAllDisplays(async: Bool = false) {
    for otherDisplay in self.getLGOtherDisplays() {
      if (otherDisplay.readPrefAsFloat(for: .brightness) == 0 && !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue)) || (otherDisplay.readPrefAsFloat(for: .brightness) < otherDisplay.combinedBrightnessSwitchingValue() && !prefs.bool(forKey: PrefKey.separateCombinedScale.rawValue) && !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue)) || otherDisplay.isSw() {
        let savedPrefValue = otherDisplay.readPrefAsFloat(key: .SwBrightness)
        if otherDisplay.getSwBrightness() != savedPrefValue {
          OSDUtils.popEmptyOsd(displayID: otherDisplay.identifier, command: Command.brightness) // This will give the user a hint why is the brightness suddenly changes.
        }
        otherDisplay.savePref(otherDisplay.getSwBrightness(), key: .SwBrightness)
        os_log("Restoring sw brightness to %{public}@ on other display %{public}@", type: .info, String(savedPrefValue), String(otherDisplay.identifier))
        _ = otherDisplay.setSwBrightness(savedPrefValue, smooth: async)
        if otherDisplay.isSw(), let slider = otherDisplay.sliderHandler[.brightness] {
          os_log("Restoring sw slider to %{public}@ for other display %{public}@", type: .info, String(savedPrefValue), String(otherDisplay.identifier))
          slider.setValue(savedPrefValue, displayID: otherDisplay.identifier)
        }
      } else {
        _ = otherDisplay.setSwBrightness(1)
      }
    }
  }

  func getAffectedDisplays(isBrightness: Bool = false, isVolume: Bool = false) -> [Display]? {
    var affectedDisplays: [Display]
    let allDisplays = self.getLGDisplays()
    var currentDisplay: Display?
    if isBrightness {
      if prefs.integer(forKey: PrefKey.multiKeyboardBrightness.rawValue) == MultiKeyboardBrightness.allScreens.rawValue {
        affectedDisplays = allDisplays
        return affectedDisplays
      }
      currentDisplay = self.getCurrentLGDisplay(byFocus: prefs.integer(forKey: PrefKey.multiKeyboardBrightness.rawValue) == MultiKeyboardBrightness.focusInsteadOfMouse.rawValue)
    }
    if isVolume {
      if prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.allScreens.rawValue {
        affectedDisplays = allDisplays
        return affectedDisplays
      } else if prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.audioDeviceNameMatching.rawValue {
        return self.audioControlTargetDisplays
      }
      currentDisplay = self.getCurrentLGDisplay(byFocus: false)
    }
    if let currentDisplay = currentDisplay {
      affectedDisplays = [currentDisplay]
      if CGDisplayIsInHWMirrorSet(currentDisplay.identifier) != 0 || CGDisplayIsInMirrorSet(currentDisplay.identifier) != 0, CGDisplayMirrorsDisplay(currentDisplay.identifier) == 0 {
        for display in allDisplays where CGDisplayMirrorsDisplay(display.identifier) == currentDisplay.identifier {
          affectedDisplays.append(display)
        }
      }
    } else {
      affectedDisplays = []
    }
    return affectedDisplays
  }

  static func isDummy(displayID: CGDirectDisplayID) -> Bool {
    let vendorNumber = CGDisplayVendorNumber(displayID)
    let rawName = DisplayManager.getDisplayRawNameByID(displayID: displayID)
    if rawName.lowercased().contains("dummy") || (self.isVirtual(displayID: displayID) && vendorNumber == UInt32(0xF0F0)) {
      os_log("NOTE: Display is a dummy!", type: .info)
      return true
    }
    return false
  }

  static func isVirtual(displayID: CGDirectDisplayID) -> Bool {
    guard let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?) else {
      return false
    }
    let isVirtualDevice = dictionary["kCGDisplayIsVirtualDevice"] as? Bool
    let displayIsAirplay = dictionary["kCGDisplayIsAirPlay"] as? Bool
    return isVirtualDevice ?? displayIsAirplay ?? false
  }

  static func engageMirror() -> Bool {
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineDisplayIDs, &displayCount) == .success, displayCount > 1 else {
      return false
    }
    // Break display mirror if there is any
    var mirrorBreak = false
    var displayConfigRef: CGDisplayConfigRef?
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      if CGDisplayIsInHWMirrorSet(onlineDisplayID) != 0 || CGDisplayIsInMirrorSet(onlineDisplayID) != 0 {
        if mirrorBreak == false {
          CGBeginDisplayConfiguration(&displayConfigRef)
        }
        CGConfigureDisplayMirrorOfDisplay(displayConfigRef, onlineDisplayID, kCGNullDirectDisplay)
        mirrorBreak = true
      }
    }
    if mirrorBreak {
      CGCompleteDisplayConfiguration(displayConfigRef, CGConfigureOption.permanently)
      return true
    }
    // Build display mirror
    var mainDisplayId = kCGNullDirectDisplay
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      if CGDisplayIsBuiltin(onlineDisplayID) == 0, mainDisplayId == kCGNullDirectDisplay {
        mainDisplayId = onlineDisplayID
      }
    }
    guard mainDisplayId != kCGNullDirectDisplay else {
      return false
    }
    CGBeginDisplayConfiguration(&displayConfigRef)
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 && onlineDisplayID != mainDisplayId {
      CGConfigureDisplayMirrorOfDisplay(displayConfigRef, onlineDisplayID, mainDisplayId)
    }
    CGCompleteDisplayConfiguration(displayConfigRef, CGConfigureOption.permanently)
    return true
  }

  static func resolveEffectiveDisplayID(_ displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    var realDisplayID = displayID
    if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
      let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
      if mirroredDisplayID != 0 {
        realDisplayID = mirroredDisplayID
      }
    }
    return realDisplayID
  }

  static func isAppleDisplay(displayID: CGDirectDisplayID) -> Bool {
    if #available(macOS 15.0, *) {
      if CGDisplayVendorNumber(displayID) != 1552, CGSIsHDRSupported(displayID), CGSIsHDREnabled(displayID) {
        return CGDisplayIsBuiltin(displayID) != 0
      }
    }
    var brightness: Float = -1
    let ret = DisplayServicesGetBrightness(displayID, &brightness)
    if ret == 0, brightness >= 0 { // If brightness read appears to be successful using DisplayServices then it should be an Apple display
      return true
    }
    return CGDisplayIsBuiltin(displayID) != 0 // If built-in display, it should be Apple
  }

  static func getByDisplayID(displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { $0.displayID == displayID }
  }

  static func getDisplayRawNameByID(displayID: CGDirectDisplayID) -> String {
    let defaultName = ""
    if let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?),
       let nameList = dictionary["DisplayProductName"] as? [String: String],
       let name = nameList["en_US"] ?? nameList.first?.value
    {
      return name
    }
    if let screen = getByDisplayID(displayID: displayID) {
      return screen.displayName ?? defaultName
    }
    return defaultName
  }

  static func getDisplayNameByID(displayID: CGDirectDisplayID) -> String {
    let defaultName: String = NSLocalizedString("Unknown", comment: "Unknown display name")
    if let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?),
       let nameList = dictionary["DisplayProductName"] as? [String: String],
       var name = nameList[Locale.current.identifier] ?? nameList["en_US"] ?? nameList.first?.value
    {
      if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
        let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
        if mirroredDisplayID != 0,
           let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(mirroredDisplayID)?.takeRetainedValue() as NSDictionary?),
           let nameList = dictionary["DisplayProductName"] as? [String: String],
           let mirroredName = nameList[Locale.current.identifier] ?? nameList["en_US"] ?? nameList.first?.value
        {
          name.append(" | " + mirroredName)
        }
      }
      return name
    }
    if let screen = getByDisplayID(displayID: displayID) {
      return screen.localizedName
    }
    return defaultName
  }
}
