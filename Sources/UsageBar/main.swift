import AppKit

// UsageBar entrypoint.
//
// `.accessory` activation policy makes this a menu-bar-only app: it lives in the
// status bar, shows no Dock icon, and has no main window. Everything the user
// interacts with hangs off the status item built in AppController.

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
