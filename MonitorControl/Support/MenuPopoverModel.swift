import AppKit
import Combine
import Foundation

@available(macOS 10.15, *)
final class MenuPopoverModel: ObservableObject {
  struct DisplaySection: Identifiable {
    let id: CGDirectDisplayID
    let display: Display
    let name: String
    let supportsBrightness: Bool
    let supportsContrast: Bool
    let supportsVolume: Bool
  }

  private struct DisplayCommandKey: Hashable {
    let displayID: CGDirectDisplayID
    let command: Command
  }

  @Published private(set) var displaySections: [DisplaySection] = []
  @Published private(set) var combinedCommands: [Command] = []
  @Published private(set) var sliderMode: MultiSliders = .separate
  @Published private(set) var menuItemStyle: MenuItemStyle = .text
  @Published private(set) var isLGActive: Bool = true
  @Published private(set) var isInLaunchGrace: Bool = false
  @Published private(set) var displayCount: Int = 0

  private var values: [DisplayCommandKey: Float] = [:]
  private var refreshTimer: Timer?
  private var pollingInterval: TimeInterval = 1.0
  private var interactionDepth: Int = 0
  private var observers: [NSObjectProtocol] = []
  private var lastStructureSignature: String?
  private let valueChangeEpsilon: Float = 0.001

  func start() {
    self.refresh()
    self.primeBrightnessFromDisplays()
    self.installObserversIfNeeded()
    self.setPollingInterval(1.0)
  }

  func stop() {
    self.refreshTimer?.invalidate()
    self.refreshTimer = nil
    self.removeObservers()
    self.interactionDepth = 0
  }

  func beginUserInteraction() {
    self.interactionDepth += 1
    if self.interactionDepth == 1 {
      self.setPollingInterval(0.5)
    }
  }

  func endUserInteraction() {
    self.interactionDepth = max(0, self.interactionDepth - 1)
    if self.interactionDepth == 0 {
      self.setPollingInterval(1.0)
    }
  }

  func setSliderMode(_ mode: MultiSliders) {
    let currentMode = MultiSliders(rawValue: prefs.integer(forKey: PrefKey.multiSliders.rawValue)) ?? .separate
    guard currentMode != mode else {
      return
    }
    prefs.set(mode.rawValue, forKey: PrefKey.multiSliders.rawValue)
    self.refresh()
  }

