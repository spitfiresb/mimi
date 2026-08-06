import ServiceManagement

/// Registers Mimi to launch at login.
///
/// A push-to-talk app that isn't running is just a missing key. This has to be on
/// by default or the hotkey silently does nothing after every reboot.
///
/// Registration is keyed to the bundle's current location — moving `Mimi.app`
/// invalidates it and it has to be re-registered from the new path.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
