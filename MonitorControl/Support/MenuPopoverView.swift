// swiftlint:disable file_length

import AppKit
import SwiftUI

@available(macOS 10.15, *)
struct MenuPopoverView: View {
  @ObservedObject var model: MenuPopoverModel
  /// Bumped on each popover show to reset internal ScrollView offsets/state.
  let sessionID: Int
  var requestContentSizeUpdate: (() -> Void)?

  var body: some View {
    Group {
      if #available(macOS 26.0, *), self.isNewPopoverEnabled {
        NewMenuPopoverRoot(model: self.model, sessionID: self.sessionID, requestContentSizeUpdate: self.requestContentSizeUpdate)
      } else {
        LegacyMenuPopoverRoot(model: self.model, sessionID: self.sessionID)
      }
    }
    // Ensure SwiftUI doesn't preserve view-local scroll state between popover shows.
    .id(self.sessionID)
  }

  private var isNewPopoverEnabled: Bool {
    guard #available(macOS 26.0, *) else { return false }
    if prefs.object(forKey: PrefKey.useNewPopoverUI.rawValue) == nil {
      return true
    }
    return prefs.bool(forKey: PrefKey.useNewPopoverUI.rawValue)
  }
}

@available(macOS 10.15, *)
private struct LegacyMenuPopoverRoot: View {
  @ObservedObject var model: MenuPopoverModel
  let sessionID: Int

  var body: some View {
    Group {
      if #available(macOS 11.0, *) {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              Color.clear
                .frame(height: 0)
                .id("top")
              Group {
                if #available(macOS 26.0, *) {
                  GlassEffectContainer(spacing: 12) { self.content }
                } else {
                  self.content
                }
              }
              .padding(12)
            }
          }
          .onAppear { Self.scrollToTop(proxy) }
          .onChange(of: self.sessionID) { _ in Self.scrollToTop(proxy) }
        }
      } else {
        ScrollView {
          Group {
            if #available(macOS 26.0, *) {
              GlassEffectContainer(spacing: 12) { self.content }
            } else {
              self.content
            }
          }
          .padding(12)
        }
      }
    }
    .frame(minWidth: 280, maxWidth: 360, maxHeight: 420)
    .clipped()
  }

  @available(macOS 11.0, *)
  private static func scrollToTop(_ proxy: ScrollViewProxy) {
    // Defer so the ScrollView's underlying NSScrollView exists and has a size.
    DispatchQueue.main.async {
      proxy.scrollTo("top", anchor: .top)
    }
  }

  private var content: some View {
    VStack(spacing: 12) {
      if !self.model.isLGActive {
        InactiveStateView(model: self.model)
          .modifier(GlassCard())
      } else if self.model.sliderMode == .combine {
        if self.model.combinedCommands.isEmpty {
          Text(NSLocalizedString("No controllable displays found.", comment: "Shown in menu"))
            .font(.caption)
            .foregroundColor(.secondary)
            .modifier(GlassCard())
        } else {
          CombinedSectionView(model: self.model)
        }
      } else {
        if self.model.displaySections.isEmpty {
          Text(NSLocalizedString("No controllable displays found.", comment: "Shown in menu"))
            .font(.caption)
            .foregroundColor(.secondary)
            .modifier(GlassCard())
        } else {
          ForEach(self.model.displaySections) { section in
            DisplaySectionView(section: section, model: self.model)
          }
        }
      }
      if self.model.isLGActive {
        FooterActionsView(model: self.model)
      }
    }
  }
}

