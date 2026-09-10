import AppKit

let application = NSApplication.shared
let delegate = OpenLaunchpadAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
