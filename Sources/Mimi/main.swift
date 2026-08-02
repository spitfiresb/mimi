import AppKit

// Top-level code runs on the main thread, but isn't statically main-actor
// isolated. Held in a global so NSApplication's weak `delegate` doesn't drop it.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
