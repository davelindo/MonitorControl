import AppKit
import SwiftUI

@available(macOS 10.15, *)
final class MenuPopoverController: NSObject, NSPopoverDelegate {
  private let popover: NSPopover
  private let model: MenuPopoverModel
  private var hostingController: NSHostingController<MenuPopoverView>
  private let minContentSize = NSSize(width: 280, height: 120)
  private let maxContentSize = NSSize(width: 360, height: 420)
  private let fallbackContentSize = NSSize(width: 340, height: 320)
  private var sessionID: Int = 0

  override init() {
    self.model = MenuPopoverModel()
    self.hostingController = NSHostingController(rootView: MenuPopoverView(model: self.model, sessionID: 0))
    self.popover = NSPopover()
    super.init()
    // Install callback after init so the closure can safely capture `self`.
    self.sessionID = 1
    self.hostingController = NSHostingController(rootView: self.makeRootView(sessionID: self.sessionID))
    self.popover.contentViewController = self.hostingController
    self.popover.behavior = .transient
    self.popover.animates = true
    self.popover.delegate = self
    self.popover.contentSize = self.fallbackContentSize
  }

  private func makeRootView(sessionID: Int) -> MenuPopoverView {
    MenuPopoverView(
      model: self.model,
      sessionID: sessionID,
      requestContentSizeUpdate: nil
    )
  }

