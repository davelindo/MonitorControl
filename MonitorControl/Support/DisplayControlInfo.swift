import Cocoa
import IOKit

enum DisplayControlInfoProvider {
  struct Info {
    var displayType: String
    var displayImage: String
    var controlMethod: String
    var controlStatus: String
  }

  static func info(for display: Display) -> Info {
    var displayType = NSLocalizedString("Other Display", comment: "Shown in the Display Settings")
    var displayImage = "display.trianglebadge.exclamationmark"
    var controlMethod = NSLocalizedString("No Control", comment: "Shown in the Display Settings") + "  ⚠️"
    var controlStatus = NSLocalizedString("This display has an unspecified control status.", comment: "Shown in the Display Settings")

    if display.isVirtual, !display.isDummy {
      displayType = NSLocalizedString("Virtual Display", comment: "Shown in the Display Settings")
      displayImage = "tv.and.mediabox"
      controlMethod = NSLocalizedString("Software (shade)", comment: "Shown in the Display Settings") + "  ⚠️"
      controlStatus = NSLocalizedString(
        "This is a virtual display (examples: AirPlay, Sidecar, display connected via a DisplayLink Dock or similar) which does not allow hardware or software gammatable control. Shading is used as a substitute but only in non-mirror scenarios. Mouse cursor will be unaffected and artifacts may appear when entering/leaving full screen mode.",
        comment: "Shown in the Display Settings"
      )
    } else if display is OtherDisplay, !display.isDummy {
      displayType = NSLocalizedString("External Display", comment: "Shown in the Display Settings")
      displayImage = "display"
      if let otherDisplay = display as? OtherDisplay {
        if otherDisplay.isSwOnly() {
          if otherDisplay.readPrefAsBool(key: .avoidGamma) {
            controlMethod = NSLocalizedString("Software (shade)", comment: "Shown in the Display Settings") + "  ⚠️"
          } else {
            controlMethod = NSLocalizedString("Software (gamma)", comment: "Shown in the Display Settings") + "  ⚠️"
          }
          displayImage = "display.trianglebadge.exclamationmark"
          controlStatus = NSLocalizedString(
            "This display allows for software brightness control via gamma table manipulation or shade as it does not support hardware control. Reasons for this might be using the HDMI port of a Mac mini (which blocks hardware DDC control) or having a blacklisted display.",
            comment: "Shown in the Display Settings"
          )
        } else {
          if otherDisplay.isSw() {
            if otherDisplay.readPrefAsBool(key: .avoidGamma) {
              controlMethod = NSLocalizedString("Software (shade, forced)", comment: "Shown in the Display Settings")
            } else {
              controlMethod = NSLocalizedString("Software (gamma, forced)", comment: "Shown in the Display Settings")
            }
            controlStatus = NSLocalizedString(
              "This display is reported to support hardware DDC control but the current settings allow for software control only.",
              comment: "Shown in the Display Settings"
            )
          } else {
            controlMethod = NSLocalizedString("Hardware (DDC)", comment: "Shown in the Display Settings")
            controlStatus = NSLocalizedString(
              "This display is reported to support hardware DDC control. If you encounter issues, you can disable hardware DDC control to force software control.",
              comment: "Shown in the Display Settings"
            )
          }
        }
      }
    } else if !display.isDummy, let appleDisplay = display as? AppleDisplay {
      if appleDisplay.isBuiltIn() {
        displayType = NSLocalizedString("Built-in Display", comment: "Shown in the Display Settings")
        displayImage = Self.isImac() ? "desktopcomputer" : "laptopcomputer"
      } else {
        displayType = NSLocalizedString("External Display", comment: "Shown in the Display Settings")
        displayImage = "display"
      }
      controlMethod = NSLocalizedString("Hardware (Apple)", comment: "Shown in the Display Settings")
      controlStatus = NSLocalizedString(
        "This display supports native Apple brightness protocol. This allows macOS to control this display without MonitorControl as well.",
        comment: "Shown in the Display Settings"
      )
    }

    return Info(
      displayType: displayType,
      displayImage: displayImage,
      controlMethod: controlMethod,
      controlStatus: controlStatus
    )
  }

  private static func isImac() -> Bool {
    let platformExpertDevice = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard platformExpertDevice != 0 else {
      return false
    }
    defer {
      IOObjectRelease(platformExpertDevice)
    }
    guard let modelIdentifier = IORegistryEntryCreateCFProperty(platformExpertDevice, "model" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
    else {
      return false
    }
    return modelIdentifier.contains("iMac")
  }
}
