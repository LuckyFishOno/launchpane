import AppKit

// The embedded agent owns all long-lived OpenLaunchpad UI state.
//
// It is an LSUIElement/accessory application:
// - no Dock running application
// - no normal application menu bar
// - still allowed to activate and present interactive windows

let application = NSApplication.shared
let delegate = OpenLaunchpadAppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