  private var sizingScreen: NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? app.statusItem.button?.window?.screen
      ?? NSScreen.main
  }

  private func contentSizeLimits(for screen: NSScreen?) -> (min: NSSize, max: NSSize) {
    guard let screen else {
      return (self.minContentSize, self.maxContentSize)
    }
    // Keep some margin for the popover arrow/shadow and avoid running off-screen on small displays.
    let visible = screen.visibleFrame.size
    let horizontalMargin: CGFloat = 48
    let verticalMargin: CGFloat = 140

    let maxWidth = min(self.maxContentSize.width, max(self.minContentSize.width, visible.width - horizontalMargin), visible.width)
    let maxHeight = min(self.maxContentSize.height, max(self.minContentSize.height, visible.height - verticalMargin), visible.height)
    let minWidth = min(self.minContentSize.width, maxWidth)
    let minHeight = min(self.minContentSize.height, maxHeight)
    return (NSSize(width: minWidth, height: minHeight), NSSize(width: maxWidth, height: maxHeight))
  }

  func attach(to statusItem: NSStatusItem) {
    statusItem.button?.target = self
    statusItem.button?.action = #selector(self.togglePopover(_:))
  }

  func updateStatusItemVisibility() {
    let menuIconPref = prefs.integer(forKey: PrefKey.menuIcon.rawValue)
    let lgActive = DisplayManager.shared.isLGActive()
    if !lgActive {
      if DisplayManager.shared.isInLaunchMenuGracePeriod() {
        app.updateStatusItemVisibility(true)
      } else {
        self.closePopover()
        app.updateStatusItemVisibility(false)
      }
      return
    }
    var showIcon = false
    if menuIconPref == MenuIcon.show.rawValue {
      showIcon = true
    } else if menuIconPref == MenuIcon.externalOnly.rawValue {
      showIcon = !DisplayManager.shared.getLGDisplays().isEmpty
    } else if menuIconPref == MenuIcon.sliderOnly.rawValue {
      showIcon = MenuPopoverModel.hasAnySliders()
    }
    app.updateStatusItemVisibility(showIcon)
  }

  private func fixedContentSize(for screen: NSScreen?) -> NSSize {
    // Dynamic sizing based on NSHostingView.fittingSize is unreliable with SwiftUI ScrollView
    // inside NSPopover (it can reopen positioned incorrectly / appear blank). Use a stable
    // size and rely on internal scrolling, but keep it compact when content is small.
    let (minSize, maxSize) = self.contentSizeLimits(for: screen)

    let width = min(max(self.fallbackContentSize.width, minSize.width), maxSize.width)
    let desiredHeight = self.desiredHeight(maxHeight: maxSize.height)
    let height = min(max(desiredHeight, minSize.height), maxSize.height)
    return NSSize(width: width, height: height)
  }

  private func desiredHeight(maxHeight: CGFloat) -> CGFloat {
    // Heuristic sizing: enough to show header + a few items without scrolling, but not the
    // full max height when only 0-1 cards/sliders exist.
    if !self.model.isLGActive || self.model.isInLaunchGrace {
      return 240
    }

    // If the user hides menu actions, the footer is removed; keep the popover tighter.
    let baseHeight: CGFloat = self.model.menuItemStyle == .hide ? 160 : 200

    let itemCount: Int
    switch self.model.sliderMode {
    case .combine:
      itemCount = self.model.combinedCommands.count
      if itemCount == 0 { return baseHeight + 40 }
      // Header/footer + "All Displays" card + a few sliders (prefer scrolling once content grows).
      return min(maxHeight, baseHeight + 40 + CGFloat(min(itemCount, 4)) * 44)
    case .relevant, .separate:
      itemCount = self.model.displaySections.count
      if itemCount == 0 { return baseHeight + 40 }
      // Header/footer + up to 2 display cards; scroll for the rest to keep the popover compact.
      return min(maxHeight, baseHeight + CGFloat(min(itemCount, 2)) * 110)
    }
  }

  @objc func togglePopover(_: Any?) {
    if self.popover.isShown {
      self.closePopover()
    } else {
      self.showPopover()
    }
  }

  func showPopover() {
    guard let button = app.statusItem.button else {
      return
    }
    // If the popover opens as non-activating/inactive, macOS will visibly change the popover
    // material when the user first clicks inside (as it becomes active/key). Activate up-front
    // so the popover renders in its final visual state immediately.
    NSApp.activate(ignoringOtherApps: true)

    self.sessionID &+= 1
    // Create a fresh hosting controller for each show. SwiftUI's underlying NSScrollView
    // can retain an out-of-range offset across popover closes, causing a blank view on reopen.
    self.hostingController = NSHostingController(rootView: self.makeRootView(sessionID: self.sessionID))
    self.popover.contentViewController = self.hostingController
    self.model.start()
    let screen = button.window?.screen ?? self.sizingScreen
    self.popover.contentSize = self.fixedContentSize(for: screen)
    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    self.constrainPopoverWindowToScreen(screen: screen)
    self.forcePopoverVibrancyActive()

    // Ensure the popover window becomes key once shown (helps keep vibrancy/material stable).
    DispatchQueue.main.async { [weak self] in
      self?.popover.contentViewController?.view.window?.makeKey()
    }
  }

  func closePopover() {
    self.popover.performClose(nil)
    self.model.stop()
  }

  func popoverDidClose(_: Notification) {
    self.model.stop()
  }

  func popoverDidShow(_: Notification) {
    // Some popover internals are created after `show(...)`; apply again after the window exists.
    self.forcePopoverVibrancyActive()
  }

  private func constrainPopoverWindowToScreen(screen: NSScreen?) {
    // NSPopover can occasionally reopen positioned partially off-screen on multi-monitor
    // setups (or after content/view controller swaps). Clamp the resulting popover window
    // to the active screen's visible frame.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
      guard let self else { return }
      guard let window = self.popover.contentViewController?.view.window else { return }
      guard let targetScreen = screen ?? window.screen ?? self.sizingScreen else { return }
      let constrained = window.constrainFrameRect(window.frame, to: targetScreen)
      guard constrained != window.frame else { return }
      window.setFrame(constrained, display: false)
    }
  }

  private func forcePopoverVibrancyActive() {
    // NSPopover's background/vibrancy can look different when the popover becomes key (after the
    // first click). Force visual effect views into a stable "active" state so opacity doesn't
    // visibly change on interaction.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let window = self.popover.contentViewController?.view.window else { return }
      guard let rootView = window.contentView else { return }
      self.setVisualEffectStateActive(in: rootView)
    }
  }

  private func setVisualEffectStateActive(in view: NSView) {
    if let effectView = view as? NSVisualEffectView {
      effectView.state = .active
    }
    for subview in view.subviews {
      self.setVisualEffectStateActive(in: subview)
    }
  }
}