  private func setPollingInterval(_ interval: TimeInterval) {
    guard interval > 0 else {
      return
    }
    guard abs(self.pollingInterval - interval) > 0.0001 || self.refreshTimer == nil else {
      return
    }
    self.pollingInterval = interval
    self.refreshTimer?.invalidate()
    self.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.refresh()
    }
  }

  private func installObserversIfNeeded() {
    guard self.observers.isEmpty else {
      return
    }
    let center = NotificationCenter.default
    self.observers.append(
      center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
        self?.refresh()
      }
    )
    self.observers.append(
      center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
        self?.refresh()
      }
    )
  }

  private func removeObservers() {
    let center = NotificationCenter.default
    for token in self.observers {
      center.removeObserver(token)
    }
    self.observers.removeAll()
  }

  static func hasAnySliders() -> Bool {
    let mode = MultiSliders(rawValue: prefs.integer(forKey: PrefKey.multiSliders.rawValue)) ?? .separate
    var displays = self.buildDisplayList()
    if mode == .relevant {
      // "Relevant" should follow the menu bar / focused display for the popover UX.
      if let currentDisplay = DisplayManager.shared.getCurrentLGDisplay(byFocus: true) {
        let currentId = DisplayManager.resolveEffectiveDisplayID(currentDisplay.identifier)
        displays = displays.filter { DisplayManager.resolveEffectiveDisplayID($0.identifier) == currentId }
      } else {
        displays = []
      }
    }
    return displays.contains { self.supportsAnyCommand(display: $0) }
  }

  // swiftlint:disable cyclomatic_complexity
  func refresh() {
    var displays = Self.buildDisplayList()
    if self.displayCount != displays.count {
      self.displayCount = displays.count
    }
    let currentMode = MultiSliders(rawValue: prefs.integer(forKey: PrefKey.multiSliders.rawValue)) ?? .separate
    if self.sliderMode != currentMode {
      self.sliderMode = currentMode
    }
    let currentStyle = MenuItemStyle(rawValue: prefs.integer(forKey: PrefKey.menuItemStyle.rawValue)) ?? .text
    if self.menuItemStyle != currentStyle {
      self.menuItemStyle = currentStyle
    }
    let active = DisplayManager.shared.isLGActive()
    if self.isLGActive != active {
      self.isLGActive = active
    }
    let inGrace = DisplayManager.shared.isInLaunchMenuGracePeriod()
    if self.isInLaunchGrace != inGrace {
      self.isInLaunchGrace = inGrace
    }

    if !active {
      self.values.removeAll()
      if self.displayCount != 0 {
        self.displayCount = 0
      }
      if !self.displaySections.isEmpty {
        self.displaySections = []
      }
      if !self.combinedCommands.isEmpty {
        self.combinedCommands = []
      }
      self.lastStructureSignature = nil
      return
    }

    var relevantDisplayID: CGDirectDisplayID?
    if currentMode == .relevant, let currentDisplay = DisplayManager.shared.getCurrentLGDisplay(byFocus: true) {
      let currentId = DisplayManager.resolveEffectiveDisplayID(currentDisplay.identifier)
      relevantDisplayID = currentId
      displays = displays.filter { DisplayManager.resolveEffectiveDisplayID($0.identifier) == currentId }
    } else if currentMode == .relevant {
      displays = []
    }

    let signature = Self.structureSignature(displays: displays, mode: currentMode, relevantDisplayID: relevantDisplayID)
    let structureChanged = signature != self.lastStructureSignature
    if structureChanged {
      self.lastStructureSignature = signature
      if currentMode == .combine {
        if !self.displaySections.isEmpty {
          self.displaySections = []
        }
        self.combinedCommands = Self.supportedCommands(for: displays)
      } else {
        self.displaySections = displays.compactMap { display in
          let supportsBrightness = Self.supports(command: .brightness, display: display)
          let supportsContrast = Self.supports(command: .contrast, display: display)
          let supportsVolume = Self.supports(command: .audioSpeakerVolume, display: display)
          guard supportsBrightness || supportsContrast || supportsVolume else {
            return nil
          }
          return DisplaySection(
            id: display.identifier,
            display: display,
            name: Self.displayTitle(display),
            supportsBrightness: supportsBrightness,
            supportsContrast: supportsContrast,
            supportsVolume: supportsVolume
          )
        }
        if !self.combinedCommands.isEmpty {
          self.combinedCommands = []
        }
      }
    }

    var didUpdateValues = false
    for display in displays {
      let brightnessKey = DisplayCommandKey(displayID: display.identifier, command: .brightness)
      let brightnessValue = Self.readValue(for: display, command: .brightness)
      if self.updateValueIfNeeded(brightnessValue, for: brightnessKey) {
        didUpdateValues = true
      }
      if Self.supports(command: .contrast, display: display) {
        let contrastKey = DisplayCommandKey(displayID: display.identifier, command: .contrast)
        let contrastValue = Self.readValue(for: display, command: .contrast)
        if self.updateValueIfNeeded(contrastValue, for: contrastKey) {
          didUpdateValues = true
        }
      }
      if Self.supports(command: .audioSpeakerVolume, display: display) {
        let volumeKey = DisplayCommandKey(displayID: display.identifier, command: .audioSpeakerVolume)
        let volumeValue = Self.readValue(for: display, command: .audioSpeakerVolume)
        if self.updateValueIfNeeded(volumeValue, for: volumeKey) {
          didUpdateValues = true
        }
      }
    }
    if didUpdateValues {
      self.objectWillChange.send()
    }
  }

  // swiftlint:enable cyclomatic_complexity

  private func updateValueIfNeeded(_ newValue: Float, for key: DisplayCommandKey) -> Bool {
    if let existing = self.values[key], abs(existing - newValue) <= self.valueChangeEpsilon {
      return false
    }
    self.values[key] = newValue
    return true
  }

  private func primeBrightnessFromDisplays() {
    let displays = Self.buildDisplayList()
    guard !displays.isEmpty else {
      return
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else {
        return
      }
      var updated = false
      for display in displays {
        guard let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() else {
          continue
        }
        if otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .brightness) {
          continue
        }
        let tries = UInt(max(1, min(otherDisplay.pollingCount, 5)))
        let delay = otherDisplay.readPrefAsBool(key: .longerDelay) ? UInt64(40 * kMillisecondScale) : nil
        if let values = otherDisplay.readDDCValues(for: .brightness, tries: tries, minReplyDelay: delay) {
          if otherDisplay.readPrefAsInt(key: .maxDDCOverride, for: .brightness) > otherDisplay.readPrefAsInt(key: .minDDCOverride, for: .brightness) {
            otherDisplay.savePref(otherDisplay.readPrefAsInt(key: .maxDDCOverride, for: .brightness), key: .maxDDC, for: .brightness)
          } else {
            otherDisplay.savePref(min(Int(values.max), DDC_MAX_DETECT_LIMIT), key: .maxDDC, for: .brightness)
          }
          otherDisplay.processCurrentDDCValue(isReadFromDisplay: true, command: .brightness, firstrun: false, currentDDCValue: values.current)
          otherDisplay.brightnessSyncSourceValue = otherDisplay.readPrefAsFloat(for: .brightness)
          updated = true
        }
      }
      guard updated else {
        return
      }
      DispatchQueue.main.async {
        self.refresh()
      }
    }
  }

  func value(for display: Display, command: Command) -> Float {
    self.values[DisplayCommandKey(displayID: display.identifier, command: command)] ?? Self.readValue(for: display, command: command)
  }

  func combinedValue(for command: Command) -> Float {
    let displays = Self.buildDisplayList().filter { Self.supports(command: command, display: $0) }
    guard !displays.isEmpty else { return 0 }
    let sum = displays.reduce(Float(0)) { $0 + self.value(for: $1, command: command) }
    return sum / Float(displays.count)
  }

  func setValue(_ value: Float, for display: Display, command: Command) {
    let newValue = Self.snappedValue(value)
    Self.applyValue(newValue, to: display, command: command)
    self.values[DisplayCommandKey(displayID: display.identifier, command: command)] = newValue
  }

  func setCombinedValue(_ value: Float, command: Command) {
    let newValue = Self.snappedValue(value)
    for display in Self.buildDisplayList() where Self.supports(command: command, display: display) {
      Self.applyValue(newValue, to: display, command: command)
      self.values[DisplayCommandKey(displayID: display.identifier, command: command)] = newValue
    }
  }

  private static func buildDisplayList() -> [Display] {
    guard DisplayManager.shared.isLGActive() else {
      return []
    }
    var displays = DisplayManager.shared.getLGDisplays()
    displays = DisplayManager.shared.sortDisplaysByFriendlyName(displays)
    return displays.filter { !$0.isDummy }
  }

  private static func supportedCommands(for displays: [Display]) -> [Command] {
    var commands: [Command] = []
    if displays.contains(where: { self.supports(command: .audioSpeakerVolume, display: $0) }) {
      commands.append(.audioSpeakerVolume)
    }
    if displays.contains(where: { self.supports(command: .contrast, display: $0) }) {
      commands.append(.contrast)
    }
    if displays.contains(where: { self.supports(command: .brightness, display: $0) }) {
      commands.append(.brightness)
    }
    return commands
  }

  private static func structureSignature(displays: [Display], mode: MultiSliders, relevantDisplayID: CGDirectDisplayID?) -> String {
    let header = [
      "mode:\(mode.rawValue)",
      "relevant:\(relevantDisplayID ?? 0)",
      "hideApple:\(prefs.bool(forKey: PrefKey.hideAppleFromMenu.rawValue))",
      "hideBrightness:\(prefs.bool(forKey: PrefKey.hideBrightness.rawValue))",
      "hideVolume:\(prefs.bool(forKey: PrefKey.hideVolume.rawValue))",
      "showContrast:\(prefs.bool(forKey: PrefKey.showContrast.rawValue))",
    ].joined(separator: "|")
    let displayParts = displays.map { display -> String in
      let effectiveID = DisplayManager.resolveEffectiveDisplayID(display.identifier)
      let friendly = display.readPrefAsString(key: .friendlyName)
      let isSw = (display as? OtherDisplay)?.isSw() ?? false
      let supportsBrightness = self.supports(command: .brightness, display: display)
      let supportsContrast = self.supports(command: .contrast, display: display)
      let supportsVolume = self.supports(command: .audioSpeakerVolume, display: display)
      return [
        "id:\(display.identifier)",
        "effective:\(effectiveID)",
        "name:\(display.name)",
        "friendly:\(friendly)",
        "dummy:\(display.isDummy)",
        "virtual:\(display.isVirtual)",
        "sw:\(isSw)",
        "b:\(supportsBrightness)",
        "c:\(supportsContrast)",
        "v:\(supportsVolume)",
      ].joined(separator: ",")
    }
    return ([header] + displayParts).joined(separator: "||")
  }

  private static func supportsAnyCommand(display: Display) -> Bool {
    self.supports(command: .audioSpeakerVolume, display: display)
      || self.supports(command: .contrast, display: display)
      || self.supports(command: .brightness, display: display)
  }

  private static func supports(command: Command, display: Display) -> Bool {
    switch command {
    case .audioSpeakerVolume:
      guard !prefs.bool(forKey: PrefKey.hideVolume.rawValue) else { return false }
      guard let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() else { return false }
      return !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume)
    case .contrast:
      guard prefs.bool(forKey: PrefKey.showContrast.rawValue) else { return false }
      guard let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() else { return false }
      return !display.readPrefAsBool(key: .unavailableDDC, for: .contrast)
    case .brightness:
      guard !prefs.bool(forKey: PrefKey.hideBrightness.rawValue) else { return false }
      return !display.readPrefAsBool(key: .unavailableDDC, for: .brightness)
    default:
      return false
    }
  }

  private static func readValue(for display: Display, command: Command) -> Float {
    switch command {
    case .audioSpeakerVolume:
      guard let otherDisplay = display as? OtherDisplay else { return 0 }
      let isMuted = otherDisplay.readPrefAsBool(key: .enableMuteUnmute) && otherDisplay.readPrefAsInt(for: .audioMuteScreenBlank) == 1
      return isMuted ? 0 : otherDisplay.readPrefAsFloat(for: .audioSpeakerVolume)
    case .contrast:
      return display.readPrefAsFloat(for: .contrast)
    case .brightness:
      if let appleDisplay = display as? AppleDisplay {
        return appleDisplay.getAppleBrightness()
      }
      return display.getBrightness()
    default:
      return 0
    }
  }

  private static func applyValue(_ value: Float, to display: Display, command: Command) {
    let clamped = max(0, min(1, value))
    switch command {
    case .brightness:
      _ = display.setBrightness(clamped)
    case .contrast:
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() {
        otherDisplay.writeDDCValues(command: .contrast, value: otherDisplay.convValueToDDC(for: .contrast, from: clamped))
        otherDisplay.savePref(clamped, for: .contrast)
      }
    case .audioSpeakerVolume:
      guard let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() else { return }
      if otherDisplay.readPrefAsBool(key: .enableMuteUnmute) {
        if clamped == 0 {
          otherDisplay.writeDDCValues(command: .audioMuteScreenBlank, value: 1)
          otherDisplay.savePref(1, for: .audioMuteScreenBlank)
        } else if otherDisplay.readPrefAsInt(for: .audioMuteScreenBlank) == 1 {
          otherDisplay.writeDDCValues(command: .audioMuteScreenBlank, value: 2)
          otherDisplay.savePref(2, for: .audioMuteScreenBlank)
        }
      }
      if !otherDisplay.readPrefAsBool(key: .enableMuteUnmute) || clamped != 0 {
        otherDisplay.writeDDCValues(command: .audioSpeakerVolume, value: otherDisplay.convValueToDDC(for: .audioSpeakerVolume, from: clamped))
      }
      otherDisplay.savePref(clamped, for: .audioSpeakerVolume)
    default:
      break
    }
  }

  private static func snappedValue(_ value: Float) -> Float {
    guard prefs.bool(forKey: PrefKey.enableSliderSnap.rawValue) else {
      return value
    }
    let intPercent = Int(value * 100)
    let snapInterval = 25
    let snapThreshold = 3
    let closest = (intPercent + snapInterval / 2) / snapInterval * snapInterval
    if abs(closest - intPercent) <= snapThreshold {
      return Float(closest) / 100
    }
    return value
  }

  private static func displayTitle(_ display: Display) -> String {
    let friendly = display.readPrefAsString(key: .friendlyName)
    return friendly.isEmpty ? display.name : friendly
  }
}
