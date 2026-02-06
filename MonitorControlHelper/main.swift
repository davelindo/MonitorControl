import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_: Notification) {
    let mainBundleID = Bundle.main.bundleIdentifier!.replacingOccurrences(of: "Helper", with: "")

    let bundlePath = Bundle.main.bundlePath as NSString

    guard NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID).isEmpty else {
      return NSApp.terminate(self)
    }

    let pathComponents = bundlePath.pathComponents
    let path = NSString.path(withComponents: Array(pathComponents[0 ..< (pathComponents.count - 4)]))

    let appURL = URL(fileURLWithPath: path)
    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
      NSApp.terminate(nil)
    }
  }

  func applicationWillTerminate(_: Notification) {}
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