@available(macOS 10.15, *)
private struct InactiveStateView: View {
  @ObservedObject var model: MenuPopoverModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(self.message)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(NSLocalizedString("Open Settings > Displays to verify control method.", comment: "Shown in menu"))
        .font(.caption)
        .foregroundColor(.secondary)
      VStack(spacing: 8) {
        self.actionButton(title: NSLocalizedString("Settings…", comment: "Shown in menu"), systemImage: "gearshape") {
          app.prefsClicked(app as AnyObject)
        }
        self.actionButton(title: NSLocalizedString("Check for updates…", comment: "Shown in menu"), systemImage: "arrow.triangle.2.circlepath.circle") {
          app.updaterController.checkForUpdates(nil)
        }
        self.actionButton(title: NSLocalizedString("Quit", comment: "Shown in menu"), systemImage: "xmark.circle") {
          app.quitClicked(app as AnyObject)
        }
      }
    }
  }

  private var message: String {
    if self.model.isInLaunchGrace {
      return NSLocalizedString("No LG display connected. MonitorControl will hide after about a minute.", comment: "Shown in menu")
    }
    return NSLocalizedString("No LG display connected.", comment: "Shown in menu")
  }

  @ViewBuilder
  private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    let button = Button { self.performAction(action) } label: {
      if #available(macOS 11.0, *) {
        Label(title, systemImage: systemImage)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(title)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    if #available(macOS 26.0, *) {
      button.buttonStyle(.glassProminent)
    } else if #available(macOS 12.0, *) {
      button.buttonStyle(.borderedProminent)
    } else if #available(macOS 11.0, *) {
      button.buttonStyle(.bordered)
    } else {
      button.buttonStyle(.plain)
    }
  }

  private func performAction(_ action: () -> Void) {
    action()
    if let controller = app.menuPopoverController as? MenuPopoverController {
      controller.closePopover()
    }
  }
}

@available(macOS 10.15, *)
private struct DisplaySectionView: View {
  let section: MenuPopoverModel.DisplaySection
  @ObservedObject var model: MenuPopoverModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(self.section.name)
        .font(.headline)
        .foregroundColor(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
      if self.section.supportsBrightness {
        SliderRow(
          title: NSLocalizedString("Brightness", comment: "Shown in menu"),
          icon: "sun.max.fill",
          value: self.binding(for: .brightness),
          onEditingChanged: self.onEditingChanged
        )
      }
      if self.section.supportsContrast {
        SliderRow(
          title: NSLocalizedString("Contrast", comment: "Shown in menu"),
          icon: "circle.lefthalf.fill",
          value: self.binding(for: .contrast),
          onEditingChanged: self.onEditingChanged
        )
      }
      if self.section.supportsVolume {
        SliderRow(
          title: NSLocalizedString("Volume", comment: "Shown in menu"),
          icon: "speaker.wave.2.fill",
          value: self.binding(for: .audioSpeakerVolume),
          onEditingChanged: self.onEditingChanged
        )
      }
    }
    .modifier(GlassCard())
  }

  private func binding(for command: Command) -> Binding<Float> {
    Binding(
      get: { self.model.value(for: self.section.display, command: command) },
      set: { newValue in self.model.setValue(newValue, for: self.section.display, command: command) }
    )
  }

  private func onEditingChanged(_ isEditing: Bool) {
    if isEditing {
      self.model.beginUserInteraction()
    } else {
      self.model.endUserInteraction()
    }
  }
}

@available(macOS 10.15, *)
private struct CombinedSectionView: View {
  @ObservedObject var model: MenuPopoverModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(NSLocalizedString("All Displays", comment: "Shown in menu"))
        .font(.headline)
        .foregroundColor(.primary)
      ForEach(self.orderedCommands(self.model.combinedCommands), id: \.rawValue) { command in
        SliderRow(
          title: self.title(for: command),
          icon: self.icon(for: command),
          value: self.binding(for: command),
          onEditingChanged: self.onEditingChanged
        )
      }
    }
    .modifier(GlassCard())
  }

  private func binding(for command: Command) -> Binding<Float> {
    Binding(
      get: { self.model.combinedValue(for: command) },
      set: { newValue in self.model.setCombinedValue(newValue, command: command) }
    )
  }

  private func title(for command: Command) -> String {
    switch command {
    case .audioSpeakerVolume: return NSLocalizedString("Volume", comment: "Shown in menu")
    case .contrast: return NSLocalizedString("Contrast", comment: "Shown in menu")
    default: return NSLocalizedString("Brightness", comment: "Shown in menu")
    }
  }

  private func icon(for command: Command) -> String {
    switch command {
    case .audioSpeakerVolume: return "speaker.wave.2.fill"
    case .contrast: return "circle.lefthalf.fill"
    default: return "sun.max.fill"
    }
  }

  private func orderedCommands(_ commands: [Command]) -> [Command] {
    let priority: [Command: Int] = [.brightness: 0, .contrast: 1, .audioSpeakerVolume: 2]
    return commands.sorted { (priority[$0] ?? 999) < (priority[$1] ?? 999) }
  }

  private func onEditingChanged(_ isEditing: Bool) {
    if isEditing {
      self.model.beginUserInteraction()
    } else {
      self.model.endUserInteraction()
    }
  }
}

