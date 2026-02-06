// swiftlint:disable file_length

import AppKit
import Combine
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

@available(macOS 13.0, *)
final class PreferencesWindowController: NSWindowController {
  init() {
    let rootView = PreferencesRootView()
    let hostingController = NSHostingController(rootView: rootView)
    let window = NSWindow(contentViewController: hostingController)
    window.title = NSLocalizedString("Settings", comment: "Preferences window title")
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]

    // Clamp to the current screen so the window can't open off-screen on small displays.
    // Note: `setContentSize` takes content size, but `minSize` is a *frame* size.
    let desiredContentSize = NSSize(width: 980, height: 620)
    let desiredMinContentSize = NSSize(width: 680, height: 520)

    let screen = NSScreen.main ?? NSScreen.screens.first
    let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
    let maxFrameSize = NSSize(
      width: max(520, visibleFrame.size.width - 80),
      height: max(420, visibleFrame.size.height - 120)
    )

    let desiredFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: desiredContentSize)).size
    let clampedFrameSize = NSSize(
      width: min(desiredFrameSize.width, maxFrameSize.width),
      height: min(desiredFrameSize.height, maxFrameSize.height)
    )
    let clampedContentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: clampedFrameSize)).size
    window.setContentSize(clampedContentSize)

    let desiredMinFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: desiredMinContentSize)).size
    window.minSize = NSSize(
      width: min(desiredMinFrameSize.width, maxFrameSize.width),
      height: min(desiredMinFrameSize.height, maxFrameSize.height)
    )
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    nil
  }

  func show() {
    if let window = self.window {
      let mouseLocation = NSEvent.mouseLocation
      let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? window.screen ?? NSScreen.main
      if let targetScreen {
        let constrainedFrame = window.constrainFrameRect(window.frame, to: targetScreen)
        window.setFrame(constrainedFrame, display: false)
      }
    }
    self.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

@available(macOS 13.0, *)
private enum PreferencesPane: String, CaseIterable, Identifiable {
  case main
  case menusliders
  case keyboard
  case displays
  case about

  var id: String {
    self.rawValue
  }

  var title: String {
    switch self {
    case .main:
      return NSLocalizedString("General", comment: "Preferences pane title")
    case .menusliders:
      return NSLocalizedString("App menu", comment: "Preferences pane title")
    case .keyboard:
      return NSLocalizedString("Keyboard", comment: "Preferences pane title")
    case .displays:
      return NSLocalizedString("Displays", comment: "Preferences pane title")
    case .about:
      return NSLocalizedString("About", comment: "Preferences pane title")
    }
  }

  var icon: String {
    switch self {
    case .main: return "switch.2"
    case .menusliders: return "filemenu.and.cursorarrow"
    case .keyboard: return "keyboard"
    case .displays: return "display.2"
    case .about: return "info.circle"
    }
  }
}

@available(macOS 13.0, *)
private struct PreferencesRootView: View {
  @State private var selection: PreferencesPane = .main

  var body: some View {
    NavigationSplitView {
      List(PreferencesPane.allCases, selection: self.$selection) { pane in
        Label(pane.title, systemImage: pane.icon)
          .tag(pane)
      }
      .listStyle(.sidebar)
      .frame(minWidth: 190)
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
    } detail: {
      PreferencesPaneView(pane: self.selection)
        .navigationTitle(self.selection.title)
    }
  }
}

@available(macOS 13.0, *)
private struct PreferencesPaneView: View {
  let pane: PreferencesPane

  var body: some View {
    switch self.pane {
    case .main:
      GeneralSettingsView()
    case .menusliders:
      MenuSettingsView()
    case .keyboard:
      KeyboardSettingsView()
    case .displays:
      DisplaysSettingsView()
    case .about:
      AboutSettingsView()
    }
  }
}

@available(macOS 13.0, *)
private final class PrefsObserver: ObservableObject {
  private var token: NSObjectProtocol?

  init() {
    self.token = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: prefs,
      queue: .main
    ) { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  deinit {
    if let token = self.token {
      NotificationCenter.default.removeObserver(token)
    }
  }
}

@available(macOS 13.0, *)
private enum StartAtLogin {
  static func isEnabled() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else {
      return false
    }
    let helperLabel = "\(bundleID)Helper"
    let jobs = (SMCopyAllJobDictionaries(kSMDomainUserLaunchd).takeRetainedValue() as? [[String: AnyObject]]) ?? []
    return jobs.first(where: { $0["Label"] as? String == helperLabel })?["OnDemand"] as? Bool ?? false
  }
}

// MARK: - General

@available(macOS 13.0, *)
private struct GeneralSettingsView: View {
  @StateObject private var prefsObserver = PrefsObserver()

  @State private var startAtLoginEnabled: Bool = false
  @State private var showingResetConfirmation: Bool = false

  @AppStorage(PrefKey.SUEnableAutomaticChecks.rawValue) private var automaticallyCheckForUpdates: Bool = true
  @AppStorage(PrefKey.disableCombinedBrightness.rawValue) private var disableCombinedBrightness: Bool = false
  @AppStorage(PrefKey.allowZeroSwBrightness.rawValue) private var allowZeroSwBrightness: Bool = false
  @AppStorage(PrefKey.disableSmoothBrightness.rawValue) private var disableSmoothBrightness: Bool = false
  @AppStorage(PrefKey.enableBrightnessSync.rawValue) private var enableBrightnessSync: Bool = false
  @AppStorage(PrefKey.startupAction.rawValue) private var startupActionRaw: Int = StartupAction.doNothing.rawValue
  @AppStorage(PrefKey.dynamicBrightnessEnabled.rawValue) private var dynamicBrightnessEnabled: Bool = false

  var body: some View {
    // Force refresh on UserDefaults changes for bindings that read `prefs` directly.
    _ = self.prefsObserver

    return Form {
      Section {
        Toggle(NSLocalizedString("Start at Login", comment: "General preference"), isOn: Binding(
          get: { self.startAtLoginEnabled },
          set: { newValue in
            self.startAtLoginEnabled = newValue
            app.setStartAtLogin(enabled: newValue)
          }
        ))

        Toggle(NSLocalizedString("Automatically check for updates", comment: "General preference"), isOn: self.$automaticallyCheckForUpdates)
      }

      Section {
        Toggle(NSLocalizedString("Enable smooth brightness transitions", comment: "General preference"), isOn: Binding(
          get: { !self.disableSmoothBrightness },
          set: { self.disableSmoothBrightness = !$0 }
        ))
        Text(NSLocalizedString("You can disable smooth transitions for a more direct, immediate control.", comment: "General preference help"))
          .font(.caption)
          .foregroundColor(.secondary)

        Toggle(NSLocalizedString("Combine hardware and software dimming", comment: "General preference"), isOn: self.combinedBrightnessBinding)
        Text(NSLocalizedString("Use software dimming after the display reached zero hardware brightness for extended range. Works for DDC controlled displays only.", comment: "General preference help"))
          .font(.caption)
          .foregroundColor(.secondary)

        Toggle(NSLocalizedString("Sync brightness changes from Built-in and Apple displays", comment: "General preference"), isOn: self.$enableBrightnessSync)
          .disabled(!DisplayManager.shared.isBuiltInDisplayActive())
        Text(NSLocalizedString("Changes that are caused by the Ambient light sensor or made using Touch Bar, Control Center, System Settings will be replicated to all displays.", comment: "General preference help"))
          .font(.caption)
          .foregroundColor(.secondary)

        Toggle(NSLocalizedString("Allow zero brightness via software or combined dimming", comment: "General preference"), isOn: self.allowZeroBrightnessBinding)
        Text(NSLocalizedString("Warning! With this option enabled, you might find yourself in a position when you end up with a blank display. This, combined with disabled keyboard controls can be frustrating.", comment: "General preference help"))
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section {
        Picker(NSLocalizedString("Upon startup or wake:", comment: "General preference"), selection: self.$startupActionRaw) {
          Text(NSLocalizedString("Do nothing", comment: "General preference")).tag(StartupAction.doNothing.rawValue)
          Text(NSLocalizedString("Assume last saved settings are valid (recommended)", comment: "General preference")).tag(StartupAction.write.rawValue)
          Text(NSLocalizedString("Read current display values", comment: "General preference")).tag(StartupAction.read.rawValue)
        }
        .pickerStyle(.menu)

        Toggle(
          NSLocalizedString("Hide menu bar item when no LG display is connected", comment: "General preference"),
          isOn: self.autoHideWhenNoLGBinding
        )
        .onChange(of: self.autoHideWhenNoLGBinding.wrappedValue) { _ in
          // Binding setter already calls configure; keep this to ensure the row always refreshes.
        }

        Toggle(
          NSLocalizedString("Enable dynamic brightness (ambient + location fallback)", comment: "General preference"),
          isOn: self.$dynamicBrightnessEnabled
        )
        .onChange(of: self.dynamicBrightnessEnabled) { _ in
          DynamicBrightnessManager.shared.updateEnabledState()
        }
      }

      Section {
        Button(NSLocalizedString("Reset Settings", comment: "General preference")) {
          self.showingResetConfirmation = true
        }
        .buttonStyle(.borderedProminent)
        .tint(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      self.startAtLoginEnabled = StartAtLogin.isEnabled()
    }
    .alert(
      NSLocalizedString("Reset Settings?", comment: "Shown in the alert dialog"),
      isPresented: self.$showingResetConfirmation
    ) {
      Button(NSLocalizedString("Yes", comment: "Shown in the alert dialog")) {
        app.settingsReset()
        self.startAtLoginEnabled = StartAtLogin.isEnabled()
      }
      Button(NSLocalizedString("No", comment: "Shown in the alert dialog")) {}
    } message: {
      Text(NSLocalizedString("Are you sure you want to reset all settings?", comment: "Shown in the alert dialog"))
    }
  }

  private var combinedBrightnessBinding: Binding<Bool> {
    Binding(
      get: { !self.disableCombinedBrightness },
      set: { newValue in
        for display in DisplayManager.shared.getDdcCapableDisplays() where !display.isSw() {
          _ = display.setDirectBrightness(1)
        }
        DisplayManager.shared.resetSwBrightnessForAllDisplays(async: false)
        self.disableCombinedBrightness = !newValue
        app.configure()
      }
    )
  }

  private var allowZeroBrightnessBinding: Binding<Bool> {
    Binding(
      get: { self.allowZeroSwBrightness },
      set: { newValue in
        self.allowZeroSwBrightness = newValue
        for display in DisplayManager.shared.getLGOtherDisplays() {
          _ = display.setDirectBrightness(1)
          _ = display.setSwBrightness(1)
        }
        app.configure()
      }
    )
  }

  private var autoHideWhenNoLGBinding: Binding<Bool> {
    Binding(
      get: {
        if prefs.object(forKey: PrefKey.autoHideWhenNoLG.rawValue) == nil {
          return true
        }
        return prefs.bool(forKey: PrefKey.autoHideWhenNoLG.rawValue)
      },
      set: { newValue in
        prefs.set(newValue, forKey: PrefKey.autoHideWhenNoLG.rawValue)
        app.configure()
      }
    )
  }
}

// MARK: - App Menu

@available(macOS 13.0, *)
private struct MenuSettingsView: View {
  @StateObject private var prefsObserver = PrefsObserver()

  @AppStorage(PrefKey.menuIcon.rawValue) private var menuIconRaw: Int = MenuIcon.show.rawValue
  @AppStorage(PrefKey.menuItemStyle.rawValue) private var menuItemStyleRaw: Int = MenuItemStyle.icon.rawValue
  @AppStorage(PrefKey.hideBrightness.rawValue) private var hideBrightness: Bool = false
  @AppStorage(PrefKey.hideAppleFromMenu.rawValue) private var hideAppleFromMenu: Bool = false
  @AppStorage(PrefKey.hideVolume.rawValue) private var hideVolume: Bool = false
  @AppStorage(PrefKey.showContrast.rawValue) private var showContrast: Bool = false
  @AppStorage(PrefKey.multiSliders.rawValue) private var multiSlidersRaw: Int = MultiSliders.separate.rawValue
  @AppStorage(PrefKey.enableSliderSnap.rawValue) private var enableSliderSnap: Bool = false
  @AppStorage(PrefKey.showTickMarks.rawValue) private var showTickMarks: Bool = false
  @AppStorage(PrefKey.enableSliderPercent.rawValue) private var enableSliderPercent: Bool = false

  var body: some View {
    _ = self.prefsObserver

    return Form {
      Section {
        Picker(NSLocalizedString("Menu bar icon", comment: "Menu preference"), selection: self.$menuIconRaw) {
          Text(NSLocalizedString("Show", comment: "Menu preference")).tag(MenuIcon.show.rawValue)
          Text(NSLocalizedString("Sliders only", comment: "Menu preference")).tag(MenuIcon.sliderOnly.rawValue)
          Text(NSLocalizedString("Hide", comment: "Menu preference")).tag(MenuIcon.hide.rawValue)
          Text(NSLocalizedString("External displays only", comment: "Menu preference")).tag(MenuIcon.externalOnly.rawValue)
        }
        .pickerStyle(.menu)

        Picker(NSLocalizedString("Menu actions", comment: "Menu preference"), selection: self.$menuItemStyleRaw) {
          Text(NSLocalizedString("Icons", comment: "Menu preference")).tag(MenuItemStyle.icon.rawValue)
          Text(NSLocalizedString("Text", comment: "Menu preference")).tag(MenuItemStyle.text.rawValue)
          Text(NSLocalizedString("Hidden", comment: "Menu preference")).tag(MenuItemStyle.hide.rawValue)
        }
        .pickerStyle(.menu)
      }

      Section {
        Toggle(NSLocalizedString("Brightness slider", comment: "Menu preference"), isOn: self.showBrightnessBinding)
        Toggle(NSLocalizedString("Apple displays", comment: "Menu preference"), isOn: self.showAppleFromMenuBinding)
          .disabled(self.hideBrightness)

        Toggle(NSLocalizedString("Volume slider", comment: "Menu preference"), isOn: self.showVolumeBinding)
        Toggle(NSLocalizedString("Contrast slider", comment: "Menu preference"), isOn: self.$showContrast)
      }

      Section {
        Picker(NSLocalizedString("Multi-display sliders", comment: "Menu preference"), selection: self.$multiSlidersRaw) {
          Text(NSLocalizedString("Each display", comment: "Menu preference")).tag(MultiSliders.separate.rawValue)
          Text(NSLocalizedString("Menu bar display", comment: "Menu preference")).tag(MultiSliders.relevant.rawValue)
          Text(NSLocalizedString("All displays", comment: "Menu preference")).tag(MultiSliders.combine.rawValue)
        }
        .pickerStyle(.segmented)

        Toggle(NSLocalizedString("Snap slider values", comment: "Menu preference"), isOn: self.$enableSliderSnap)
        Toggle(NSLocalizedString("Show tick marks", comment: "Menu preference"), isOn: self.$showTickMarks)
        Toggle(NSLocalizedString("Show percentages", comment: "Menu preference"), isOn: self.$enableSliderPercent)
      }
    }
    .formStyle(.grouped)
    .onChange(of: self.menuIconRaw) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.menuItemStyleRaw) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.hideBrightness) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.hideAppleFromMenu) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.hideVolume) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.showContrast) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.multiSlidersRaw) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.enableSliderSnap) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.showTickMarks) { _ in app.updateMenusAndKeys() }
    .onChange(of: self.enableSliderPercent) { _ in app.updateMenusAndKeys() }
  }

  private var showBrightnessBinding: Binding<Bool> {
    Binding(
      get: { !self.hideBrightness },
      set: { newValue in
        self.hideBrightness = !newValue
      }
    )
  }

  private var showAppleFromMenuBinding: Binding<Bool> {
    Binding(
      get: { !self.hideAppleFromMenu },
      set: { newValue in
        self.hideAppleFromMenu = !newValue
      }
    )
  }

  private var showVolumeBinding: Binding<Bool> {
    Binding(
      get: { !self.hideVolume },
      set: { newValue in
        self.hideVolume = !newValue
      }
    )
  }
}

