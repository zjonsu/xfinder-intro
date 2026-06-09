import Foundation

enum PaneSide {
    case left, right
    var other: PaneSide { self == .left ? .right : .left }
}

enum ViewMode: String, CaseIterable {
    case full      // Name / Size / Modified columns (list)
    case icon      // large-icon grid with thumbnails

    var label: String { self == .full ? "목록" : "아이콘" }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, ext, size, modified, created, kind

    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .ext: return "Ext"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .kind: return "Kind"
        }
    }
}

extension Array where Element == FileItem {
    /// Sort respecting NC conventions: ".." first, then folders before files, then by key.
    func sorted(by key: SortKey, ascending: Bool) -> [FileItem] {
        sorted { a, b in
            if a.isParent != b.isParent { return a.isParent }
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            let result: Bool
            switch key {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .ext:
                if a.ext == b.ext {
                    result = a.name.localizedStandardCompare(b.name) == .orderedAscending
                } else {
                    result = a.ext.localizedStandardCompare(b.ext) == .orderedAscending
                }
            case .size:
                if a.size == b.size {
                    result = a.name.localizedStandardCompare(b.name) == .orderedAscending
                } else {
                    result = a.size < b.size
                }
            case .modified:
                if a.modified == b.modified {
                    result = a.name.localizedStandardCompare(b.name) == .orderedAscending
                } else {
                    result = a.modified < b.modified
                }
            case .created:
                if a.created == b.created {
                    result = a.name.localizedStandardCompare(b.name) == .orderedAscending
                } else {
                    result = a.created < b.created
                }
            case .kind:
                let ka = Format.kindLabel(a), kb = Format.kindLabel(b)
                if ka == kb {
                    result = a.name.localizedStandardCompare(b.name) == .orderedAscending
                } else {
                    result = ka.localizedStandardCompare(kb) == .orderedAscending
                }
            }
            return ascending ? result : !result
        }
    }
}
