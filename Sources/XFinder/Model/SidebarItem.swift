import Foundation
import Observation

/// One row in the Finder-style sidebar. Folder rows are selectable and expandable into a tree;
/// special rows (AirDrop, the computer) have bespoke behaviour.
@Observable
final class SidebarItem: Identifiable {
    enum Kind {
        case folder        // a real directory: selectable + expandable
        case computer      // the Mac: selects "/" and lists volumes
        case airDrop       // opens AirDrop via Finder
        case trash         // the Trash folder
        case recents       // recently-used files (Spotlight)
        case tag           // a Finder color tag — clicking filters files with that tag
    }

    let id = UUID()
    let title: String
    let icon: String           // SF Symbol name
    let url: URL?              // backing directory (nil for AirDrop)
    let kind: Kind
    let depth: Int            // indentation level in the tree

    var isExpanded = false
    var children: [SidebarItem]? = nil   // nil = not loaded yet
    var hasCheckedChildren = false
    var mayHaveChildren = true            // drives whether a disclosure triangle is shown

    init(title: String, icon: String, url: URL?, kind: Kind, depth: Int = 0, hasChildren: Bool = true) {
        self.title = title
        self.icon = icon
        self.url = url
        self.kind = kind
        self.depth = depth
        self.mayHaveChildren = hasChildren
    }

    var isSelectable: Bool { url != nil }
    var canExpand: Bool { (kind == .folder || kind == .computer) && mayHaveChildren }

    /// Lazily load child folders one level deep.
    func loadChildren(showHidden: Bool) {
        guard let url, children == nil else { return }
        let subs: [URL]
        if kind == .computer {
            subs = FileSystemService.subfolders(of: URL(fileURLWithPath: "/Volumes"), showHidden: showHidden)
        } else {
            subs = FileSystemService.subfolders(of: url, showHidden: showHidden)
        }
        children = subs.map { sub in
            // Only show a disclosure triangle when the child actually contains sub-folders, and use
            // a filled folder icon to distinguish "has sub-folders" from a leaf folder.
            let hasKids = FileSystemService.hasSubfolders(sub, showHidden: showHidden)
            return SidebarItem(title: sub.lastPathComponent,
                               icon: hasKids ? "folder.fill" : "folder",
                               url: sub, kind: .folder, depth: depth + 1, hasChildren: hasKids)
        }
    }
}

/// A titled group of sidebar rows ("즐겨찾기", "위치", …).
struct SidebarSection: Identifiable {
    let id = UUID()
    let title: String
    var items: [SidebarItem]
}