// MARK: - Keyboard

@available(macOS 13.0, *)
private struct KeyboardSettingsView: View {
  @StateObject private var prefsObserver = PrefsObserver()

  @AppStorage(PrefKey.keyboardBrightness.rawValue) private var keyboardBrightnessRaw: Int = KeyboardBrightness.media.rawValue
  @AppStorage(PrefKey.keyboardVolume.rawValue) private var keyboardVolumeRaw: Int = KeyboardVolume.media.rawValue
  @AppStorage(PrefKey.disableAltBrightnessKeys.rawValue) private var disableAltBrightnessKeys: Bool = false

  @AppStorage(PrefKey.multiKeyboardBrightness.rawValue) private var multiKeyboardBrightnessRaw: Int = MultiKeyboardBrightness.mouse.rawValue
  @AppStorage(PrefKey.multiKeyboardVolume.rawValue) private var multiKeyboardVolumeRaw: Int = MultiKeyboardVolume.mouse.rawValue

  @AppStorage(PrefKey.useFineScaleBrightness.rawValue) private var useFineScaleBrightness: Bool = false
  @AppStorage(PrefKey.useFineScaleVolume.rawValue) private var useFineScaleVolume: Bool = false
  @AppStorage(PrefKey.separateCombinedScale.rawValue) private var separateCombinedScale: Bool = false

