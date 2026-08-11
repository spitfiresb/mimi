import AppKit
import CoreGraphics

/// Inserts text into whatever app has focus, via the pasteboard plus a
/// synthesized ⌘V, restoring the user's clipboard afterwards.
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9

    /// How long to leave our text on the pasteboard before putting the user's
    /// clipboard back.
    ///
    /// Reading the pasteboard after ⌘V is asynchronous and entirely the target
    /// app's business, so this is a race we can only lose loudly: restore too
    /// early and the app pastes *the previous clipboard contents*. At 150ms that
    /// happened for real — a 50MB screenshot (TIFF + BMP + PNG + seven other
    /// representations) got pasted instead of the transcript, because snapshot,
    /// write, and restore of that much data all had to finish inside the window
    /// (2026-08-11). Generous now that waiting costs the dictation nothing.
    private static let restoreDelay = Duration.milliseconds(1200)

    static func insert(_ text: String) async {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount

        // The user may still be holding ⌃⌥ from the hotkey. Physical modifiers
        // merge with synthesized ones, which would turn our ⌘V into ⌃⌥⌘V.
        await waitForModifiersToClear()
        postPaste()

        // Off the critical path: the dictation is finished the moment ⌘V is
        // posted, so the user should never wait on clipboard housekeeping.
        Task.detached {
            try? await Task.sleep(for: restoreDelay)
            await MainActor.run {
                let board = NSPasteboard.general
                // Someone copied something while we waited — theirs wins.
                guard board.changeCount == ours else { return }
                restore(snapshot, to: board)
            }
        }
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
