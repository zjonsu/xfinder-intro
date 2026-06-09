import Foundation

/// Loads the system "Recents" — recently used files — via a Spotlight metadata query, the same
/// mechanism Finder's 최근 항목 uses (sorted by last-used date, newest first).
final class RecentsLoader {
    private var query: NSMetadataQuery?
    private var token: NSObjectProtocol?
    /// Guards against the gather notification re-entering while we process results — without this the
    /// query stays live and Spotlight + our handler feed back into a CPU storm (pegs many cores + mds).
    private var finished = false

    /// Fetch up to `limit` recently-used files, keeping only files whose type is in `categories`
    /// (empty set = no filter / show all). `completion` runs on the main queue.
    func load(limit: Int = 100, categories: Set<String> = [], completion: @escaping ([FileItem]) -> Void) {
        cancel()
        finished = false
        let q = NSMetadataQuery()
        // Files used within the last ~60 days, newest first.
        let since = Date(timeIntervalSinceNow: -60 * 60 * 24 * 60)
        q.predicate = NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, since as NSDate)
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        q.searchScopes = [NSMetadataQueryUserHomeScope]

        token = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in
            // Stop the query and detach the observer BEFORE touching results: reading file properties
            // below spins enough that a still-live query re-posts this notification and re-enters here.
            guard let self, !self.finished else { return }
            self.finished = true
            q.disableUpdates()
            q.stop()
            if let token = self.token {
                NotificationCenter.default.removeObserver(token)
                self.token = nil
            }
            let total = q.resultCount
            var items: [FileItem] = []
            var i = 0
            while i < total && items.count < limit {
                defer { i += 1 }
                guard let item = q.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let url = URL(fileURLWithPath: path)
                // 카테고리 필터(문서/이미지/…). 빈 집합이면 전체 표시.
                let category = FileSystemService.fileCategory(forExtension: url.pathExtension)
                if !categories.isEmpty && !categories.contains(category) { continue }
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = rv?.isDirectory ?? false
                let lastUsed = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
                items.append(FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    isSymlink: false,
                    isHidden: false,
                    size: isDir ? -1 : Int64(rv?.fileSize ?? 0),
                    modified: lastUsed ?? .distantPast,
                    ext: url.pathExtension.lowercased(),
                    isParent: false
                ))
            }
            self.query = nil
            completion(items)
        }
        query = q
        q.start()
    }

    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token); self.token = nil }
        query?.stop()
        query = nil
    }

    deinit { cancel() }
}