  var body: some View {
    _ = self.prefsObserver

    return Form {
      Section {
        Picker(NSLocalizedString("Brightness keys", comment: "Keyboard preference"), selection: self.$keyboardBrightnessRaw) {
          Text(NSLocalizedString("Media keys", comment: "Keyboard preference")).tag(KeyboardBrightness.media.rawValue)
          Text(NSLocalizedString("Custom shortcuts", comment: "Keyboard preference")).tag(KeyboardBrightness.custom.rawValue)
          Text(NSLocalizedString("Both", comment: "Keyboard preference")).tag(KeyboardBrightness.both.rawValue)
          Text(NSLocalizedString("Disabled", comment: "Keyboard preference")).tag(KeyboardBrightness.disabled.rawValue)
        }
        .pickerStyle(.menu)

        Toggle(NSLocalizedString("Disable alternate brightness keys (F14/F15)", comment: "Keyboard preference"), isOn: self.$disableAltBrightnessKeys)
          .disabled(self.keyboardBrightnessRaw == KeyboardBrightness.disabled.rawValue)

        if self.keyboardBrightnessRaw == KeyboardBrightness.custom.rawValue || self.keyboardBrightnessRaw == KeyboardBrightness.both.rawValue {
          VStack(alignment: .leading, spacing: 10) {
            ShortcutRecorderRow(title: NSLocalizedString("Brightness up", comment: "Keyboard shortcut"), name: .brightnessUp, placeholder: NSLocalizedString("Increase", comment: "Shown in record shortcut box"))
            ShortcutRecorderRow(title: NSLocalizedString("Brightness down", comment: "Keyboard shortcut"), name: .brightnessDown, placeholder: NSLocalizedString("Decrease", comment: "Shown in record shortcut box"))
            ShortcutRecorderRow(title: NSLocalizedString("Contrast up", comment: "Keyboard shortcut"), name: .contrastUp, placeholder: NSLocalizedString("Increase", comment: "Shown in record shortcut box"))
            ShortcutRecorderRow(title: NSLocalizedString("Contrast down", comment: "Keyboard shortcut"), name: .contrastDown, placeholder: NSLocalizedString("Decrease", comment: "Shown in record shortcut box"))
          }
          .padding(.top, 6)
        }
      }

      Section {
        Picker(NSLocalizedString("Volume keys", comment: "Keyboard preference"), selection: self.$keyboardVolumeRaw) {
          Text(NSLocalizedString("Media keys", comment: "Keyboard preference")).tag(KeyboardVolume.media.rawValue)
          Text(NSLocalizedString("Custom shortcuts", comment: "Keyboard preference")).tag(KeyboardVolume.custom.rawValue)
          Text(NSLocalizedString("Both", comment: "Keyboard preference")).tag(KeyboardVolume.both.rawValue)
          Text(NSLocalizedString("Disabled", comment: "Keyboard preference")).tag(KeyboardVolume.disabled.rawValue)
        }
        .pickerStyle(.menu)

        if self.keyboardVolumeRaw == KeyboardVolume.custom.rawValue || self.keyboardVolumeRaw == KeyboardVolume.both.rawValue {
          VStack(alignment: .leading, spacing: 10) {
            ShortcutRecorderRow(title: NSLocalizedString("Volume up", comment: "Keyboard shortcut"), name: .volumeUp, placeholder: NSLocalizedString("Increase", comment: "Shown in record shortcut box"))
            ShortcutRecorderRow(title: NSLocalizedString("Volume down", comment: "Keyboard shortcut"), name: .volumeDown, placeholder: NSLocalizedString("Decrease", comment: "Shown in record shortcut box"))
            ShortcutRecorderRow(title: NSLocalizedString("Mute", comment: "Keyboard shortcut"), name: .mute, placeholder: NSLocalizedString("Mute", comment: "Shown in record shortcut box"))
          }
          .padding(.top, 6)
        }
      }

      Section {
        Picker(NSLocalizedString("Brightness target", comment: "Keyboard preference"), selection: self.$multiKeyboardBrightnessRaw) {
          Text(NSLocalizedString("Display under cursor", comment: "Keyboard preference")).tag(MultiKeyboardBrightness.mouse.rawValue)
          Text(NSLocalizedString("All screens", comment: "Keyboard preference")).tag(MultiKeyboardBrightness.allScreens.rawValue)
          Text(NSLocalizedString("Focused display", comment: "Keyboard preference")).tag(MultiKeyboardBrightness.focusInsteadOfMouse.rawValue)
        }
        .pickerStyle(.menu)
        .disabled(self.keyboardBrightnessRaw == KeyboardBrightness.disabled.rawValue)

        if self.multiKeyboardBrightnessRaw == MultiKeyboardBrightness.focusInsteadOfMouse.rawValue {
          Text(NSLocalizedString("Brightness keys will affect the display with keyboard focus (if available).", comment: "Keyboard preference help"))
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Toggle(NSLocalizedString("Use fine scale for brightness OSD", comment: "Keyboard preference"), isOn: self.$useFineScaleBrightness)
          .disabled(self.keyboardBrightnessRaw == KeyboardBrightness.disabled.rawValue)

        Toggle(NSLocalizedString("Use separate combined scale", comment: "Keyboard preference"), isOn: self.$separateCombinedScale)
          .disabled(self.keyboardBrightnessRaw == KeyboardBrightness.disabled.rawValue)

        Picker(NSLocalizedString("Volume target", comment: "Keyboard preference"), selection: self.$multiKeyboardVolumeRaw) {
          Text(NSLocalizedString("Display under cursor", comment: "Keyboard preference")).tag(MultiKeyboardVolume.mouse.rawValue)
          Text(NSLocalizedString("All screens", comment: "Keyboard preference")).tag(MultiKeyboardVolume.allScreens.rawValue)
          Text(NSLocalizedString("Match audio device name", comment: "Keyboard preference")).tag(MultiKeyboardVolume.audioDeviceNameMatching.rawValue)
        }
        .pickerStyle(.menu)
        .disabled(self.keyboardVolumeRaw == KeyboardVolume.disabled.rawValue)

        if self.multiKeyboardVolumeRaw == MultiKeyboardVolume.audioDeviceNameMatching.rawValue {
          Text(NSLocalizedString("Volume keys will control displays whose audio device name matches the current output device.", comment: "Keyboard preference help"))
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
          Text(NSLocalizedString("Volume keys will affect the display under the cursor.", comment: "Keyboard preference help"))
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Toggle(NSLocalizedString("Use fine scale for volume OSD", comment: "Keyboard preference"), isOn: self.$useFineScaleVolume)
          .disabled(self.keyboardVolumeRaw == KeyboardVolume.disabled.rawValue)
      }
    }
    .formStyle(.grouped)
    .onChange(of: self.keyboardBrightnessRaw) { _ in
      app.updateMenusAndKeys()
    }
    .onChange(of: self.keyboardVolumeRaw) { _ in
      app.updateMenusAndKeys()
    }
    .onChange(of: self.disableAltBrightnessKeys) { _ in
      app.updateMediaKeyTap()
    }
    .onChange(of: self.multiKeyboardBrightnessRaw) { _ in
      app.updateMediaKeyTap()
    }
    .onChange(of: self.multiKeyboardVolumeRaw) { _ in
      app.updateMediaKeyTap()
    }
    .onChange(of: self.useFineScaleBrightness) { _ in
      // OSD behavior; no immediate reconfigure needed.
    }
    .onChange(of: self.useFineScaleVolume) { _ in
      // OSD behavior; no immediate reconfigure needed.
    }
    .onChange(of: self.separateCombinedScale) { _ in
      // Affects OSD and brightness mapping.
    }
  }
}

@available(macOS 13.0, *)
private struct ShortcutRecorderRow: View {
  let title: String
  let name: KeyboardShortcuts.Name
  let placeholder: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(self.title)
        .frame(width: 160, alignment: .leading)
      ShortcutRecorder(name: self.name, placeholder: self.placeholder)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

@available(macOS 13.0, *)
private struct ShortcutRecorder: NSViewRepresentable {
  let name: KeyboardShortcuts.Name
  let placeholder: String

  func makeNSView(context _: Context) -> NSView {
    let recorder = KeyboardShortcuts.RecorderCocoa(for: self.name)
    recorder.placeholderString = self.placeholder
    return recorder
  }

  func updateNSView(_ nsView: NSView, context _: Context) {
    if let recorder = nsView as? KeyboardShortcuts.RecorderCocoa {
      recorder.placeholderString = self.placeholder
    }
  }
}

// MARK: - Displays

@available(macOS 13.0, *)
@MainActor
private final class DisplaysSettingsModel: ObservableObject {
  @Published var displays: [Display] = []
  private var tokens: [NSObjectProtocol] = []

  func start() {
    self.refresh()
    guard self.tokens.isEmpty else { return }
    self.tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.refresh()
        }
      }
    )
  }