@available(macOS 10.15, *)
private struct SliderRow: View {
  let title: String
  let icon: String
  @Binding var value: Float
  var onEditingChanged: ((Bool) -> Void)?

  var body: some View {
    let row = HStack(spacing: 10) {
      if #available(macOS 11.0, *) {
        Image(systemName: self.icon)
          .foregroundColor(.secondary)
          .frame(width: 16)
      } else {
        Color.clear
          .frame(width: 16, height: 16)
      }
      Slider(
        value: Binding(get: { Double(self.value) }, set: { self.value = Float($0) }),
        in: 0 ... 1,
        onEditingChanged: { isEditing in
          self.onEditingChanged?(isEditing)
        }
      )
      .transaction { transaction in
        // Prevent implicit animations caused by the model polling.
        transaction.disablesAnimations = true
      }
      if prefs.bool(forKey: PrefKey.enableSliderPercent.rawValue) {
        Text("\(Int(self.value * 100))%")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(width: 42, alignment: .trailing)
      }
    }
    if #available(macOS 11.0, *) {
      row.accessibilityLabel(Text(self.title))
    } else {
      row
    }
  }
}

@available(macOS 10.15, *)
private struct FooterActionsView: View {
  @ObservedObject var model: MenuPopoverModel

  var body: some View {
    if self.model.menuItemStyle == .hide {
      EmptyView()
    } else if self.model.menuItemStyle == .icon, #available(macOS 11.0, *) {
      HStack(spacing: 16) {
        if #available(macOS 26.0, *) {
          Button { self.performAction { app.prefsClicked(app as AnyObject) } } label: {
            Image(systemName: "gearshape")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.glass)
        } else {
          Button { self.performAction { app.prefsClicked(app as AnyObject) } } label: {
            Image(systemName: "gearshape")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.plain)
        }

        if #available(macOS 26.0, *) {
          Button { self.performAction { app.updaterController.checkForUpdates(nil) } } label: {
            Image(systemName: "arrow.triangle.2.circlepath.circle")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.glass)
        } else {
          Button { self.performAction { app.updaterController.checkForUpdates(nil) } } label: {
            Image(systemName: "arrow.triangle.2.circlepath.circle")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.plain)
        }

        if #available(macOS 26.0, *) {
          Button { self.performAction { app.quitClicked(app as AnyObject) } } label: {
            Image(systemName: "xmark.circle")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.glass)
        } else {
          Button { self.performAction { app.quitClicked(app as AnyObject) } } label: {
            Image(systemName: "xmark.circle")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.plain)
        }
      }
      .modifier(GlassCard())
    } else {
      VStack(spacing: 8) {
        Button(NSLocalizedString("Settings…", comment: "Shown in menu")) {
          self.performAction { app.prefsClicked(app as AnyObject) }
        }
        Button(NSLocalizedString("Check for updates…", comment: "Shown in menu")) {
          self.performAction { app.updaterController.checkForUpdates(nil) }
        }
        Button(NSLocalizedString("Quit", comment: "Shown in menu")) {
          self.performAction { app.quitClicked(app as AnyObject) }
        }
      }
      .modifier(GlassCard())
    }
  }

  private func performAction(_ action: () -> Void) {
    action()
    if let controller = app.menuPopoverController as? MenuPopoverController {
      controller.closePopover()
    }
  }
}

