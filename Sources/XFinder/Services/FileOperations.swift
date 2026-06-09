import Foundation

enum OpResult {
    case success
    case failure(String)
    case cancelled
}

/// Copy / move / compress / extract, run off the main actor with progress reported back to it.
enum FileOperations {

    /// A destination URL in `directory` that doesn't collide with an existing file.
    static func uniqueURL(directory: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        func make(_ n: Int) -> URL {
            let stem = n == 1 ? base : "\(base) \(n)"
            let name = ext.isEmpty ? stem : "\(stem).\(ext)"
            return directory.appendingPathComponent(name)
        }
        var n = 1
        var url = make(n)
        while fm.fileExists(atPath: url.path) { n += 1; url = make(n) }
        return url
    }

    // MARK: - Copy / Move

    static func transfer(items: [URL], toDirectory destDir: URL, move: Bool, progress: OperationProgress) async -> OpResult {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            await MainActor.run {
                progress.totalUnits = Int64(items.count)
                progress.completedUnits = 0
            }
            var failures: [String] = []
            var cancelled = false
            for src in items {
                if await MainActor.run(body: { progress.isCancelled }) { cancelled = true; break }
                let original = src.lastPathComponent
                // 윈도우에서도 쓸 수 있는 이름으로 변환(금지 문자/예약 이름 처리).
                let name = WindowsName.sanitize(original)
                await MainActor.run { progress.currentFile = original }

                // Moving an item into the folder it already lives in is a no-op (Finder behaviour).
                // 이름 변환이 필요 없는 보통 파일에 한함 — 변환이 필요하면 같은 폴더라도 정리 대상.
                if move, name == original,
                   src.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL {
                    await MainActor.run { progress.completedUnits += 1 }
                    continue
                }

                var dest = destDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) {
                    dest = uniqueURL(
                        directory: destDir,
                        base: WindowsName.sanitize(src.deletingPathExtension().lastPathComponent),
                        ext: src.pathExtension
                    )
                }
                do {
                    if move {
                        try fm.moveItem(at: src, to: dest)
                    } else {
                        try fm.copyItem(at: src, to: dest)
                    }
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
                await MainActor.run { progress.completedUnits += 1 }
            }
            if !failures.isEmpty { return .failure(failures.joined(separator: "\n")) }
            return cancelled ? .cancelled : .success
        }.value
    }

    // MARK: - Archives

    /// Create a .zip at `dest` from `items` (which must share a parent directory).
    static func zip(items: [URL], to dest: URL, progress: OperationProgress) async -> OpResult {
        await Task.detached(priority: .userInitiated) {
            await MainActor.run {
                progress.totalUnits = 1
                progress.currentFile = dest.lastPathComponent
            }
            let parent = items.first?.deletingLastPathComponent() ?? dest.deletingLastPathComponent()
            let names = items.map(\.lastPathComponent)
            let (status, output) = runProcess(
                "/usr/bin/zip",
                ["-r", "-X", dest.path] + names,
                cwd: parent
            )
            await MainActor.run { progress.completedUnits = 1 }
            return status == 0 ? .success : .failure("zip failed (\(status)):\n\(output)")
        }.value
    }

    /// Extract `archive` into `destDir` using ditto.
    static func unzip(archive: URL, toDirectory destDir: URL, progress: OperationProgress) async -> OpResult {
        await Task.detached(priority: .userInitiated) {
            await MainActor.run {
                progress.totalUnits = 1
                progress.currentFile = archive.lastPathComponent
            }
            let (status, output) = runProcess(
                "/usr/bin/ditto",
                ["-x", "-k", archive.path, destDir.path]
            )
            await MainActor.run { progress.completedUnits = 1 }
            return status == 0 ? .success : .failure("extract failed (\(status)):\n\(output)")
        }.value
    }

    // MARK: - Trash via Finder

    /// Move items to the Trash by asking **Finder** (AppleScript). Finder already has the system
    /// privileges a normal `FileManager.trashItem` lacks: it can remove other apps' bundles (with an
    /// admin-auth prompt for root-owned ones) and TCC-protected sandbox containers in ~/Library.
    /// Runs synchronously (blocks while Finder shows any auth dialog). Returns the AppleScript error
    /// number, or nil on success. Notable: -1743 = Automation (Apple Events) permission not granted.
    @discardableResult
    static func trashViaFinder(_ urls: [URL]) -> Int? {
        guard !urls.isEmpty else { return nil }
        let list = urls.map { url -> String in
            let p = url.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "POSIX file \"\(p)\""
        }.joined(separator: ", ")
        let source = """
        tell application "Finder"
            delete { \(list) }
        end tell
        """
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        return (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
    }

    // MARK: - Process helper

    @discardableResult
    static func runProcess(_ launchPath: String, _ args: [String], cwd: URL? = nil) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
