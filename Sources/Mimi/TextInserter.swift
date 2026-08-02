import AppKit
import CoreGraphics

/// Inserts text into whatever app has focus, via the pasteboard plus a
/// synthesized ⌘V, restoring the user's clipboard afterwards.
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9

    /// How long to wait after ⌘V before putting the old clipboard back.
    /// Too short and the target app reads stale pasteboard data.
    private static let restoreDelay = Duration.milliseconds(150)

    static func insert(_ text: String) async {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // The user may still be holding ⌃⌥ from the hotkey. Physical modifiers
        // merge with synthesized ones, which would turn our ⌘V into ⌃⌥⌘V.
        await waitForModifiersToClear()
        postPaste()

        try? await Task.sleep(for: restoreDelay)
        restore(snapshot, to: pasteboard)
    }

    private static func waitForModifiersToClear() async {
        let interfering: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        for _ in 0..<80 {  // ~800ms ceiling
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(interfering).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func postPaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = HotkeyMonitor.syntheticMarker

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    private static func restore(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }

        let items = snapshot.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
