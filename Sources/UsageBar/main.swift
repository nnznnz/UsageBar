import AppKit
import UsageBarKit

// UsageBar entrypoint.
//
// `.accessory` activation policy makes this a menu-bar-only app: it lives in the
// status bar, shows no Dock icon, and has no main window. All behavior lives in
// UsageBarKit; this executable just wires AppController into NSApplication.

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