@available(macOS 10.15, *)
private struct GlassCard: ViewModifier {
  func body(content: Content) -> some View {
    Group {
      if #available(macOS 26.0, *) {
        content
          .padding(12)
          // Non-interactive glass keeps appearance stable when the popover becomes key.
          .glassEffect(.regular, in: .rect(cornerRadius: 16))
      } else if #available(macOS 12.0, *) {
        content
          .padding(12)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
      } else {
        content
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(Color(NSColor.windowBackgroundColor))
          )
      }
    }
  }
}

// MARK: - macOS 26+ Redesign

@available(macOS 26.0, *)
private struct NewMenuPopoverRoot: View {
  @ObservedObject var model: MenuPopoverModel
  let sessionID: Int
  var requestContentSizeUpdate: (() -> Void)?

  @State private var ephemeralExpandedIDs: Set<Int> = []
  @State private var ephemeralKnownIDs: Set<Int> = []
  @State private var ephemeralInitialized: Bool = false

  var body: some View {
    VStack(spacing: 12) {
      self.header
        .modifier(GlassCard())

      Group {
        if #available(macOS 11.0, *) {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 12) {
                Color.clear
                  .frame(height: 0)
                  .id("top")
                self.content
              }
              .padding(.vertical, 2)
            }
            .onAppear { Self.scrollToTop(proxy) }
            .onChange(of: self.sessionID) { _ in Self.scrollToTop(proxy) }
          }
        } else {
          ScrollView {
            VStack(spacing: 12) {
              self.content
            }
            .padding(.vertical, 2)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .top)

      if self.model.isLGActive {
        FooterActionsView26(model: self.model)
      }
    }
    .padding(12)
    .frame(minWidth: 240, idealWidth: 340, maxWidth: 340, maxHeight: 420)
    .clipped()
    .onAppear {
      self.seedEphemeralIfNeeded()
      self.requestContentSizeUpdate?()
    }
    .onChange(of: self.effectiveDisplayIDs) { _ in
      self.seedEphemeralIfNeeded()
      self.requestContentSizeUpdate?()
    }
    .onChange(of: self.model.sliderMode.rawValue) { _ in
      self.requestContentSizeUpdate?()
    }
    .onChange(of: self.model.isLGActive) { _ in
      self.seedEphemeralIfNeeded()
      self.requestContentSizeUpdate?()
    }
    .onChange(of: prefs.bool(forKey: PrefKey.enableSliderPercent.rawValue)) { _ in
      self.requestContentSizeUpdate?()
    }
  }

  private static func scrollToTop(_ proxy: ScrollViewProxy) {
    DispatchQueue.main.async {
      proxy.scrollTo("top", anchor: .top)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("MonitorControl")
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.9)
          StatusChip(isActive: self.model.isLGActive)
        }
        Spacer()
        self.gearMenu
      }
    }
  }

  private var gearMenu: some View {
    Menu {
      Menu(NSLocalizedString("Slider mode", comment: "Menu popover option")) {
        self.sliderModeButton(
          title: NSLocalizedString("Each display", comment: "Menu popover slider mode"),
          mode: .separate,
          help: NSLocalizedString("Show one card per display.", comment: "Menu popover slider mode help")
        )
        self.sliderModeButton(
          title: NSLocalizedString("Menu bar display", comment: "Menu popover slider mode"),
          mode: .relevant,
          help: NSLocalizedString("Show only the display this menu bar is on.", comment: "Menu popover slider mode help")
        )
        self.sliderModeButton(
          title: NSLocalizedString("All displays", comment: "Menu popover slider mode"),
          mode: .combine,
          help: NSLocalizedString("Combine sliders for all displays.", comment: "Menu popover slider mode help")
        )
      }
      Divider()
      Toggle(NSLocalizedString("Show %", comment: "Menu popover option"), isOn: self.boolBinding(.enableSliderPercent))
      Toggle(NSLocalizedString("Snap", comment: "Menu popover option"), isOn: self.boolBinding(.enableSliderSnap))
      Toggle(NSLocalizedString("Contrast slider", comment: "Menu popover option"), isOn: self.showContrastBinding)
      Divider()
      Menu(NSLocalizedString("Cards", comment: "Menu popover option")) {
        self.expansionModeButton(title: NSLocalizedString("Auto", comment: "Menu popover option"), mode: .auto)
        self.expansionModeButton(title: NSLocalizedString("Expanded", comment: "Menu popover option"), mode: .expanded)
        self.expansionModeButton(title: NSLocalizedString("Collapsed", comment: "Menu popover option"), mode: .collapsed)
        Divider()
        Toggle(
          NSLocalizedString("Remember expanded displays", comment: "Menu popover option"),
          isOn: self.rememberExpandedBinding
        )
        if self.model.displayCount > 2 {
          Divider()
          Button(NSLocalizedString("Expand All", comment: "Menu popover option")) {
            self.setAllExpanded(true)
          }
          Button(NSLocalizedString("Collapse All", comment: "Menu popover option")) {
            self.setAllExpanded(false)
          }
        }
      }
      Divider()
      Button(NSLocalizedString("Open Settings…", comment: "Shown in menu")) {
        self.performAction {
          app.prefsClicked(app as AnyObject)
        }
      }
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 32, height: 32)
    }
    .buttonStyle(.glass)
    .help(NSLocalizedString("Menu options", comment: "Menu popover tooltip"))
  }

  private func sliderModeButton(title: String, mode: MultiSliders, help: String) -> some View {
    Button {
      self.modeBinding.wrappedValue = mode
    } label: {
      HStack {
        Text(title)
        Spacer()
        if self.model.sliderMode == mode {
          Image(systemName: "checkmark")
            .foregroundColor(.secondary)
        }
      }
    }
    .help(help)
  }

  private var modeBinding: Binding<MultiSliders> {
    Binding(
      get: { self.model.sliderMode },
      set: { newValue in
        self.model.setSliderMode(newValue)
        app.updateMenusAndKeys()
        self.requestContentSizeUpdate?()
      }
    )
  }

  private var content: some View {
    Group {
      if !self.model.isLGActive {
        InactiveStateView(model: self.model)
          .modifier(GlassCard())
      } else if self.model.sliderMode == .combine {
        if self.model.combinedCommands.isEmpty {
          Text(NSLocalizedString("No controllable displays found.", comment: "Shown in menu"))
            .font(.caption)
            .foregroundColor(.secondary)
            .modifier(GlassCard())
        } else {
          CombinedSectionView(model: self.model)
        }
      } else {
        if self.model.displaySections.isEmpty {
          Text(NSLocalizedString("No controllable displays found.", comment: "Shown in menu"))
            .font(.caption)
            .foregroundColor(.secondary)
            .modifier(GlassCard())
        } else {
          ForEach(self.model.displaySections) { section in
            DisplayCardView(
              section: section,
              model: self.model,
              isExpanded: self.expandedBinding(for: section),
              isToggleEnabled: self.expansionMode == .auto,
              requestContentSizeUpdate: self.requestContentSizeUpdate
            )
          }
        }
      }
    }
  }

  private var effectiveDisplayIDs: [Int] {
    self.model.displaySections.map { Int(DisplayManager.resolveEffectiveDisplayID($0.display.identifier)) }
  }

  private var rememberExpandedDisplays: Bool {
    if prefs.object(forKey: PrefKey.popoverRememberExpandedDisplays.rawValue) == nil {
      return true
    }
    return prefs.bool(forKey: PrefKey.popoverRememberExpandedDisplays.rawValue)
  }

  private var expansionMode: PopoverCardExpansionMode {
    PopoverCardExpansionMode(rawValue: prefs.integer(forKey: PrefKey.popoverCardExpansionMode.rawValue)) ?? .auto
  }

  private func boolBinding(_ key: PrefKey, default defaultValue: Bool = false, _ onSet: (() -> Void)? = nil) -> Binding<Bool> {
    Binding(
      get: {
        if prefs.object(forKey: key.rawValue) == nil {
          return defaultValue
        }
        return prefs.bool(forKey: key.rawValue)
      },
      set: { newValue in
        prefs.set(newValue, forKey: key.rawValue)
        onSet?()
        self.model.refresh()
      }
    )
  }

  private var showContrastBinding: Binding<Bool> {
    self.boolBinding(.showContrast) {
      app.updateMenusAndKeys()
    }
  }

  private var rememberExpandedBinding: Binding<Bool> {
    Binding(
      get: { self.rememberExpandedDisplays },
      set: { newValue in
        if newValue {
          prefs.set(true, forKey: PrefKey.popoverRememberExpandedDisplays.rawValue)
          // Switching on: persist current ephemeral state if we have it.
          if self.ephemeralInitialized {
            self.setPersistedExpandedIDs(self.ephemeralExpandedIDs)
          }
        } else {
          let allIDs = Set(self.effectiveDisplayIDs)
          let snapshot: Set<Int>
          switch self.expansionMode {
          case .expanded:
            snapshot = allIDs
          case .collapsed:
            snapshot = []
          case .auto:
            snapshot = self.readPersistedExpandedIDs()
              ?? (self.model.displayCount <= 2 ? allIDs : [])
          }
          prefs.set(false, forKey: PrefKey.popoverRememberExpandedDisplays.rawValue)
          // Switching off: snapshot current expanded state into ephemeral storage.
          self.ephemeralExpandedIDs = snapshot
          self.ephemeralKnownIDs = Set(self.effectiveDisplayIDs)
          self.ephemeralInitialized = true
        }
        self.requestContentSizeUpdate?()
      }
    )
  }

  private func expansionModeButton(title: String, mode: PopoverCardExpansionMode) -> some View {
    Button {
      prefs.set(mode.rawValue, forKey: PrefKey.popoverCardExpansionMode.rawValue)
      if mode == .expanded {
        self.setAllExpanded(true)
      } else if mode == .collapsed {
        self.setAllExpanded(false)
      }
      self.requestContentSizeUpdate?()
    } label: {
      HStack {
        Text(title)
        Spacer()
        if self.expansionMode == mode {
          Image(systemName: "checkmark")
            .foregroundColor(.secondary)
        }
      }
    }
  }

  private func seedEphemeralIfNeeded() {
    guard !self.rememberExpandedDisplays else {
      return
    }
    let ids = Set(self.effectiveDisplayIDs)
    if !self.ephemeralInitialized {
      switch self.expansionMode {
      case .expanded:
        self.ephemeralExpandedIDs = ids
      case .collapsed:
        self.ephemeralExpandedIDs = []
      case .auto:
        self.ephemeralExpandedIDs = self.model.displayCount <= 2 ? ids : []
      }
      self.ephemeralKnownIDs = ids
      self.ephemeralInitialized = true
      return
    }

    // Add new displays using the current default behavior.
    let newIDs = ids.subtracting(self.ephemeralKnownIDs)
    self.ephemeralKnownIDs = ids
    guard !newIDs.isEmpty else {
      return
    }
    if self.expansionMode == .expanded || (self.expansionMode == .auto && self.model.displayCount <= 2) {
      self.ephemeralExpandedIDs.formUnion(newIDs)
    }
  }

  private func currentExpandedSet() -> Set<Int> {
    switch self.expansionMode {
    case .expanded:
      return Set(self.effectiveDisplayIDs)
    case .collapsed:
      return []
    case .auto:
      if self.rememberExpandedDisplays, let persisted = self.readPersistedExpandedIDs() {
        return persisted
      }
      if self.rememberExpandedDisplays {
        return self.model.displayCount <= 2 ? Set(self.effectiveDisplayIDs) : []
      }
      return self.ephemeralExpandedIDs
    }
  }

  private func expandedBinding(for section: MenuPopoverModel.DisplaySection) -> Binding<Bool> {
    let effectiveID = Int(DisplayManager.resolveEffectiveDisplayID(section.display.identifier))
    return Binding(
      get: {
        switch self.expansionMode {
        case .expanded:
          return true
        case .collapsed:
          return false
        case .auto:
          if self.rememberExpandedDisplays {
            if let persisted = self.readPersistedExpandedIDs() {
              return persisted.contains(effectiveID)
            }
            return self.model.displayCount <= 2
          } else {
            return self.ephemeralExpandedIDs.contains(effectiveID)
          }
        }
      },
      set: { newValue in
        guard self.expansionMode == .auto else {
          return
        }
        if self.rememberExpandedDisplays {
          var set = self.readPersistedExpandedIDs() ?? self.defaultExpandedSetForFirstPersist()
          if newValue {
            set.insert(effectiveID)
          } else {
            set.remove(effectiveID)
          }
          self.setPersistedExpandedIDs(set)
        } else {
          if newValue {
            self.ephemeralExpandedIDs.insert(effectiveID)
          } else {
            self.ephemeralExpandedIDs.remove(effectiveID)
          }
          self.ephemeralInitialized = true
        }
        self.requestContentSizeUpdate?()
      }
    )
  }

  private func readPersistedExpandedIDs() -> Set<Int>? {
    guard prefs.object(forKey: PrefKey.popoverExpandedDisplayIDs.rawValue) != nil else {
      return nil
    }
    let raw = prefs.array(forKey: PrefKey.popoverExpandedDisplayIDs.rawValue) as? [Int] ?? []
    return Set(raw)
  }

  private func setPersistedExpandedIDs(_ set: Set<Int>) {
    let sorted = Array(set).sorted()
    prefs.set(sorted, forKey: PrefKey.popoverExpandedDisplayIDs.rawValue)
  }

  private func defaultExpandedSetForFirstPersist() -> Set<Int> {
    self.model.displayCount <= 2 ? Set(self.effectiveDisplayIDs) : []
  }

  private func setAllExpanded(_ expanded: Bool) {
    let set = expanded ? Set(self.effectiveDisplayIDs) : Set<Int>()
    if self.rememberExpandedDisplays {
      self.setPersistedExpandedIDs(set)
    } else {
      self.ephemeralExpandedIDs = set
      self.ephemeralKnownIDs = Set(self.effectiveDisplayIDs)
      self.ephemeralInitialized = true
    }
    self.requestContentSizeUpdate?()
  }

  private func performAction(_ action: () -> Void) {
    action()
    if let controller = app.menuPopoverController as? MenuPopoverController {
      controller.closePopover()
    }
  }
}

