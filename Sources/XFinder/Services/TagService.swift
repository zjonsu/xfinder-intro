import Foundation
import SwiftUI
import AppKit

/// macOS Finder 호환 태그(색상 라벨) 읽기/쓰기. 태그는 파일의 확장 속성
/// `com.apple.metadata:_kMDItemUserTags`(문자열 배열의 바이너리 plist)에 저장된다.
/// 색상 태그는 "이름\n색번호" 형식(예: "빨간색\n6")이라 Finder가 같은 색 점으로 표시한다.
enum TagService {
    private static let attr = "com.apple.metadata:_kMDItemUserTags"

    /// 파인더 기본 7색 태그(사이드바·컨텍스트 메뉴 순서와 동일). 색번호는 Finder 규칙.
    static let standard: [FinderTag] = [
        FinderTag(name: "빨간색", colorIndex: 6),
        FinderTag(name: "주황색", colorIndex: 7),
        FinderTag(name: "노란색", colorIndex: 5),
        FinderTag(name: "초록색", colorIndex: 2),
        FinderTag(name: "파란색", colorIndex: 4),
        FinderTag(name: "보라색", colorIndex: 3),
        FinderTag(name: "회색",   colorIndex: 1),
    ]

    // MARK: - Read / write the extended attribute

    /// 원본 태그 문자열들("이름" 또는 "이름\n색번호").
    static func rawTags(of url: URL) -> [String] {
        let path = url.path
        let len = getxattr(path, attr, nil, 0, 0, 0)
        guard len > 0 else { return [] }
        var data = Data(count: len)
        let read = data.withUnsafeMutableBytes { getxattr(path, attr, $0.baseAddress, len, 0, 0) }
        guard read > 0,
              let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String]
        else { return [] }
        return list
    }

    private static func setRawTags(_ tags: [String], on url: URL) {
        let path = url.path
        if tags.isEmpty {
            removexattr(path, attr, 0)
            return
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { setxattr(path, attr, $0.baseAddress, data.count, 0, 0) }
    }

    /// 태그 문자열에서 표시 이름만(색번호 접미사 제거).
    static func displayName(_ raw: String) -> String {
        raw.components(separatedBy: "\n").first ?? raw
    }

    static func hasTag(_ tag: FinderTag, on url: URL) -> Bool {
        rawTags(of: url).contains { displayName($0) == tag.name }
    }

    /// 선택한 파일들에 태그를 토글(전부 갖고 있으면 제거, 아니면 추가).
    static func toggle(_ tag: FinderTag, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        let allHave = urls.allSatisfy { hasTag(tag, on: $0) }
        for url in urls {
            var raw = rawTags(of: url)
            raw.removeAll { displayName($0) == tag.name }
            if !allHave { raw.append("\(tag.name)\n\(tag.colorIndex)") }
            setRawTags(raw, on: url)
        }
    }

    /// 선택한 파일들의 모든 태그 제거.
    static func clear(on urls: [URL]) {
        for url in urls { setRawTags([], on: url) }
    }

    /// 컨텍스트 메뉴용 컬러 점 이미지. 메뉴는 SF Symbol을 템플릿(흑백)으로 그리므로, 색을 보이게
    /// 하려면 non-template 컬러 NSImage를 직접 그려서 넣어야 한다.
    static func colorDot(_ tag: FinderTag, size: CGFloat = 11) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        tag.nsColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1)).fill()
        img.unlockFocus()
        img.isTemplate = false   // 템플릿이 아니어야 메뉴에서 색이 그대로 표시됨
        return img
    }
}

/// 색상 + 이름을 가진 파인더 표준 태그.
struct FinderTag: Identifiable, Hashable {
    let name: String
    let colorIndex: Int
    var id: String { name }

    /// Finder 색번호 → 화면 색.
    var color: Color {
        switch colorIndex {
        case 1: return Color(.systemGray)
        case 2: return .green
        case 3: return .purple
        case 4: return .blue
        case 5: return .yellow
        case 6: return .red
        case 7: return .orange
        default: return .secondary
        }
    }

    var nsColor: NSColor {
        switch colorIndex {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return .secondaryLabelColor
        }
    }
}

/// 특정 태그가 붙은 파일들을 Spotlight로 찾아온다(파인더의 태그 클릭과 동일). `completion`은 메인 큐에서.
final class TagLoader {
    private var query: NSMetadataQuery?
    private var token: NSObjectProtocol?
    private var finished = false

    func load(tagName: String, limit: Int = 500, completion: @escaping ([FileItem]) -> Void) {
        cancel()
        finished = false
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemUserTags == %@", tagName)
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        q.searchScopes = [NSMetadataQueryUserHomeScope]

        token = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in
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
                guard let it = q.result(at: i) as? NSMetadataItem,
                      let path = it.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let url = URL(fileURLWithPath: path)
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = rv?.isDirectory ?? false
                items.append(FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    isSymlink: false,
                    isHidden: false,
                    size: isDir ? -1 : Int64(rv?.fileSize ?? 0),
                    modified: rv?.contentModificationDate ?? .distantPast,
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