  func stop() {
    for token in self.tokens {
      NotificationCenter.default.removeObserver(token)
    }
    self.tokens.removeAll()
  }

  func refresh() {
    self.displays = DisplayManager.shared.getAllDisplays()
  }
}

@available(macOS 13.0, *)
private struct DisplaysSettingsView: View {
  @StateObject private var prefsObserver = PrefsObserver()
  @StateObject private var model = DisplaysSettingsModel()

  @AppStorage(PrefKey.showAdvancedSettings.rawValue) private var showAdvancedSettings: Bool = false

  var body: some View {
    _ = self.prefsObserver

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox {
          Toggle(NSLocalizedString("Show advanced settings", comment: "Displays preference"), isOn: self.$showAdvancedSettings)
            .toggleStyle(.switch)
          Text(NSLocalizedString("Advanced settings may cause system freezes or unexpected behavior.", comment: "Displays preference help"))
            .font(.caption)
            .foregroundColor(.secondary)
        }

        ForEach(self.model.displays, id: \.identifier) { display in
          DisplaySettingsCard(display: display, showAdvanced: self.showAdvancedSettings) {
            self.model.refresh()
          }
        }
      }
      .padding(20)
    }
    .onAppear { self.model.start() }
    .onDisappear { self.model.stop() }
  }
}

