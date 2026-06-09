import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Thin wrappers over NSWorkspace for opening / revealing / icons / terminal.
enum SystemActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open System Settings → Privacy & Security → Full Disk Access. Required for the app to trash
    /// other apps' bundles (App Management protection) and their sandbox containers in ~/Library.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings → Privacy & Security → Automation, so the user can allow XFinder to
    /// control Finder (needed for the Finder-delegated trash used when uninstalling apps).
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open the user's Trash in Finder. macOS blocks apps from enumerating ~/.Trash directly
    /// (only Finder has the right), so we hand off to Finder which displays it properly.
    static func openTrash() {
        let trash = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trash)
    }

    /// Show the macOS native Quick Look preview panel for a file (via qlmanage).
    private static var quickLookProcess: Process?
    static func quickLook(_ url: URL) {
        quickLookProcess?.terminate()        // close any previous panel
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        proc.arguments = ["-p", url.path(percentEncoded: false)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { _ in }   // reaps the child so it doesn't linger
        try? proc.run()
        quickLookProcess = proc
        NSApp.activate(ignoringOtherApps: false)
    }

    /// Stores the user's terminal-app preference ("auto" | "terminal" | "iterm"). Read here so every
    /// call site (toolbar button, sidebar/detail context menus) honours the setting uniformly.
    static let terminalPrefKey = "XFinder.terminalApp.v1"

    static func iTermURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
    }

    /// Launch DayFlow (a menu-bar/LSUIElement calendar app) and tell it to show its
    /// calendar popover. DayFlow listens for the distributed notification below; merely
    /// launching it only adds the menu-bar item, so we post the notification too.
    static func showDayflow() {
        let note = Notification.Name("com.zjonsu.dayflow.showPopover")
        let bundleID = "com.zjonsu.dayflow"
        // Show the calendar at the click location (current cursor, which is on the icon).
        let p = NSEvent.mouseLocation
        let info = ["x": "\(p.x)", "y": "\(p.y)"]
        let isRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }

        if isRunning {
            DistributedNotificationCenter.default()
                .postNotificationName(note, object: nil, userInfo: info, deliverImmediately: true)
            return
        }

        // Not running yet: launch, then post once it has registered its observer.
        let appURL = URL(fileURLWithPath: "/Applications/DayFlow.app")
        let target = FileManager.default.fileExists(atPath: appURL.path)
            ? appURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let url = target else { return }
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                DistributedNotificationCenter.default()
                    .postNotificationName(note, object: nil, userInfo: info, deliverImmediately: true)
            }
        }
    }

    /// Launch an app by its display name (e.g. "Dayflow"). Searches the standard
    /// /Applications and ~/Applications locations, then falls back to LaunchServices.
    /// Returns false (and does nothing) if the app can't be found.
    @discardableResult
    static func launchApp(named name: String, extraPaths: [String] = []) -> Bool {
        let candidates = extraPaths.map { URL(fileURLWithPath: $0) } + [
            URL(fileURLWithPath: "/Applications/\(name).app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/\(name).app"),
        ]
        let appURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
        guard let url = appURL else { return false }
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return true
    }

    static func terminalURL() -> URL {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    /// Open `directory` in the preferred terminal. "auto"/"iterm" use iTerm when installed and fall
    /// back to the system Terminal; "terminal" always uses Terminal.
    static func openTerminal(at directory: URL) {
        let pref = UserDefaults.standard.string(forKey: terminalPrefKey) ?? "auto"
        let appURL: URL
        switch pref {
        case "terminal": appURL = terminalURL()
        default:         appURL = iTermURL() ?? terminalURL()   // auto / iterm
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: config) { _, _ in }
    }

    // MARK: - Icons (cached)

    private static let iconCache = NSCache<NSString, NSImage>()

    static func icon(for item: FileItem) -> NSImage {
        // Icons must be cheap because they're built during SwiftUI row rendering. `icon(forFile:)`
        // touches the file on disk (custom-icon / resource-fork read) and is slow per item, so we
        // only use it where icons are genuinely unique (app bundles, symlink alias badges). Plain
        // folders share one folder icon and plain files share a per-type icon — both disk-free and
        // cached, which is what keeps folder navigation snappy (per-file icons cost hundreds of ms
        // on a folder's first paint; per-type costs ~0).
        let key: String
        if item.isParent {
            key = "__folder__"
        } else if item.isBundle || item.isSymlink {
            key = "path:" + item.url.path              // unique icon → key by path
        } else if item.isDirectory {
            key = "__folder__"                          // every plain folder shares one icon
        } else if !item.ext.isEmpty {
            key = "ext:" + item.ext                     // files share a per-type icon
        } else {
            key = "__file__"                            // extension-less → generic document
        }
        if let cached = iconCache.object(forKey: key as NSString) { return cached }

        let image: NSImage
        if item.isParent || (item.isDirectory && !item.isBundle && !item.isSymlink) {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if item.isBundle || item.isSymlink {
            image = NSWorkspace.shared.icon(forFile: item.url.path)
        } else if !item.ext.isEmpty, let type = UTType(filenameExtension: item.ext) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        iconCache.setObject(image, forKey: key as NSString)
        return image
    }

    static func swiftUIImage(for item: FileItem) -> Image {
        Image(nsImage: icon(for: item))
    }

    /// 파일의 시스템 아이콘을 흑백 템플릿(실루엣)으로 — 사이드바에서 응용 프로그램을 파인더처럼
    /// 단색 글리프로 보여줄 때 사용.
    static func monochromeImage(forFile path: String) -> Image {
        let key = "tmpl:" + path
        if let cached = iconCache.object(forKey: key as NSString) { return Image(nsImage: cached) }
        let base = NSWorkspace.shared.icon(forFile: path)
        let img = (base.copy() as? NSImage) ?? base
        img.isTemplate = true
        iconCache.setObject(img, forKey: key as NSString)
        return Image(nsImage: img)
    }

    /// macOS 기본 폴더 아이콘(폴더에 사용자 지정 아이콘이 있으면 그것) — 사이드바 폴더 행에 사용.
    static func folderImage(for url: URL) -> Image {
        let key = "folder:" + url.path
        if let cached = iconCache.object(forKey: key as NSString) { return Image(nsImage: cached) }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(image, forKey: key as NSString)
        return Image(nsImage: image)
    }
}
