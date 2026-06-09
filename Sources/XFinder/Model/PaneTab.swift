import Foundation
import Observation

/// State for a single tab inside a panel: where it points, what it shows, what's selected.
@Observable
final class PaneTab: Identifiable {
    let id = UUID()

    var directory: URL

    /// Raw, unfiltered directory listing (excluding the ".." row).
    var rawItems: [FileItem] = []
    /// What the table actually displays (filtered + sorted, with ".." prepended when applicable).
    var items: [FileItem] = []

    /// Marked / selected files (Norton-Commander style marks == multi-selection).
    var selection: Set<URL> = []
    /// The focused row (keyboard cursor).
    var cursor: URL?
    /// Anchor for range selection (Shift+arrow / Shift+click).
    var selectionAnchor: URL?

    var sortKey: SortKey = .name
    var sortAscending: Bool = true
    var filter: String = ""
    var viewMode: ViewMode = .full
    var loadError: String?
    /// True while `items` holds recursive search results (not the plain directory listing).
    var searchMode: Bool = false
    /// True while `items` holds the system "Recents" list (not a directory listing).
    var recentsMode: Bool = false
    /// True while `items` holds files filtered by a Finder tag. `tagName` is the active tag.
    var tagMode: Bool = false
    var tagName: String?

    init(directory: URL) {
        self.directory = directory
    }

    var title: String {
        if directory.path == "/" { return "/" }
        let name = directory.lastPathComponent
        return name.isEmpty ? directory.path : name
    }

    var isAtRoot: Bool { directory.path == "/" }

    /// Recompute `items` from `rawItems` applying hidden-filter, text-filter and sort.
    func rebuild(showHidden: Bool) {
        // While searching / Recents / tag-filtering, `items` is managed by AppModel, not from rawItems.
        if searchMode || recentsMode || tagMode { return }
        var visible = rawItems
        if !showHidden {
            visible.removeAll { $0.isHidden }
        }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            visible = visible.filter { $0.name.lowercased().contains(needle) }
        }
        visible = visible.sorted(by: sortKey, ascending: sortAscending)

        // Finder-style detail list: no ".." row (navigation happens via the sidebar / toolbar).
        items = visible

        // Keep cursor valid.
        if let c = cursor, !items.contains(where: { $0.url == c }) {
            cursor = items.first?.url
        } else if cursor == nil {
            cursor = items.first?.url
        }
        // Drop selection entries that no longer exist.
        let present = Set(items.map(\.url))
        selection.formIntersection(present)
    }

    /// Items that an operation should act on: the marked set, or the cursor row if nothing is marked.
    func actionTargets() -> [FileItem] {
        let marked = items.filter { selection.contains($0.url) && !$0.isParent }
        if !marked.isEmpty { return marked }
        if let c = cursor, let item = items.first(where: { $0.url == c }), !item.isParent {
            return [item]
        }
        return []
    }

    func toggleMark(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }
}
