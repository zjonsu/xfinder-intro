import SwiftUI
import AppKit

/// Makes a file row / icon cell a drag source so its file(s) can be dragged out of the app and dropped
/// into other apps (KakaoTalk, Mail, Notes, Finder, the Desktop, …) to *copy* them.
///
/// SwiftUI's native `.onDrag` only carries one item and tends to fight the row's tap gesture, so the
/// drag is done in AppKit. A thin overlay `NSView` claims only the left mouse button:
///   • a press that doesn't move is forwarded as a normal click (`onClick`) → selection / open;
///   • a press that moves starts a real dragging session for every selected file (`urls`);
///   • right-click (context menu), scroll and hover report "no hit" so they reach the SwiftUI views
///     beneath the overlay untouched.
struct FileDrag: ViewModifier {
    /// Whether this row was part of the selection *before* the press — if so a drag MOVES the selected
    /// files; otherwise a drag rubber-band-selects. Evaluated live so it tracks selection changes.
    let canDrag: () -> Bool
    /// Evaluated at drag start so it reflects the current selection.
    let urls: () -> [URL]
    /// Called on mouse-UP that didn't move (a plain click). Used for collapse-to-single / sidebar nav.
    let onClick: () -> Void
    /// Called the instant the mouse goes *down* so selection feels immediate, like Finder. When set,
    /// this row claims every left press (not only already-selected rows). Mouse handling is NON-blocking
    /// so the selection repaints right away instead of waiting for mouse-up.
    var onPress: (() -> Void)? = nil
    /// Called while dragging on a *non*-draggable (unselected) row to rubber-band select; the argument
    /// is how far the mouse moved downward from the press, in points.
    var onRubberBand: ((CGFloat) -> Void)? = nil

    func body(content: Content) -> some View {
        content.overlay {
            DragSource(canDrag: canDrag, urls: urls, onClick: onClick, onPress: onPress, onRubberBand: onRubberBand)
        }
    }
}

private struct DragSource: NSViewRepresentable {
    let canDrag: () -> Bool
    let urls: () -> [URL]
    let onClick: () -> Void
    let onPress: (() -> Void)?
    let onRubberBand: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.canDrag = canDrag
        view.urls = urls
        view.onClick = onClick
        view.onPress = onPress
        view.onRubberBand = onRubberBand
    }

    final class SourceView: NSView, NSDraggingSource {
        var canDrag: (() -> Bool)?
        var urls: (() -> [URL])?
        var onClick: (() -> Void)?
        var onPress: (() -> Void)?
        var onRubberBand: ((CGFloat) -> Void)?

        private var startWindow: NSPoint = .zero
        private var wasDraggable = false       // captured at mouse-down, BEFORE selection changes
        private var dragging = false

        // Allow a click/drag to act even when the window wasn't already focused.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Claim the *initial* left press. With `onPress`/`onRubberBand` set we claim every press (so we
        /// can select on mouse-down and rubber-band, Finder-style); otherwise only draggable rows. Right-
        /// click, scroll, hover and drag-and-drop hovering all fall through to the SwiftUI content below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
            guard onPress != nil || onRubberBand != nil || canDrag?() == true else { return nil }
            return super.hitTest(point)
        }

        // Non-blocking: handle down/dragged/up as separate events so the runloop keeps spinning and the
        // selection set on mouse-down paints immediately (the old nextEvent pull loop froze repaint).
        override func mouseDown(with event: NSEvent) {
            wasDraggable = canDrag?() == true     // was this row already selected? (decides move vs rubber-band)
            startWindow = event.locationInWindow
            dragging = false
            onPress?()                            // select instantly
        }

        override func mouseDragged(with event: NSEvent) {
            let p = event.locationInWindow
            if !dragging && hypot(p.x - startWindow.x, p.y - startWindow.y) <= 4 { return }
            if wasDraggable {
                if !dragging { dragging = true; beginDrag(with: event) }   // move the selected file(s)
            } else if let onRubberBand {
                dragging = true
                onRubberBand(startWindow.y - p.y)   // downward distance (window y is bottom-up)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if !dragging { onClick?() }            // a plain click (no drag)
            dragging = false
        }

        private func beginDrag(with event: NSEvent) {
            let files = urls?() ?? []
            guard !files.isEmpty else { return }
            let iconSize = NSSize(width: 32, height: 32)
            let origin = convert(event.locationInWindow, from: nil)
            let items: [NSDraggingItem] = files.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = iconSize
                let shift = CGFloat(index) * 6   // fan the stack out a little for multi-file drags
                let frame = NSRect(x: origin.x - iconSize.width / 2 + shift,
                                   y: origin.y - iconSize.height / 2 - shift,
                                   width: iconSize.width, height: iconSize.height)
                item.setDraggingFrame(frame, contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        // Inside the app, allow both so a folder can request a move; to other apps, copy only
        // (so dragging out never removes the original).
        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? [.copy, .move] : .copy
        }
    }
}
