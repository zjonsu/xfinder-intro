import AppKit

/// A single, focus-independent keyboard handler for the main window. A local key-down monitor
/// receives every key press regardless of which SwiftUI view holds focus, so navigation and
/// shortcuts work consistently (NavigationSplitView focus quirks would otherwise swallow them).
enum KeyboardMonitor {
    static func install(app: AppModel) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            // Multi-window: every window installs a monitor, but each event belongs to one window.
            // Ignore events for other windows so only the key window's model reacts.
            if let w = app.window, let ew = event.window, ew !== w { return event }

            // Mouse side buttons: thumb-button 3 → back, 4 → forward (matches macOS convention).
            // Suppressed while any dialog/sheet is up so navigation can't fire behind it.
            if event.type == .otherMouseDown {
                guard app.confirm == nil, app.sheet == nil,
                      app.errorMessage == nil, app.infoMessage == nil else { return event }
                switch event.buttonNumber {
                case 3: app.goBack();    return nil
                case 4: app.goForward(); return nil
                default: return event
                }
            }

            // Confirmation dialog: arrow/Tab move focus between buttons, Return runs the focused one,
            // Esc cancels. Swallow other keys so the list behind doesn't react.
            if app.confirm != nil {
                switch event.keyCode {
                case 123, 126: app.moveConfirmFocus(-1); return nil  // ← / ↑
                case 124, 125, 48: app.moveConfirmFocus(1); return nil  // → / ↓ / Tab
                case 36, 76: app.executeConfirmFocus(); return nil   // Return / Enter
                case 53: app.cancelConfirm(); return nil             // Esc
                default: return nil
                }
            }

            // Let other dialogs and text editing handle their own keys.
            if app.sheet != nil || app.errorMessage != nil || app.infoMessage != nil {
                return event
            }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }

            let flags = event.modifierFlags
            let cmd = flags.contains(.command)
            let shift = flags.contains(.shift)
            let ctrl = flags.contains(.control)
            let opt = flags.contains(.option)
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

            // ⌃M — toggle list / icon view
            if ctrl && !cmd {
                if chars == "m" { app.toggleViewMode(); return nil }
                return event
            }

            if cmd {
                // Replicate the standard window/app shortcuts so the monitor never swallows them.
                switch chars {
                case "q": NSApp.terminate(nil); return nil
                case "w" where !shift: NSApp.keyWindow?.performClose(nil); return nil
                case "m" where !shift: NSApp.keyWindow?.miniaturize(nil); return nil
                default: break
                }
                switch event.keyCode {
                case 126: app.goUp();           return nil  // ⌘↑  parent
                case 125: app.openSelected();   return nil  // ⌘↓  open
                case 123: app.goBack();         return nil  // ⌘←  back
                case 124: app.goForward();      return nil  // ⌘→  forward
                case 51:  app.requestDelete();  return nil  // ⌘⌫  trash
                default: break
                }
                switch chars {
                case "c" where opt && !shift: app.copySelectedPath(); return nil  // ⌥⌘C  경로 복사
                case "c" where !shift: app.copySelection();     return nil  // ⌘C
                case "x" where !shift: app.cutSelection();      return nil  // ⌘X
                case "v" where !shift: app.paste();             return nil  // ⌘V
                case "d" where !shift: app.duplicate();         return nil  // ⌘D
                case "r" where !shift: app.refresh();           return nil  // ⌘R
                case "n" where shift:  app.requestNewFolder();  return nil  // ⇧⌘N
                case "g" where shift:  app.requestGoToFolder(); return nil  // ⇧⌘G
                case "[":              app.goBack();            return nil  // ⌘[
                case "]":              app.goForward();         return nil  // ⌘]
                case "." where shift:  app.toggleHidden();      return nil  // ⇧⌘.
                default: return event   // let ⌘A / menu shortcuts through
                }
            }

            // Tab toggles which pane the keyboard drives (sidebar ⇄ detail list).
            if event.keyCode == 48 && !ctrl {   // Tab / ⇧Tab
                app.toggleFocusedPane()
                return nil
            }

            // When the sidebar holds focus, arrows move through 즐겨찾기 / 위치 instead of the list.
            if app.focusedPane == .sidebar {
                switch event.keyCode {
                case 126: app.moveSidebarSelection(by: -1);  return nil  // ↑
                case 125: app.moveSidebarSelection(by: 1);   return nil  // ↓
                case 124: app.expandSidebarSelection();      return nil  // →  expand / into child
                case 123: app.collapseSidebarSelection();    return nil  // ←  collapse / to parent
                case 36, 76: app.activateSelectedSidebar();  return nil  // Return → open & focus list
                case 49: app.activateSelectedSidebar();      return nil  // Space → open & focus list
                default: return event
                }
            }

            // Shift+arrows: extend the multi-selection (range select).
            if shift && !cmd {
                switch event.keyCode {
                case 126: app.extendCursor(by: -1);  return nil  // ⇧↑
                case 125: app.extendCursor(by: 1);   return nil  // ⇧↓
                case 116: app.extendCursor(by: -15); return nil  // ⇧PageUp
                case 121: app.extendCursor(by: 15);  return nil  // ⇧PageDown
                case 115: app.extendCursorToTop();    return nil  // ⇧Home
                case 119: app.extendCursorToBottom(); return nil  // ⇧End
                default: break
                }
            }

            // No modifiers: cursor navigation, opening, and function keys.
            switch event.keyCode {
            case 126: app.moveCursor(by: -1);  return nil  // ↑
            case 125: app.moveCursor(by: 1);   return nil  // ↓
            case 116: app.moveCursor(by: -15); return nil  // Page Up
            case 121: app.moveCursor(by: 15);  return nil  // Page Down
            case 115: app.cursorToTop();       return nil  // Home
            case 119: app.cursorToBottom();    return nil  // End
            case 36, 76: app.openCursorItem(); return nil  // Return / Enter
            case 49: app.viewSelected();       return nil  // Space → Quick Look
            case 51: app.goUp();               return nil  // Backspace → parent
            case 120: app.requestRename();     return nil  // F2  rename
            case 99:  app.viewSelected();      return nil  // F3  view
            case 118: app.editSelected();      return nil  // F4  open with default app
            case 96:  app.refresh();           return nil  // F5  refresh
            default: return event
            }
        }
    }

    static func remove(_ token: Any?) {
        if let token { NSEvent.removeMonitor(token) }
    }
}