@available(macOS 26.0, *)
private struct StatusChip: View {
  let isActive: Bool

  var body: some View {
    let text = self.isActive
      ? NSLocalizedString("Active", comment: "Menu popover status")
      : NSLocalizedString("No LG display", comment: "Menu popover status")
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundColor(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .glassEffect(.regular, in: .rect(cornerRadius: 999))
      .allowsHitTesting(false)
  }
}

@available(macOS 26.0, *)
private struct DisplayCardView: View {
  let section: MenuPopoverModel.DisplaySection
  @ObservedObject var model: MenuPopoverModel
  @Binding var isExpanded: Bool
  let isToggleEnabled: Bool
  var requestContentSizeUpdate: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        guard self.isToggleEnabled else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
          self.isExpanded.toggle()
        }
        self.requestContentSizeUpdate?()
      } label: {
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(self.section.name)
              .font(.headline)
              .foregroundColor(.primary)
              .lineLimit(1)
              .truncationMode(.tail)
            if let hint = self.controlMethodHint(for: self.section.display) {
              Text(hint)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          Spacer()
          Image(systemName: "chevron.right")
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(self.isExpanded ? 90 : 0))
            .animation(.easeInOut(duration: 0.18), value: self.isExpanded)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!self.isToggleEnabled)

      if self.isExpanded {
        VStack(spacing: 10) {
          if self.section.supportsBrightness {
            SliderRow(title: NSLocalizedString("Brightness", comment: "Shown in menu"), icon: "sun.max.fill", value: self.binding(for: .brightness), onEditingChanged: self.onEditingChanged)
          }
          if self.section.supportsContrast {
            SliderRow(title: NSLocalizedString("Contrast", comment: "Shown in menu"), icon: "circle.lefthalf.fill", value: self.binding(for: .contrast), onEditingChanged: self.onEditingChanged)
          }
          if self.section.supportsVolume {
            SliderRow(title: NSLocalizedString("Volume", comment: "Shown in menu"), icon: "speaker.wave.2.fill", value: self.binding(for: .audioSpeakerVolume), onEditingChanged: self.onEditingChanged)
          }
        }
      } else {
        VStack(spacing: 10) {
          if self.section.supportsBrightness {
            MetricRow(title: NSLocalizedString("Brightness", comment: "Shown in menu"), icon: "sun.max.fill", value: self.model.value(for: self.section.display, command: .brightness))
          }
          if self.section.supportsContrast {
            MetricRow(title: NSLocalizedString("Contrast", comment: "Shown in menu"), icon: "circle.lefthalf.fill", value: self.model.value(for: self.section.display, command: .contrast))
          }
          if self.section.supportsVolume {
            MetricRow(title: NSLocalizedString("Volume", comment: "Shown in menu"), icon: "speaker.wave.2.fill", value: self.model.value(for: self.section.display, command: .audioSpeakerVolume))
          }
        }
      }
    }
    .modifier(GlassCard())
  }

  private func binding(for command: Command) -> Binding<Float> {
    Binding(
      get: { self.model.value(for: self.section.display, command: command) },
      set: { newValue in self.model.setValue(newValue, for: self.section.display, command: command) }
    )
  }

  private func onEditingChanged(_ isEditing: Bool) {
    if isEditing {
      self.model.beginUserInteraction()
    } else {
      self.model.endUserInteraction()
    }
  }

  private func controlMethodHint(for display: Display) -> String? {
    if display is AppleDisplay {
      return nil
    }
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() {
      return nil
    }
    if display.isVirtual {
      return NSLocalizedString("Software (shade)", comment: "Shown in the Display Settings") + "  ⚠️"
    }
    if let otherDisplay = display as? OtherDisplay {
      if otherDisplay.isSwOnly() {
        if otherDisplay.readPrefAsBool(key: .avoidGamma) {
          return NSLocalizedString("Software (shade)", comment: "Shown in the Display Settings") + "  ⚠️"
        }
        return NSLocalizedString("Software (gamma)", comment: "Shown in the Display Settings") + "  ⚠️"
      }
      if otherDisplay.isSw() {
        if otherDisplay.readPrefAsBool(key: .avoidGamma) {
          return NSLocalizedString("Software (shade, forced)", comment: "Shown in the Display Settings")
        }
        return NSLocalizedString("Software (gamma, forced)", comment: "Shown in the Display Settings")
      }
    }
    return nil
  }
}

