import Foundation

/// Reads directory contents into `FileItem` values.
enum FileSystemService {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        .isHiddenKey, .isSymbolicLinkKey, .nameKey,
        .creationDateKey, .localizedTypeDescriptionKey
    ]
    private static let resourceKeySet = Set(resourceKeys)

    static func list(_ directory: URL) -> Result<[FileItem], Error> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: []          // include hidden entries; the model decides what to show
            )
            let items = urls.map { url -> FileItem in
                let v = try? url.resourceValues(forKeys: resourceKeySet)
                let isDir = v?.isDirectory ?? false
                return FileItem(
                    url: url,
                    name: v?.name ?? url.lastPathComponent,
                    isDirectory: isDir,
                    isSymlink: v?.isSymbolicLink ?? false,
                    isHidden: v?.isHidden ?? url.lastPathComponent.hasPrefix("."),
                    size: isDir ? -1 : Int64(v?.fileSize ?? 0),
                    modified: v?.contentModificationDate ?? .distantPast,
                    ext: url.pathExtension.lowercased(),
                    isParent: false,
                    created: v?.creationDate ?? .distantPast,
                    typeName: v?.localizedTypeDescription ?? ""
                )
            }
            return .success(items)
        } catch {
            return .failure(error)
        }
    }

    /// Recursively search `root` (and all descendants) for entries whose name contains `needle`
    /// (case-insensitive). Folders are listed before files. Potentially slow — call off the main
    /// thread. `limit` caps the result count to keep large trees responsive.
    static func searchRecursive(root: URL, needle: String, showHidden: Bool, limit: Int = 1000) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isSymbolicLinkKey, .nameKey, .isHiddenKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, _ in true }
        ) else { return [] }

        var out: [FileItem] = []
        for case let url as URL in enumerator {
            if out.count >= limit { break }
            let name = url.lastPathComponent
            guard name.lowercased().contains(needle) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            out.append(FileItem(
                url: url,
                name: name,
                isDirectory: isDir,
                isSymlink: v?.isSymbolicLink ?? false,
                isHidden: v?.isHidden ?? name.hasPrefix("."),
                size: isDir ? -1 : Int64(v?.fileSize ?? 0),
                modified: v?.contentModificationDate ?? .distantPast,
                ext: url.pathExtension.lowercased(),
                isParent: false
            ))
        }
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The immediate sub-directories of `url`, sorted by name — used to build the sidebar tree.
    static func subfolders(of url: URL, showHidden: Bool) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { sub in
            let v = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Whether `url` contains at least one sub-folder (to decide if a tree row is expandable).
    static func hasSubfolders(_ url: URL, showHidden: Bool = false) -> Bool {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return false }
        for sub in urls {
            let v = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if (v?.isDirectory ?? false) && !(v?.isPackage ?? false) { return true }
        }
        return false
    }

    /// Total size (logical bytes) of all regular files under `url`, recursively. Potentially slow —
    /// call off the main thread. Returns 0 on error / empty.
    static func folderSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Recursive file/folder count and total bytes under `url`. Potentially slow — call off the main thread.
    static func folderStats(_ url: URL) -> (files: Int, folders: Int, bytes: Int64) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return (0, 0, 0) }

        var files = 0, folders = 0
        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let v = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if v.isRegularFile == true {
                files += 1
                bytes += Int64(v.fileSize ?? 0)
            } else if v.isDirectory == true {
                folders += 1
            }
        }
        return (files, folders, bytes)
    }

    /// Extension → category map for the by-type breakdown.
    private static let fileTypeMap: [String: String] = {
        let groups: [(String, [String])] = [
            ("문서", ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "hwp", "hwpx",
                     "pages", "numbers", "key", "md", "csv", "rtf", "odt", "ods", "odp", "epub"]),
            ("이미지", ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
                      "svg", "raw", "cr2", "nef", "dng", "psd", "ai"]),
            ("동영상", ["mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm", "mpg", "mpeg", "3gp"]),
            ("음악", ["mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "ogg", "wma", "opus"]),
            ("압축", ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso"]),
        ]
        var m: [String: String] = [:]
        for (cat, exts) in groups { for e in exts { m[e] = cat } }
        return m
    }()

    /// 정해진 카테고리 순서(마지막은 "기타").
    static let fileTypeOrder = ["문서", "이미지", "동영상", "음악", "압축", "기타"]

    /// 확장자가 속하는 카테고리("문서"/"이미지"/…/"기타").
    static func fileCategory(forExtension ext: String) -> String {
        fileTypeMap[ext.lowercased()] ?? "기타"
    }

    /// Total size (and count) of regular files under `root`, grouped by file-type category.
    /// Hidden trees (e.g. ~/Library) are skipped so the result reflects user content. Slow — call
    /// off the main thread.
    static func sizeByFileType(_ root: URL) -> [(name: String, bytes: Int64, count: Int)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var acc: [String: (bytes: Int64, count: Int)] = [:]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) {
            for case let fileURL as URL in enumerator {
                guard let v = try? fileURL.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                let cat = fileTypeMap[fileURL.pathExtension.lowercased()] ?? "기타"
                var cur = acc[cat] ?? (0, 0)
                cur.bytes += Int64(v.fileSize ?? 0)
                cur.count += 1
                acc[cat] = cur
            }
        }
        return fileTypeOrder.map { (name: $0, bytes: acc[$0]?.bytes ?? 0, count: acc[$0]?.count ?? 0) }
    }

    /// Free space on the volume containing `url`, formatted, or nil.
    static func freeSpace(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