@available(macOS 13.0, *)
private struct DisplaySettingsCard: View {
  let display: Display
  let showAdvanced: Bool
  let onRefresh: () -> Void

  @State private var isAdvancedExpanded: Bool = false
  @State private var pendingLongerDelayDisplayID: CGDirectDisplayID?
  @State private var showingResetConfirmation: Bool = false

  var body: some View {
    let displayInfo = DisplaysPrefsViewController.getDisplayInfo(display: self.display)
    let title = self.friendlyNameOrSystemName

    return GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField(NSLocalizedString("Name", comment: "Displays preference"), text: self.friendlyNameBinding)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 420)
            Spacer()
            Text("ID \(self.display.identifier)")
              .font(.caption)
              .foregroundColor(.secondary)
              .monospacedDigit()
          }

          HStack(spacing: 8) {
            Text(displayInfo.displayType)
              .font(.caption)
              .foregroundColor(.secondary)
            Text("•")
              .font(.caption)
              .foregroundColor(.secondary)
            Text(displayInfo.controlMethod)
              .font(.caption)
              .foregroundColor(.secondary)
              .help(displayInfo.controlStatus)
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
          Toggle(NSLocalizedString("Enable keyboard control for display", comment: "Displays preference"), isOn: self.enabledBinding)
          Toggle(NSLocalizedString("Use hardware DDC control", comment: "Displays preference"), isOn: self.ddcBinding)
            .disabled(!self.canToggleDDC)
          Toggle(NSLocalizedString("Avoid gamma table manipulation", comment: "Displays preference"), isOn: self.avoidGammaBinding)
            .disabled(!self.canToggleAvoidGamma)
          Toggle(NSLocalizedString("Disable macOS volume OSD", comment: "Displays preference"), isOn: self.disableVolumeOSDBinding)
            .disabled(!self.canToggleVolumeOSD)
        }

        if self.showAdvanced {
          Divider()
          DisclosureGroup(isExpanded: self.$isAdvancedExpanded) {
            self.advancedContent
          } label: {
            Text(NSLocalizedString("Advanced", comment: "Displays preference"))
          }
        }
      }
      .padding(.vertical, 4)
    } label: {
      Label(title, systemImage: displayInfo.displayImage)
    }
    .alert(
      NSLocalizedString("Enable Longer Delay?", comment: "Shown in the alert dialog"),
      isPresented: Binding(
        get: { self.pendingLongerDelayDisplayID != nil },
        set: { newValue in
          if !newValue {
            self.pendingLongerDelayDisplayID = nil
          }
        }
      )
    ) {
      Button(NSLocalizedString("Yes", comment: "Shown in the alert dialog")) {
        guard let otherDisplay = self.otherDisplay else { return }
        app.setStartAtLogin(enabled: false)
        otherDisplay.savePref(true, key: .longerDelay)
        self.pendingLongerDelayDisplayID = nil
        self.onRefresh()
      }
      Button(NSLocalizedString("No", comment: "Shown in the alert dialog")) {
        self.pendingLongerDelayDisplayID = nil
        self.onRefresh()
      }
    } message: {
      Text(NSLocalizedString("Are you sure you want to enable a longer delay? Doing so may freeze your system and require a restart. Start at login will be disabled as a safety measure.", comment: "Shown in the alert dialog"))
    }
    .alert(
      NSLocalizedString("Reset Display Settings?", comment: "Shown in the alert dialog"),
      isPresented: self.$showingResetConfirmation
    ) {
      Button(NSLocalizedString("Reset", comment: "Shown in the alert dialog")) {
        self.resetDisplayPrefs()
        self.onRefresh()
      }
      Button(NSLocalizedString("Cancel", comment: "Shown in the alert dialog")) {}
    } message: {
      Text(NSLocalizedString("This will reset the saved settings for this display.", comment: "Shown in the alert dialog"))
    }
  }

  private var otherDisplay: OtherDisplay? {
    self.display as? OtherDisplay
  }

  private var friendlyNameOrSystemName: String {
    let stored = self.display.readPrefAsString(key: .friendlyName)
    return stored.isEmpty ? self.display.name : stored
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { !self.display.readPrefAsBool(key: .isDisabled) },
      set: { newValue in
        self.display.savePref(!newValue, key: .isDisabled)
      }
    )
  }

  private var canToggleDDC: Bool {
    guard let other = self.otherDisplay else { return false }
    return !other.isSwOnly() && !other.isVirtual
  }

  private var ddcBinding: Binding<Bool> {
    Binding(
      get: { !(self.otherDisplay?.isSw() ?? true) },
      set: { newValue in
        let display = self.display
        if newValue {
          _ = display.setDirectBrightness(1)
          display.savePref(false, key: .forceSw)
        } else {
          display.savePref(true, key: .forceSw)
        }
        _ = display.setSwBrightness(1)
        _ = display.setDirectBrightness(1)
        app.configure()
        self.onRefresh()
      }
    )
  }

  private var canToggleAvoidGamma: Bool {
    guard let other = self.otherDisplay else { return false }
    return !other.isVirtual
  }

  private var avoidGammaBinding: Binding<Bool> {
    Binding(
      get: { self.display.readPrefAsBool(key: .avoidGamma) },
      set: { newValue in
        guard let other = self.otherDisplay else { return }
        _ = other.setSwBrightness(1)
        _ = other.setDirectBrightness(1)
        other.savePref(newValue, key: .avoidGamma)
        self.onRefresh()
      }
    )
  }

  private var canToggleVolumeOSD: Bool {
    guard let other = self.otherDisplay else { return false }
    return !other.isSw()
  }

  private var disableVolumeOSDBinding: Binding<Bool> {
    Binding(
      get: { (self.otherDisplay?.readPrefAsBool(key: .hideOsd) ?? false) },
      set: { newValue in
        self.otherDisplay?.savePref(newValue, key: .hideOsd)
      }
    )
  }

  private var friendlyNameBinding: Binding<String> {
    Binding(
      get: { self.friendlyNameOrSystemName },
      set: { newValue in
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.display.savePref(trimmed, key: .friendlyName)
        app.updateMenusAndKeys()
        self.onRefresh()
      }
    )
  }

  @ViewBuilder
  private var advancedContent: some View {
    if let other = self.otherDisplay, !other.isSwOnly() {
      VStack(alignment: .leading, spacing: 14) {
        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            Picker(NSLocalizedString("Polling mode", comment: "Displays preference"), selection: self.pollingModeBinding) {
              Text(NSLocalizedString("None", comment: "Displays preference")).tag(PollingMode.none.rawValue)
              Text(NSLocalizedString("Minimal", comment: "Displays preference")).tag(PollingMode.minimal.rawValue)
              Text(NSLocalizedString("Normal", comment: "Displays preference")).tag(PollingMode.normal.rawValue)
              Text(NSLocalizedString("Heavy", comment: "Displays preference")).tag(PollingMode.heavy.rawValue)
              Text(NSLocalizedString("Custom", comment: "Displays preference")).tag(PollingMode.custom.rawValue)
            }
            .pickerStyle(.menu)

            if other.readPrefAsInt(key: .pollingMode) == PollingMode.custom.rawValue {
              HStack(spacing: 12) {
                Text(NSLocalizedString("Count", comment: "Displays preference"))
                  .frame(width: 90, alignment: .leading)
                TextField("", text: self.pollingCountBinding)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: 80)
              }
            }

            Toggle(NSLocalizedString("Longer delay during DDC read operations", comment: "Displays preference"), isOn: self.longerDelayBinding)
            Toggle(NSLocalizedString("Enable Mute DDC command", comment: "Displays preference"), isOn: self.enableMuteBinding)
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
              Text(NSLocalizedString("Combined dimming switchover point", comment: "Displays preference"))
              Slider(value: self.combinedSwitchBinding, in: -8 ... 7, step: 1)
              Text(String(format: NSLocalizedString("Effective switchover: %.0f%% hardware brightness", comment: "Displays preference"), other.combinedBrightnessSwitchingValue() * 100))
                .font(.caption)
                .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
              Text(NSLocalizedString("Override audio device name", comment: "Displays preference"))
              TextField("", text: self.audioDeviceNameBinding)
                .textFieldStyle(.roundedBorder)
              Button(NSLocalizedString("Get current", comment: "Displays preference")) {
                if let defaultDevice = app.coreAudio.defaultOutputDevice {
                  other.savePref(defaultDevice.name, key: .audioDeviceNameOverride)
                  app.configure()
                  self.onRefresh()
                }
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("DDC Commands", comment: "Displays preference"))
              .font(.subheadline.weight(.semibold))
            Toggle(NSLocalizedString("Enable Brightness DDC command", comment: "Displays preference"), isOn: self.ddcCommandEnabledBinding(.brightness))
            Toggle(NSLocalizedString("Enable Volume DDC command", comment: "Displays preference"), isOn: self.ddcCommandEnabledBinding(.audioSpeakerVolume))
            Toggle(NSLocalizedString("Enable Contrast DDC command", comment: "Displays preference"), isOn: self.ddcCommandEnabledBinding(.contrast))
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("DDC Overrides", comment: "Displays preference"))
              .font(.subheadline.weight(.semibold))

            DDCOverrideRow(title: NSLocalizedString("Brightness", comment: "Displays preference")) {
              DDCOverrideFields(
                minBinding: self.intOverrideBinding(key: .minDDCOverride, command: .brightness, range: 0 ... 65535),
                maxBinding: self.uintOverrideBinding(key: .maxDDCOverride, command: .brightness),
                curveBinding: self.curveBinding(command: .brightness),
                invertBinding: self.boolDisplayBinding(key: .invertDDC, command: .brightness),
                remapBinding: self.hexRemapBinding(command: .brightness)
              )
            }

            DDCOverrideRow(title: NSLocalizedString("Volume", comment: "Displays preference")) {
              DDCOverrideFields(
                minBinding: self.intOverrideBinding(key: .minDDCOverride, command: .audioSpeakerVolume, range: 0 ... 65535),
                maxBinding: self.uintOverrideBinding(key: .maxDDCOverride, command: .audioSpeakerVolume),
                curveBinding: self.curveBinding(command: .audioSpeakerVolume),
                invertBinding: self.boolDisplayBinding(key: .invertDDC, command: .audioSpeakerVolume),
                remapBinding: self.hexRemapBinding(command: .audioSpeakerVolume)
              )
            }

            DDCOverrideRow(title: NSLocalizedString("Contrast", comment: "Displays preference")) {
              DDCOverrideFields(
                minBinding: self.intOverrideBinding(key: .minDDCOverride, command: .contrast, range: 0 ... 65535),
                maxBinding: self.uintOverrideBinding(key: .maxDDCOverride, command: .contrast),
                curveBinding: self.curveBinding(command: .contrast),
                invertBinding: self.boolDisplayBinding(key: .invertDDC, command: .contrast),
                remapBinding: self.hexRemapBinding(command: .contrast)
              )
            }
          }
        }

        HStack {
          Spacer()
          Button {
            self.showingResetConfirmation = true
          } label: {
            Text(NSLocalizedString("Reset display settings", comment: "Displays preference"))
          }
        }
      }
      .padding(.top, 8)
    } else {
      Text(NSLocalizedString("Advanced settings are only available for external DDC-capable displays.", comment: "Displays preference help"))
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.top, 6)
    }
  }

  private var pollingModeBinding: Binding<Int> {
    Binding(
      get: { self.otherDisplay?.readPrefAsInt(key: .pollingMode) ?? PollingMode.normal.rawValue },
      set: { newValue in
        self.otherDisplay?.savePref(newValue, key: .pollingMode)
        self.onRefresh()
      }
    )
  }

  private var pollingCountBinding: Binding<String> {
    Binding(
      get: { String(self.otherDisplay?.pollingCount ?? 0) },
      set: { newValue in
        guard let other = self.otherDisplay else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(trimmed) else { return }
        other.pollingCount = intValue
        self.onRefresh()
      }
    )
  }

  private var longerDelayBinding: Binding<Bool> {
    Binding(
      get: { self.otherDisplay?.readPrefAsBool(key: .longerDelay) ?? false },
      set: { newValue in
        guard let other = self.otherDisplay else { return }
        if newValue {
          // Show confirmation first.
          self.pendingLongerDelayDisplayID = other.identifier
        } else {
          other.savePref(false, key: .longerDelay)
          self.onRefresh()
        }
      }
    )
  }

  private var enableMuteBinding: Binding<Bool> {
    Binding(
      get: { self.otherDisplay?.readPrefAsBool(key: .enableMuteUnmute) ?? false },
      set: { newValue in
        guard let other = self.otherDisplay else { return }
        if !newValue, other.readPrefAsInt(for: .audioMuteScreenBlank) == 1 {
          other.toggleMute()
        }
        other.savePref(newValue, key: .enableMuteUnmute)
      }
    )
  }

  private var combinedSwitchBinding: Binding<Double> {
    Binding(
      get: { Double(self.otherDisplay?.readPrefAsInt(key: .combinedBrightnessSwitchingPoint) ?? 0) },
      set: { newValue in
        self.otherDisplay?.savePref(Int(newValue), key: .combinedBrightnessSwitchingPoint)
        self.onRefresh()
      }
    )
  }

  private var audioDeviceNameBinding: Binding<String> {
    Binding(
      get: { self.otherDisplay?.readPrefAsString(key: .audioDeviceNameOverride) ?? "" },
      set: { newValue in
        self.otherDisplay?.savePref(newValue, key: .audioDeviceNameOverride)
        app.configure()
        self.onRefresh()
      }
    )
  }

  private func ddcCommandEnabledBinding(_ command: Command) -> Binding<Bool> {
    Binding(
      get: { !self.display.readPrefAsBool(key: .unavailableDDC, for: command) },
      set: { newValue in
        self.display.savePref(!newValue, key: .unavailableDDC, for: command)
        _ = self.display.setDirectBrightness(1)
        _ = self.display.setSwBrightness(1)
        app.configure()
        self.onRefresh()
      }
    )
  }

  private func boolDisplayBinding(key: PrefKey, command: Command) -> Binding<Bool> {
    Binding(
      get: { self.otherDisplay?.readPrefAsBool(key: key, for: command) ?? false },
      set: { newValue in
        self.otherDisplay?.savePref(newValue, key: key, for: command)
        app.configure()
        self.onRefresh()
      }
    )
  }

  private func curveBinding(command: Command) -> Binding<Double> {
    Binding(
      get: {
        let raw = self.otherDisplay?.readPrefAsInt(key: .curveDDC, for: command) ?? 0
        let effective = raw == 0 ? 5 : raw
        return Double(effective)
      },
      set: { newValue in
        self.otherDisplay?.savePref(Int(newValue), key: .curveDDC, for: command)
        self.onRefresh()
      }
    )
  }

  private func normalizeHexRemap(_ input: String) -> String {
    let values = input.components(separatedBy: ",")
    var normalizedValues: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " "))
      if !trimmed.isEmpty, let intValue = UInt8(trimmed, radix: 16), intValue != 0 {
        normalizedValues.append(String(format: "%02x", intValue))
      }
    }
    return normalizedValues.joined(separator: ", ")
  }

  private func hexRemapBinding(command: Command) -> Binding<String> {
    Binding(
      get: { self.otherDisplay?.readPrefAsString(key: .remapDDC, for: command) ?? "" },
      set: { newValue in
        let normalized = self.normalizeHexRemap(newValue)
        self.otherDisplay?.savePref(normalized, key: .remapDDC, for: command)
        self.onRefresh()
      }
    )
  }

  private func intOverrideBinding(key: PrefKey, command: Command, range: ClosedRange<Int>) -> Binding<String> {
    Binding(
      get: { self.otherDisplay?.readPrefAsString(key: key, for: command) ?? "" },
      set: { newValue in
        guard let other = self.otherDisplay else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intValue = Int(trimmed), range.contains(intValue) {
          other.savePref(intValue, key: key, for: command)
        } else if trimmed.isEmpty {
          other.removePref(key: key, for: command)
        }
        app.configure()
        self.onRefresh()
      }
    )
  }

  private func uintOverrideBinding(key: PrefKey, command: Command) -> Binding<String> {
    Binding(
      get: { self.otherDisplay?.readPrefAsString(key: key, for: command) ?? "" },
      set: { newValue in
        guard let other = self.otherDisplay else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intValue = UInt(trimmed) {
          other.savePref(Int(intValue), key: key, for: command)
        } else if trimmed.isEmpty {
          other.removePref(key: key, for: command)
        }
        app.configure()
        self.onRefresh()
      }
    )
  }

  private func resetDisplayPrefs() {
    // Remove common display-specific prefs to restore defaults.
    let commands: [Command] = [.brightness, .audioSpeakerVolume, .contrast]
    self.display.removePref(key: .friendlyName)
    self.display.removePref(key: .isDisabled)
    self.display.removePref(key: .forceSw)
    self.display.removePref(key: .avoidGamma)
    self.display.removePref(key: .hideOsd)
    self.display.removePref(key: .pollingMode)
    self.display.removePref(key: .pollingCount)
    self.display.removePref(key: .longerDelay)
    self.display.removePref(key: .enableMuteUnmute)
    self.display.removePref(key: .combinedBrightnessSwitchingPoint)
    self.display.removePref(key: .audioDeviceNameOverride)
    for command in commands {
      self.display.removePref(key: .unavailableDDC, for: command)
      self.display.removePref(key: .minDDCOverride, for: command)
      self.display.removePref(key: .maxDDCOverride, for: command)
      self.display.removePref(key: .curveDDC, for: command)
      self.display.removePref(key: .invertDDC, for: command)
      self.display.removePref(key: .remapDDC, for: command)
    }
    app.configure()
  }
}

