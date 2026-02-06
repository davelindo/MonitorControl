//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import Foundation
import IOKit
import os.log

class Display: Equatable {
  let identifier: CGDirectDisplayID
  let prefsId: String
  var name: String
  var vendorNumber: UInt32?
  var modelNumber: UInt32?
  var serialNumber: UInt32?
  var smoothBrightnessTransient: Float = 1
  var smoothBrightnessRunning: Bool = false
  var smoothBrightnessSlow: Bool = false
  let swBrightnessSemaphore = DispatchSemaphore(value: 1)

  private static func normalizedPrefsName(_ name: String) -> String {
    name.filter { !$0.isWhitespace }
  }

  private static func stablePrefsName(displayID: CGDirectDisplayID, fallbackName: String) -> String {
    let rawName = DisplayManager.getDisplayRawNameByID(displayID: displayID)
    return rawName.isEmpty ? fallbackName : rawName
  }

  private static func readIORegStringProperty(displayID: CGDirectDisplayID, key: String) -> String? {
    var service: io_service_t = 0
    CGSServiceForDisplayNumber(displayID, &service)
    guard service != 0 else {
      return nil
    }
    defer {
      IOObjectRelease(service)
    }
    guard let unmanaged = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) else {
      return nil
    }
    return unmanaged.takeRetainedValue() as? String
  }

  private static func stablePrefsToken(displayID: CGDirectDisplayID, serialNumber: UInt32?, isVirtual: Bool) -> String {
    if isVirtual {
      return String(serialNumber ?? 9999)
    }

    func sanitizeToken(_ token: String) -> String {
      token.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
    }

    if let edidUUID = self.readIORegStringProperty(displayID: displayID, key: "EDID UUID").map(sanitizeToken), !edidUUID.isEmpty {
      return edidUUID
    }

    if Arm64DDC.isArm64 {
      let matches = Arm64DDC.getServiceMatches(displayIDs: [displayID])
      if let match = matches.first, !match.serviceDetails.edidUUID.isEmpty {
        return sanitizeToken(match.serviceDetails.edidUUID)
      }
    }

    let unitNumber = CGDisplayUnitNumber(displayID)
    if unitNumber != 0, unitNumber != UInt32.max {
      return String(unitNumber)
    }

    if let serialNumber, serialNumber != 0 {
      return String(serialNumber)
    }

    return String(displayID)
  }

  private static func makePrefsId(name: String, vendorNumber: UInt32?, modelNumber: UInt32?, displayID: CGDirectDisplayID, serialNumber: UInt32?, isVirtual: Bool) -> String {
    let normalizedName = self.normalizedPrefsName(name)
    let token = self.stablePrefsToken(displayID: displayID, serialNumber: serialNumber, isVirtual: isVirtual)
    return "(\(normalizedName)\(vendorNumber ?? 0)\(modelNumber ?? 0)@\(token))"
  }

  private static func makeLegacyPrefsId(name: String, vendorNumber: UInt32?, modelNumber: UInt32?, displayID: CGDirectDisplayID, serialNumber: UInt32?, isVirtual: Bool) -> String {
    let normalizedName = self.normalizedPrefsName(name)
    let token = isVirtual ? String(serialNumber ?? 9999) : String(displayID)
    return "(\(normalizedName)\(vendorNumber ?? 0)\(modelNumber ?? 0)@\(token))"
  }

  private static func migratePrefsIfNeeded(vendorNumber: UInt32?, modelNumber: UInt32?, displayID: CGDirectDisplayID, serialNumber: UInt32?, isVirtual _: Bool, to newPrefsId: String) {
    let existing = prefs.dictionaryRepresentation()
    guard !existing.keys.contains(where: { $0.hasSuffix(newPrefsId) }) else {
      return
    }

    let marker = "\(vendorNumber ?? 0)\(modelNumber ?? 0)@"
    var candidates: [String: Int] = [:]
    for key in existing.keys {
      guard key.hasSuffix(")"), let start = key.lastIndex(of: "(") else {
        continue
      }
      let suffix = String(key[start...])
      guard suffix != newPrefsId, suffix.contains(marker) else {
        continue
      }
      candidates[suffix, default: 0] += 1
    }

    guard !candidates.isEmpty else {
      return
    }

    let currentDisplayIDToken = String(displayID)
    let currentSerialToken = serialNumber.map(String.init)
    let unitNumber = CGDisplayUnitNumber(displayID)
    let currentUnitToken = (unitNumber != 0 && unitNumber != UInt32.max) ? String(unitNumber) : nil

    func score(candidate: String) -> Int {
      let keyCount = candidates[candidate, default: 0]
      let touchedKey = PrefKey.isTouched.rawValue + String(Command.brightness.rawValue) + candidate
      let valueKey = PrefKey.value.rawValue + String(Command.brightness.rawValue) + candidate
      let isTouched = (existing[touchedKey] as? Bool) ?? false
      let hasBrightnessValue = existing[valueKey] != nil
      var score = keyCount
      if candidate.contains("@\(currentDisplayIDToken))") {
        score += 2500
      }
      if let currentSerialToken, candidate.contains("@\(currentSerialToken))") {
        score += 2500
      }
      if let currentUnitToken, candidate.contains("@\(currentUnitToken))") {
        score += 2500
      }
      if isTouched {
        score += 5000
      }
      if hasBrightnessValue {
        score += 1000
      }
      return score
    }

    guard let bestCandidate = candidates.keys.max(by: { score(candidate: $0) < score(candidate: $1) }) else {
      return
    }

    var migrated = 0
    for (key, value) in existing where key.hasSuffix(bestCandidate) {
      let newKey = String(key.dropLast(bestCandidate.count)) + newPrefsId
      guard prefs.object(forKey: newKey) == nil else {
        continue
      }
      prefs.set(value, forKey: newKey)
      migrated += 1
    }

    if migrated > 0 {
      os_log("Migrated %{public}@ prefs keys from %{public}@ to %{public}@", type: .info, String(migrated), bestCandidate, newPrefsId)
    }
  }

  static func == (lhs: Display, rhs: Display) -> Bool {
    lhs.identifier == rhs.identifier
  }

  var sliderHandler: [Command: SliderHandler] = [:]
  var brightnessSyncSourceValue: Float = 1
  var isVirtual: Bool = false
  var isDummy: Bool = false

  var defaultGammaTableRed = [CGGammaValue](repeating: 0, count: 256)
  var defaultGammaTableGreen = [CGGammaValue](repeating: 0, count: 256)
  var defaultGammaTableBlue = [CGGammaValue](repeating: 0, count: 256)
  var defaultGammaTableSampleCount: UInt32 = 0
  var defaultGammaTablePeak: Float = 1

  func prefExists(key: PrefKey? = nil, for command: Command? = nil) -> Bool {
    prefs.object(forKey: self.getKey(key: key, for: command)) != nil
  }

  func removePref(key: PrefKey, for command: Command? = nil) {
    prefs.removeObject(forKey: self.getKey(key: key, for: command))
  }

  func savePref<T>(_ value: T, key: PrefKey? = nil, for command: Command? = nil) {
    prefs.set(value, forKey: self.getKey(key: key, for: command))
  }

  func readPrefAsFloat(key: PrefKey? = nil, for command: Command? = nil) -> Float {
    prefs.float(forKey: self.getKey(key: key, for: command))
  }

  func readPrefAsInt(key: PrefKey? = nil, for command: Command? = nil) -> Int {
    prefs.integer(forKey: self.getKey(key: key, for: command))
  }

  func readPrefAsBool(key: PrefKey? = nil, for command: Command? = nil) -> Bool {
    prefs.bool(forKey: self.getKey(key: key, for: command))
  }

  func readPrefAsString(key: PrefKey? = nil, for command: Command? = nil) -> String {
    prefs.string(forKey: self.getKey(key: key, for: command)) ?? ""
  }

  private func getKey(key: PrefKey? = nil, for command: Command? = nil) -> String {
    (key ?? PrefKey.value).rawValue + (command != nil ? String((command ?? Command.none).rawValue) : "") + self.prefsId
  }

  init(_ identifier: CGDirectDisplayID, name: String, vendorNumber: UInt32?, modelNumber: UInt32?, serialNumber: UInt32?, isVirtual: Bool = false, isDummy: Bool = false) {
    self.identifier = identifier
    self.name = name
    self.vendorNumber = vendorNumber
    self.modelNumber = modelNumber
    self.serialNumber = serialNumber
    self.isVirtual = DEBUG_VIRTUAL ? true : isVirtual
    self.isDummy = isDummy
    let prefsName = Display.stablePrefsName(displayID: identifier, fallbackName: name)
    let newPrefsId = Display.makePrefsId(name: prefsName, vendorNumber: vendorNumber, modelNumber: modelNumber, displayID: identifier, serialNumber: serialNumber, isVirtual: self.isVirtual)
    Display.migratePrefsIfNeeded(vendorNumber: vendorNumber, modelNumber: modelNumber, displayID: identifier, serialNumber: serialNumber, isVirtual: self.isVirtual, to: newPrefsId)
    self.prefsId = newPrefsId
    os_log("Display init with prefsIdentifier %{public}@", type: .info, self.prefsId)
    self.swUpdateDefaultGammaTable()
    self.smoothBrightnessTransient = self.getBrightness()
    if self.isVirtual || self.readPrefAsBool(key: PrefKey.avoidGamma), !self.isDummy {
      os_log("Creating or updating shade for display %{public}@", type: .info, String(self.identifier))
      _ = DisplayManager.shared.updateShade(displayID: self.identifier)
    } else {
      os_log("Destroying shade (if exists) for display %{public}@", type: .info, String(self.identifier))
      _ = DisplayManager.shared.destroyShade(displayID: self.identifier)
    }
    self.brightnessSyncSourceValue = self.getBrightness()
  }

  func calcNewBrightness(isUp: Bool, isSmallIncrement: Bool) -> Float {
    var step: Float = (isUp ? 1 : -1) / 16.0
    let delta = step / 4
    if isSmallIncrement {
      step = delta
    }
    return min(max(0, ceil((self.getBrightness() + delta) / step) * step), 1)
  }

  func stepBrightness(isUp: Bool, isSmallIncrement: Bool) {
    guard !self.readPrefAsBool(key: .unavailableDDC, for: .brightness) else {
      return
    }
    let value = self.calcNewBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
    if self.setBrightness(value) {
      OSDUtils.showOsd(displayID: self.identifier, command: .brightness, value: value * 64, maxValue: 64)
      if let slider = self.sliderHandler[.brightness] {
        slider.setValue(value, displayID: self.identifier)
        self.brightnessSyncSourceValue = value
      }
    }
  }

  func setBrightness(_ to: Float = -1, slow: Bool = false) -> Bool {
    if !prefs.bool(forKey: PrefKey.disableSmoothBrightness.rawValue) {
      return self.setSmoothBrightness(to, slow: slow)
    } else {
      return self.setDirectBrightness(to)
    }
  }

  func setSmoothBrightness(_ to: Float = -1, slow: Bool = false) -> Bool {
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      self.savePref(self.smoothBrightnessTransient, for: .brightness)
      self.smoothBrightnessRunning = false
      os_log("Pushing brightness stopped for Display %{public}@ because of sleep or reconfiguration", type: .info, String(self.identifier))
      return false
    }
    if slow {
      self.smoothBrightnessSlow = true
    }
    var stepDivider: Float = 6
    if self.smoothBrightnessSlow {
      stepDivider = 16
    }
    var dontPushAgain = false
    if to != -1 {
      os_log("Pushing brightness towards goal of %{public}@ for Display  %{public}@", type: .info, String(to), String(self.identifier))
      let value = max(min(to, 1), 0)
      self.savePref(value, for: .brightness)
      self.brightnessSyncSourceValue = value
      self.smoothBrightnessSlow = slow
      if self.smoothBrightnessRunning {
        return true
      }
    }
    let brightness = self.readPrefAsFloat(for: .brightness)
    if brightness != self.smoothBrightnessTransient {
      if abs(brightness - self.smoothBrightnessTransient) < 0.01 {
        self.smoothBrightnessTransient = brightness
        os_log("Pushing brightness finished for Display  %{public}@", type: .info, String(self.identifier))
        dontPushAgain = true
        self.smoothBrightnessRunning = false
      } else if brightness > self.smoothBrightnessTransient {
        self.smoothBrightnessTransient += max((brightness - self.smoothBrightnessTransient) / stepDivider, 1 / 100)
      } else {
        self.smoothBrightnessTransient += min((brightness - self.smoothBrightnessTransient) / stepDivider, 1 / 100)
      }
      _ = self.setDirectBrightness(self.smoothBrightnessTransient, transient: true)
      if !dontPushAgain {
        self.smoothBrightnessRunning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
          _ = self.setSmoothBrightness()
        }
      }
    } else {
      os_log("No more need to push brightness for Display  %{public}@ (setting one final time)", type: .info, String(self.identifier))
      _ = self.setDirectBrightness(self.smoothBrightnessTransient, transient: true)
      self.smoothBrightnessRunning = false
    }
    return true
  }

  func setDirectBrightness(_ to: Float, transient: Bool = false) -> Bool {
    let value = max(min(to, 1), 0)
    if self.setSwBrightness(value) {
      if !transient {
        self.savePref(value, for: .brightness)
        self.brightnessSyncSourceValue = value
        self.smoothBrightnessTransient = value
      }
      return true
    }
    return false
  }

  func getBrightness() -> Float {
    if self.prefExists(for: .brightness) {
      return self.readPrefAsFloat(for: .brightness)
    } else {
      return self.getSwBrightness()
    }
  }

  func swUpdateDefaultGammaTable() {
    guard !self.isDummy else {
      return
    }
    CGGetDisplayTransferByTable(self.identifier, 256, &self.defaultGammaTableRed, &self.defaultGammaTableGreen, &self.defaultGammaTableBlue, &self.defaultGammaTableSampleCount)
    let redPeak = self.defaultGammaTableRed.max() ?? 0
    let greenPeak = self.defaultGammaTableGreen.max() ?? 0
    let bluePeak = self.defaultGammaTableBlue.max() ?? 0
    self.defaultGammaTablePeak = max(redPeak, greenPeak, bluePeak)
  }

  func swBrightnessTransform(value: Float, reverse: Bool = false) -> Float {
    let lowTreshold: Float = prefs.bool(forKey: PrefKey.allowZeroSwBrightness.rawValue) ? 0.0 : 0.15
    if !reverse {
      return value * (1 - lowTreshold) + lowTreshold
    } else {
      return (value - lowTreshold) / (1 - lowTreshold)
    }
  }

  func setSwBrightness(_ value: Float, smooth: Bool = false, noPrefSave: Bool = false) -> Bool {
    self.swBrightnessSemaphore.wait()
    let brightnessValue = min(1, value)
    var currentValue = self.readPrefAsFloat(key: .SwBrightness)
    if !noPrefSave {
      self.savePref(brightnessValue, key: .SwBrightness)
    }
    guard !self.isDummy else {
      self.swBrightnessSemaphore.signal()
      return true
    }
    var newValue = brightnessValue
    currentValue = self.swBrightnessTransform(value: currentValue)
    newValue = self.swBrightnessTransform(value: newValue)
    if smooth {
      let usesShade = self.isVirtual || self.readPrefAsBool(key: .avoidGamma)
      let effectiveDisplayID = DisplayManager.resolveEffectiveDisplayID(self.identifier)
      DispatchQueue.global(qos: .userInteractive).async {
        defer { self.swBrightnessSemaphore.signal() }
        for transientValue in stride(from: currentValue, to: newValue, by: 0.005 * (currentValue > newValue ? -1 : 1)) {
          guard app.reconfigureID == 0 else {
            return
          }
          if usesShade {
            _ = DisplayManager.shared.setShadeAlpha(value: 1 - transientValue, displayID: effectiveDisplayID)
          } else {
            let gammaTableRed = self.defaultGammaTableRed.map { $0 * transientValue }
            let gammaTableGreen = self.defaultGammaTableGreen.map { $0 * transientValue }
            let gammaTableBlue = self.defaultGammaTableBlue.map { $0 * transientValue }
            CGSetDisplayTransferByTable(self.identifier, self.defaultGammaTableSampleCount, gammaTableRed, gammaTableGreen, gammaTableBlue)
          }
          Thread.sleep(forTimeInterval: 0.001) // Let's make things quick if not performed in the background
        }
      }
      return true
    } else {
      if self.isVirtual || self.readPrefAsBool(key: .avoidGamma) {
        self.swBrightnessSemaphore.signal()
        return DisplayManager.shared.setShadeAlpha(value: 1 - newValue, displayID: DisplayManager.resolveEffectiveDisplayID(self.identifier))
      } else {
        let gammaTableRed = self.defaultGammaTableRed.map { $0 * newValue }
        let gammaTableGreen = self.defaultGammaTableGreen.map { $0 * newValue }
        let gammaTableBlue = self.defaultGammaTableBlue.map { $0 * newValue }
        DisplayManager.shared.moveGammaActivityEnforcer(displayID: self.identifier)
        CGSetDisplayTransferByTable(self.identifier, self.defaultGammaTableSampleCount, gammaTableRed, gammaTableGreen, gammaTableBlue)
        DisplayManager.shared.enforceGammaActivity()
      }
    }
    self.swBrightnessSemaphore.signal()
    return true
  }

  func getSwBrightness() -> Float {
    guard !self.isDummy else {
      if self.prefExists(key: .SwBrightness) {
        return self.readPrefAsFloat(key: .SwBrightness)
      } else {
        return 1
      }
    }
    self.swBrightnessSemaphore.wait()
    if self.isVirtual || self.readPrefAsBool(key: .avoidGamma) {
      let rawBrightnessValue = 1 - (DisplayManager.shared.getShadeAlpha(displayID: DisplayManager.resolveEffectiveDisplayID(self.identifier)) ?? 1)
      self.swBrightnessSemaphore.signal()
      return self.swBrightnessTransform(value: rawBrightnessValue, reverse: true)
    }
    var gammaTableRed = [CGGammaValue](repeating: 0, count: 256)
    var gammaTableGreen = [CGGammaValue](repeating: 0, count: 256)
    var gammaTableBlue = [CGGammaValue](repeating: 0, count: 256)
    var gammaTableSampleCount: UInt32 = 0
    var brightnessValue: Float = 1
    if CGGetDisplayTransferByTable(self.identifier, 256, &gammaTableRed, &gammaTableGreen, &gammaTableBlue, &gammaTableSampleCount) == CGError.success {
      let redPeak = gammaTableRed.max() ?? 0
      let greenPeak = gammaTableGreen.max() ?? 0
      let bluePeak = gammaTableBlue.max() ?? 0
      let gammaTablePeak = max(redPeak, greenPeak, bluePeak)
      let peakRatio = gammaTablePeak / self.defaultGammaTablePeak
      brightnessValue = round(self.swBrightnessTransform(value: peakRatio, reverse: true) * 256) / 256
    }
    self.swBrightnessSemaphore.signal()
    return brightnessValue
  }

  func checkGammaInterference() {
    let currentSwBrightness = self.getSwBrightness()
    guard !self.isDummy, !DisplayManager.shared.gammaInterferenceWarningShown, !(prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue)), !self.readPrefAsBool(key: .avoidGamma), !self.isVirtual, !self.smoothBrightnessRunning, self.prefExists(key: .SwBrightness), abs(currentSwBrightness - self.readPrefAsFloat(key: .SwBrightness)) > 0.02 else {
      return
    }
    DisplayManager.shared.gammaInterferenceCounter += 1
    _ = self.setSwBrightness(1)
    os_log("Gamma table interference detected, number of events: %{public}@", type: .info, String(DisplayManager.shared.gammaInterferenceCounter))
    if DisplayManager.shared.gammaInterferenceCounter >= 3 {
      DisplayManager.shared.gammaInterferenceWarningShown = true
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Is f.lux or similar running?", comment: "Shown in the alert dialog")
      alert.informativeText = NSLocalizedString("An other app seems to change the brightness or colors which causes issues.\n\nTo solve this, you need to quit the other app or disable gamma control for your displays in MonitorControl!", comment: "Shown in the alert dialog")
      alert.addButton(withTitle: NSLocalizedString("I'll quit the other app", comment: "Shown in the alert dialog"))
      alert.addButton(withTitle: NSLocalizedString("Disable gamma control for my displays", comment: "Shown in the alert dialog"))
      alert.alertStyle = NSAlert.Style.critical
      if alert.runModal() != .alertFirstButtonReturn {
        for otherDisplay in DisplayManager.shared.getLGOtherDisplays() {
          _ = otherDisplay.setSwBrightness(1)
          _ = otherDisplay.setDirectBrightness(1)
          otherDisplay.savePref(true, key: .avoidGamma)
          _ = otherDisplay.setSwBrightness(1)
          DisplayManager.shared.gammaInterferenceWarningShown = false
          DisplayManager.shared.gammaInterferenceCounter = 0
          displaysPrefsVc?.loadDisplayList()
        }
      } else {
        os_log("We won't watch for gamma table interference anymore", type: .info)
      }
    }
  }

  func resetSwBrightness() -> Bool {
    self.setSwBrightness(1)
  }

  func isSwBrightnessNotDefault() -> Bool {
    guard !self.isVirtual, !self.isDummy else {
      return false
    }
    if self.getSwBrightness() < 1 {
      return true
    }
    return false
  }

  func refreshBrightness() -> Float {
    0
  }

  func isBuiltIn() -> Bool {
    if CGDisplayIsBuiltin(self.identifier) != 0 {
      return true
    } else {
      return false
    }
  }
}
