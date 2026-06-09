import Foundation
import AppKit

/// A file or folder related to an application: the .app bundle itself plus its support / cache /
/// preference files scattered across the Library folders — what AppCleaner gathers before removal.
struct AppRelatedFile: Identifiable, Hashable {
    let url: URL
    var size: Int64
    let isApp: Bool          // the .app bundle itself (always the first row)

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var path: String { url.path }

    /// Containing folder, with the home directory abbreviated to "~" like Finder/AppCleaner.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = url.deletingLastPathComponent().path
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }
}

/// Finds an application's related files (caches, preferences, containers, launch agents, …) so the
/// whole app can be removed cleanly — AppCleaner style. Read-only; deletion happens in AppModel.
enum AppUninstaller {

    /// True for a FileItem we can offer to uninstall (a real .app bundle).
    static func isApp(_ item: FileItem) -> Bool {
        item.isDirectory && item.ext == "app"
    }

    /// The app bundle plus every related support file, with sizes computed. Scans the Library
    /// folders and measures folder sizes, so it is slow — call off the main thread.
    static func relatedFiles(for appURL: URL) -> [AppRelatedFile] {
        let fm = FileManager.default
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        let appName = appURL.deletingPathExtension().lastPathComponent

        var found: [URL] = [appURL.standardizedFileURL]
        var seen: Set<String> = [appURL.standardizedFileURL.path]

        func add(_ url: URL) {
            let std = url.standardizedFileURL
            guard !seen.contains(std.path), fm.fileExists(atPath: std.path) else { return }
            seen.insert(std.path)
            found.append(std)
        }

        // Does `name` belong to this app's bundle identifier? The bundle id must appear as a
        // dot-delimited token run: it may be preceded by a developer **Team ID** prefix
        // ("S8EX82NJP6.com.x.app", "group.com.x.app") and followed by a separator or the end —
        //   "com.x.app", "com.x.app.helper.plist", "com.x.app_stats.sqlite3",
        //   "S8EX82NJP6.com.x.app", "S8EX82NJP6.com.x.app.plist".
        // The before-"." / after-separator boundaries stop a *different* app whose id merely starts
        // or ends similarly from matching (e.g. "com.x.app2", "xcom.x.app").
        func belongs(_ name: String) -> Bool {
            guard let bundleID, !bundleID.isEmpty, let r = name.range(of: bundleID) else { return false }
            if r.lowerBound != name.startIndex, name[name.index(before: r.lowerBound)] != "." { return false }
            if r.upperBound != name.endIndex {
                let after = name[r.upperBound]
                if after != "." && after != "_" && after != " " { return false }
            }
            return true
        }
        func nameMatch(_ name: String) -> Bool {
            (name as NSString).deletingPathExtension == appName
        }
        func scan(_ dir: URL, _ match: (String) -> Bool) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: []) else { return }
            for entry in entries where match(entry.lastPathComponent) { add(entry) }
        }

        let home = fm.homeDirectoryForCurrentUser
        let userLib = home.appendingPathComponent("Library")
        let sysLib = URL(fileURLWithPath: "/Library")

        // ~/Library — entries named by bundle identifier (incl. team-id-prefixed variants).
        for sub in ["Preferences", "Preferences/ByHost", "Caches", "HTTPStorages", "WebKit",
                    "Containers", "Group Containers", "Saved Application State", "Application Scripts",
                    "LaunchAgents", "Cookies"] {
            scan(userLib.appendingPathComponent(sub), belongs)
        }
        // Application Support & Logs are named by display name OR bundle id.
        for sub in ["Application Support", "Logs"] {
            scan(userLib.appendingPathComponent(sub)) { belongs($0) || nameMatch($0) }
        }

        // /Library — daemons / privileged helpers (trashable when writable by the user).
        for sub in ["LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"] {
            scan(sysLib.appendingPathComponent(sub), belongs)
        }
        scan(sysLib.appendingPathComponent("Application Support")) { belongs($0) || nameMatch($0) }

        // Measure each (folders recursively).
        return found.enumerated().map { index, url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let size = isDir
                ? FileSystemService.folderSize(url)
                : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return AppRelatedFile(url: url, size: size, isApp: index == 0)
        }
    }
}
