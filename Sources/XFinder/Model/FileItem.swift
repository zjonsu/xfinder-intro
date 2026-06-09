import Foundation

/// A single entry shown in a panel (file, folder, symlink, or the synthetic ".." parent).
struct FileItem: Identifiable, Hashable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
    var isHidden: Bool
    var size: Int64          // bytes; -1 when unknown (e.g. folders we haven't measured)
    var modified: Date
    var ext: String          // lowercased extension without the dot; "" for none / folders
    var isParent: Bool       // the ".." row
    var created: Date = .distantPast    // 생성일
    var typeName: String = ""           // 종류(현지화된 설명, 예: "PDF 문서"); 빈 값이면 Format.kind로 대체

    var id: URL { url }

    /// A package/app bundle (e.g. .app) is a directory but should open like a file by default.
    var isBundle: Bool {
        isDirectory && !ext.isEmpty && ["app", "bundle", "framework", "rtfd", "playground"].contains(ext)
    }

    static func parent(of directory: URL) -> FileItem {
        FileItem(
            url: directory.deletingLastPathComponent(),
            name: "..",
            isDirectory: true,
            isSymlink: false,
            isHidden: false,
            size: -1,
            modified: .distantPast,
            ext: "",
            isParent: true
        )
    }
}

// MARK: - Display formatting

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func size(_ bytes: Int64, isDirectory: Bool) -> String {
        if bytes < 0 { return "--" }   // not yet computed / unknown (folders show -- until measured)
        return byteFormatter.string(fromByteCount: bytes)
    }

    static func date(_ date: Date) -> String {
        if date == .distantPast { return "" }
        return dateFormatter.string(from: date)
    }

    static func kind(_ item: FileItem) -> String {
        if item.isParent { return "" }
        if item.isSymlink { return "Alias" }
        if item.isBundle { return item.ext.uppercased() }
        if item.isDirectory { return "Folder" }
        return item.ext.isEmpty ? "File" : item.ext.uppercased()
    }

    /// 종류 컬럼 표시값: 현지화된 설명(예: "PDF 문서")이 있으면 그것을, 없으면 `kind`로 대체.
    static func kindLabel(_ item: FileItem) -> String {
        if item.isParent { return "" }
        return item.typeName.isEmpty ? kind(item) : item.typeName
    }
}