@available(macOS 26.0, *)
private struct MetricRow: View {
  let title: String
  let icon: String
  let value: Float

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: self.icon)
        .foregroundColor(.secondary)
        .frame(width: 16)

      ProgressView(value: Double(max(0, min(1, self.value))))
        .progressViewStyle(.linear)
        .accessibilityLabel(Text(self.title))

      if prefs.bool(forKey: PrefKey.enableSliderPercent.rawValue) {
        Text("\(Int(self.value * 100))%")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(width: 42, alignment: .trailing)
      }
    }
    .font(.caption)
  }
}

@available(macOS 26.0, *)
private struct FooterActionsView26: View {
  @ObservedObject var model: MenuPopoverModel

  var body: some View {
    if self.model.menuItemStyle == .hide {
      EmptyView()
    } else {
      HStack(spacing: 16) {
        Button { self.performAction { app.prefsClicked(app as AnyObject) } } label: {
          Image(systemName: "gearshape")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .help(NSLocalizedString("Settings…", comment: "Shown in menu"))

        Button { self.performAction { app.updaterController.checkForUpdates(nil) } } label: {
          Image(systemName: "arrow.triangle.2.circlepath.circle")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .help(NSLocalizedString("Check for updates…", comment: "Shown in menu"))

        Button { self.performAction { app.quitClicked(app as AnyObject) } } label: {
          Image(systemName: "xmark.circle")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .help(NSLocalizedString("Quit", comment: "Shown in menu"))
      }
      .modifier(GlassCard())
    }
  }

  private func performAction(_ action: () -> Void) {
    action()
    if let controller = app.menuPopoverController as? MenuPopoverController {
      controller.closePopover()
    }
  }
}