@available(macOS 13.0, *)
private struct DDCOverrideRow<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(self.title)
        .font(.caption.weight(.semibold))
        .foregroundColor(.secondary)
      self.content()
    }
  }
}

@available(macOS 13.0, *)
private struct DDCOverrideFields: View {
  let minBinding: Binding<String>
  let maxBinding: Binding<String>
  let curveBinding: Binding<Double>
  let invertBinding: Binding<Bool>
  let remapBinding: Binding<String>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Text("DDC min")
          .frame(width: 70, alignment: .leading)
        TextField("", text: self.minBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
        Text("DDC max")
          .frame(width: 70, alignment: .leading)
        TextField("", text: self.maxBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
      }

      HStack(spacing: 12) {
        Text("Curve")
          .frame(width: 70, alignment: .leading)
        Slider(value: self.curveBinding, in: 1 ... 9, step: 1)
          .frame(width: 180)
        Toggle("Invert", isOn: self.invertBinding)
          .toggleStyle(.switch)
      }

      HStack(spacing: 12) {
        Text("Remap")
          .frame(width: 70, alignment: .leading)
        TextField(NSLocalizedString("Hex codes (comma-separated)", comment: "Displays preference"), text: self.remapBinding)
          .textFieldStyle(.roundedBorder)
      }
    }
  }
}

// MARK: - About

@available(macOS 13.0, *)
private struct AboutSettingsView: View {
  private var versionText: String {
    let versionName = NSLocalizedString("Version", comment: "Version")
    let buildName = NSLocalizedString("Build", comment: "Build")
    let versionNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"
    return "\(versionName) \(versionNumber) \(buildName) \(buildNumber)"
  }

  var body: some View {
    Form {
      Section {
        Text("MonitorControl")
          .font(.title.weight(.semibold))
        Text(self.versionText)
          .font(.callout)
          .foregroundColor(.secondary)
      }

      Section {
        Button(NSLocalizedString("Check for updates…", comment: "About")) {
          app.updaterController.checkForUpdates(nil)
        }
        Button(NSLocalizedString("Open website", comment: "About")) {
          if let url = URL(string: "https://monitorcontrol.app") {
            NSWorkspace.shared.open(url)
          }
        }
        Button(NSLocalizedString("Donate", comment: "About")) {
          if let url = URL(string: "https://opencollective.com/monitorcontrol/donate") {
            NSWorkspace.shared.open(url)
          }
        }
        Button(NSLocalizedString("Contributors", comment: "About")) {
          if let url = URL(string: "https://github.com/MonitorControl/MonitorControl/graphs/contributors") {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}
