import Foundation
import AppKit
import Observation

/// Progress state for a running copy/move/zip operation.
@Observable
final class OperationProgress {
    var title: String
    var currentFile: String = ""
    var completedUnits: Int64 = 0
    var totalUnits: Int64 = 0
    var isCancelled: Bool = false

    init(title: String) { self.title = title }

    var fraction: Double {
        totalUnits <= 0 ? 0 : min(1, Double(completedUnits) / Double(totalUnits))
    }
}

enum AppSheet: Identifiable {
    case viewer(FileItem)
    case goToFolder
    case newFolder
    case rename(FileItem)
    case progress(OperationProgress)
    case about
    case manual
    case uninstall(FileItem)
    case aiOrganize

    var id: String {
        switch self {
        case .viewer(let i): return "viewer:\(i.url.path)"
        case .goToFolder: return "goto"
        case .newFolder: return "newfolder"
        case .rename(let i): return "rename:\(i.url.path)"
        case .progress: return "progress"
        case .about: return "about"
        case .manual: return "manual"
        case .uninstall(let i): return "uninstall:\(i.url.path)"
        case .aiOrganize: return "aiOrganize"
        }
    }
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var isDestructive: Bool
    var action: () -> Void
}

/// Cut/Copy clipboard (Explorer-style paste).
struct Clipboard {
    var urls: [URL]
    var isCut: Bool
}

/// Which pane the keyboard is currently driving. Tab switches between them.
enum FocusPane {
    case sidebar, detail
}

/// 터미널 실행에 사용할 앱 (설정 메뉴에서 선택).
enum TerminalApp: String, CaseIterable, Identifiable {
    case auto, terminal, iterm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "자동"
        case .terminal: return "터미널"
        case .iterm: return "iTerm"
        }
    }
}

/// App-wide appearance preference (설정 메뉴에서 선택).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "시스템"
        case .light: return "라이트"
        case .dark: return "다크"
        }
    }
}

/// Root state: Finder-style sidebar, the selected folder, its detail listing, history & clipboard.
@Observable
final class AppModel {
    var sections: [SidebarSection]
    var selectedFolder: URL
    var detail: PaneTab
    var showHidden: Bool = false
    /// 상태바에 표시할 현재 볼륨 여유공간(문자열). 느린 시스템 호출이라 백그라운드에서 계산해 캐시한다.
    var statusFreeSpace: String?
    /// 사이드바 즐겨찾기를 드래그 중일 때 그 URL(순서 변경 판별용). 드롭/드래그 종료 시 nil.
    @ObservationIgnored var draggingFavorite: URL?

    var history: [URL] = []
    var historyIndex: Int = -1
    var clipboard: Clipboard?
    /// `NSPasteboard.general.changeCount` recorded when we last wrote our own copy/cut. Lets paste tell
    /// "files we put on the clipboard" apart from "files copied in Finder / another app".
    @ObservationIgnored private var pasteboardChangeCount: Int = -1
    /// The NSWindow this model drives. Lets the (app-global) keyboard monitor ignore key events that
    /// belong to other windows, so multiple windows don't all react to one keypress.
    @ObservationIgnored weak var window: NSWindow?
    var favoritePaths: [URL] = []
    /// AI 파일 정리에서 제외할 예외 폴더 목록(표준화된 URL). 등록된 폴더와 그 하위 폴더 전체에서
    /// AI 정리 기능이 동작하지 않는다. 우클릭 메뉴에서 등록/해제하며 실행 간 유지된다.
    var excludedPaths: [URL] = []
    /// Per-folder view mode (목록/아이콘), keyed by standardized path, persisted across launches.
    var folderViewModes: [String: ViewMode] = [:]
    /// 화면 모드(시스템/라이트/다크). 변경 시 즉시 적용 + 저장.
    var appearance: AppearanceMode = AppModel.loadAppearance() {
        didSet {
            applyAppearance()
            UserDefaults.standard.set(appearance.rawValue, forKey: AppModel.appearanceKey)
        }
    }
    /// 터미널 실행 앱(자동/터미널/iTerm). 변경 시 저장.
    var terminalApp: TerminalApp = AppModel.loadTerminalApp() {
        didSet { UserDefaults.standard.set(terminalApp.rawValue, forKey: SystemActions.terminalPrefKey) }
    }
    /// 파일 목록의 글자/아이콘 크기 배율(0.8~1.8, 기본 1.0). 변경 시 저장.
    var listScale: Double = AppModel.loadListScale() {
        didSet { UserDefaults.standard.set(listScale, forKey: AppModel.listScaleKey) }
    }
    /// 최근 항목에 표시할 파일 종류(빈 집합 = 전체). 변경 시 저장 + 최근 항목 보기 중이면 갱신.
    var recentsCategories: Set<String> = AppModel.loadRecentsCategories() {
        didSet {
            UserDefaults.standard.set(Array(recentsCategories), forKey: AppModel.recentsCategoriesKey)
            if detail.recentsMode { showRecents() }
        }
    }
    /// 폴더 용량 계산 여부(기본 끔 — 파인더처럼 탐색을 즉각적으로 유지). 켜면 현재 폴더의 하위 폴더
    /// 용량을 백그라운드에서 계산해 표시한다. 변경 시 저장 + 현재 폴더 갱신.
    var calculateFolderSizes: Bool = AppModel.loadCalculateFolderSizes() {
        didSet {
            UserDefaults.standard.set(calculateFolderSizes, forKey: AppModel.calculateFolderSizesKey)
            if calculateFolderSizes { computeFolderSizes() } else { sizeTask?.cancel() }
        }
    }
    /// AI 파일 정리에 쓸 LLM 제공자(로컬 Ollama / Gemini). 변경 시 저장.
    var aiProvider: AIProvider = AppModel.loadAIProvider() {
        didSet { UserDefaults.standard.set(aiProvider.rawValue, forKey: AppModel.aiProviderKey) }
    }
    /// Gemini API 키(클라우드 사용 시). 변경 시 저장.
    var geminiAPIKey: String = AppModel.loadGeminiAPIKey() {
        didSet { UserDefaults.standard.set(geminiAPIKey, forKey: AppModel.geminiKeyKey) }
    }
    /// Gemini 모델 이름(기본 gemini-2.5-flash). 변경 시 저장.
    var geminiModel: String = AppModel.loadGeminiModel() {
        didSet { UserDefaults.standard.set(geminiModel, forKey: AppModel.geminiModelKey) }
    }
    /// 로컬 Ollama 서버 주소(기본 http://localhost:11434). 변경 시 저장.
    var ollamaBaseURL: String = AppModel.loadOllamaBaseURL() {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: AppModel.ollamaBaseURLKey) }
    }
    /// 우선 사용할 로컬 모델 이름(기본 gemma4:latest). 변경 시 저장.
    var ollamaModel: String = AppModel.loadOllamaModel() {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: AppModel.ollamaModelKey) }
    }
    /// AI 시트에 넘길 현재 설정 묶음.
    var aiConfig: AIConfig {
        AIConfig(provider: aiProvider, geminiAPIKey: geminiAPIKey, geminiModel: geminiModel,
                 ollamaBaseURL: ollamaBaseURL, ollamaModel: ollamaModel)
    }

    /// Which sidebar row is highlighted (by identity, so two rows pointing at "/" don't both light up).
    var selectedSidebarID: SidebarItem.ID?
    /// Which pane the keyboard drives (Tab toggles). Detail by default.
    var focusedPane: FocusPane = .detail

    var sheet: AppSheet?
    var confirm: ConfirmRequest? {
        didSet { if confirm != nil { confirmFocus = 0 } }   // 새 다이얼로그는 기본 동작 버튼에 포커스
    }
    /// 확인 다이얼로그에서 키보드 포커스가 있는 버튼 (0 = 확인/실행, 1 = 취소).
    var confirmFocus: Int = 0
    var errorMessage: String?
    var infoMessage: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.favoritePaths = AppModel.loadFavorites(home: home)
        self.excludedPaths = AppModel.loadExcludedFolders()
        self.folderViewModes = AppModel.loadFolderViewModes()
        self.selectedFolder = home
        self.detail = PaneTab(directory: home)
        self.sections = []
        self.history = [home]
        self.historyIndex = 0
        detail.viewMode = folderViewModes[home.standardizedFileURL.path] ?? .full
        // NOTE: init must stay cheap & side-effect-free. SwiftUI re-evaluates `@State var app =
        // AppModel()` on every render of the host view, constructing (and discarding) a fresh AppModel
        // each time — if the heavy initial load ran here it would fire on every render, spawning
        // recursive folder-size scans + a Spotlight query in a loop that pegs every core. The real
        // load runs once via bootstrap() from the view's onAppear.
    }

    /// One-time initial load (directory listing + sidebar + Recents). Safe to call repeatedly — it
    /// runs only the first time. Invoked from the window's onAppear, never from init (see init note).
    @ObservationIgnored private var didBootstrap = false
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        reloadDetail()
        detail.cursor = detail.items.first?.url
        rebuildSections()
        selectedSidebarID = sidebarItem(matching: selectedFolder)
        showRecents()   // 첫 실행 시 macOS 기본 앱처럼 "최근 항목"을 먼저 보여준다
    }

    static let helpText = """
    XFinder — 키보드 단축키 (클릭 없이 항상 동작)

    ↑ ↓ / PageUp·Down / Home·End   커서 이동
    Return          파일 열기 / 폴더 진입
    ⌘↓              선택 항목 열기
    ⌘↑ / Backspace  상위 폴더로
    ⌘[ ⌘] / ⌘← ⌘→   뒤로 / 앞으로
    Space (F3)      빠른 보기      F4  기본 앱으로 열기

    ⌘C 복사   ⌘X 잘라내기   ⌘V 붙여넣기
    ⌘D 복제   ⌘⌫ 휴지통으로   F2 이름 변경
    ⇧⌘N 새 폴더   ⌘R·F5 새로고침
    ⇧⌘.  숨김 파일   ⇧⌘G  폴더로 이동   ⌃M  목록/아이콘

    Tab             사이드바 ⇄ 파일 목록 포커스 전환
    사이드바 포커스 시  ↑↓ 이동 · → 펼치기 · ← 접기 · Return 열기
    경로 막대 더블클릭(또는 ✎) → 경로 직접 입력 후 Return

    폴더 우클릭 → 즐겨찾기에 추가 / 제거
    """

    // MARK: - Sidebar construction

    /// Full rebuild (used at launch). Resets tree expansion in both sections.
    func rebuildSections() {
        sections = [buildFavoritesSection(), buildLocationsSection(), buildTagsSection()]
    }

    /// 파인더 스타일 "태그" 섹션 — 기본 7색. 클릭하면 그 태그가 붙은 파일만 보여준다.
    private func buildTagsSection() -> SidebarSection {
        let items = TagService.standard.map {
            SidebarItem(title: $0.name, icon: "circle.fill", url: nil, kind: .tag, hasChildren: false)
        }
        return SidebarSection(title: "태그", items: items)
    }

    /// Rebuild only the 즐겨찾기 section, preserving the 위치 tree's expansion state.
    func rebuildFavoritesSection() {
        let fav = buildFavoritesSection()
        if let idx = sections.firstIndex(where: { $0.title == "즐겨찾기" }) {
            sections[idx] = fav
        } else {
            sections.insert(fav, at: 0)
        }
    }

    private func buildFavoritesSection() -> SidebarSection {
        let fm = FileManager.default
        var items: [SidebarItem] = [
            SidebarItem(title: "최근 항목", icon: "clock", url: nil, kind: .recents, hasChildren: false)
        ]
        for url in favoritePaths where fm.fileExists(atPath: url.path) {
            items.append(SidebarItem(title: AppModel.favoriteTitle(url),
                                     icon: AppModel.favoriteIcon(url),
                                     url: url, kind: .folder,
                                     hasChildren: FileSystemService.hasSubfolders(url, showHidden: showHidden)))
        }
        return SidebarSection(title: "즐겨찾기", items: items)
    }

    private func buildLocationsSection() -> SidebarSection {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 컴퓨터 노드("정종수의 MacBook Pro")는 "/"를 가리켜 아래 "Macintosh HD"(루트 볼륨)와 중복이므로 표시하지 않는다.
        var items: [SidebarItem] = [
            SidebarItem(title: home.lastPathComponent, icon: "house", url: home, kind: .folder,
                        hasChildren: FileSystemService.hasSubfolders(home, showHidden: showHidden)),
        ]
        // Only real, mounted, browsable volumes — de-duplicated by resolved path so the boot
        // volume's /Volumes symlink doesn't produce a second (non-working) "Macintosh HD".
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        var seen = Set<String>()
        if let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) {
            for vol in vols {
                let rv = try? vol.resourceValues(forKeys: Set(keys))
                guard rv?.volumeIsBrowsable ?? true else { continue }
                let resolved = vol.resolvingSymlinksInPath().standardizedFileURL.path
                if seen.contains(resolved) { continue }
                seen.insert(resolved)
                let isRoot = rv?.volumeIsRootFileSystem ?? (vol.path == "/")
                let name = rv?.volumeName ?? (isRoot ? "Macintosh HD" : vol.lastPathComponent)
                items.append(SidebarItem(title: name,
                                         icon: isRoot ? "internaldrive" : "externaldrive",
                                         url: vol, kind: .folder,
                                         hasChildren: FileSystemService.hasSubfolders(vol, showHidden: showHidden)))
            }
        }
        return SidebarSection(title: "위치", items: items)
    }

    static func hostName() -> String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    // MARK: - Favorites (persisted)

    private static let favoritesKey = "XFinder.favorites.v1"

    static func loadFavorites(home: URL) -> [URL] {
        if let arr = UserDefaults.standard.array(forKey: favoritesKey) as? [String] {
            return arr.map { URL(fileURLWithPath: $0) }
        }
        return defaultFavorites(home: home)
    }

    static func defaultFavorites(home: URL) -> [URL] {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Pictures"),
            home.appendingPathComponent("Movies"),
            home.appendingPathComponent("Music"),
        ]
        return candidates.filter { fm.fileExists(atPath: $0.path) }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(favoritePaths.map(\.path), forKey: AppModel.favoritesKey)
    }

    // MARK: - AI 정리 예외 폴더 (persisted)

    private static let excludedFoldersKey = "XFinder.aiExcludedFolders.v1"

    static func loadExcludedFolders() -> [URL] {
        guard let arr = UserDefaults.standard.array(forKey: excludedFoldersKey) as? [String] else { return [] }
        return arr.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func saveExcludedFolders() {
        UserDefaults.standard.set(excludedPaths.map(\.path), forKey: AppModel.excludedFoldersKey)
    }

    /// 이 폴더가 정확히 예외 폴더로 "직접" 등록되어 있는지(메뉴의 등록/해제 토글 표시에 사용).
    func isDirectlyExcluded(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return excludedPaths.contains { $0.path == p }
    }

    /// 이 폴더에서 AI 정리가 막혀 있는지 — 자기 자신이 등록됐거나, 어떤 예외 폴더의 하위 폴더인 경우.
    /// 하위 폴더 판정은 경로 경계(`/`)로 비교해 "/A/B"가 "/A/BC"를 잘못 포함하지 않게 한다.
    func isExcluded(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return excludedPaths.contains { ex in
            let base = ex.path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    func addExcludedFolder(_ url: URL) {
        guard url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
        guard !isDirectlyExcluded(url) else { return }
        excludedPaths.append(url.standardizedFileURL)
        saveExcludedFolders()
        infoMessage = "“\(url.lastPathComponent)” 및 하위 폴더를 AI 정리 예외로 등록했습니다."
    }

    func removeExcludedFolder(_ url: URL) {
        let p = url.standardizedFileURL.path
        excludedPaths.removeAll { $0.path == p }
        saveExcludedFolders()
        infoMessage = "“\(url.lastPathComponent)”의 AI 정리 예외를 해제했습니다."
    }

    /// 응용 프로그램 폴더(및 그 하위)인지 — 안내 문구를 응용 프로그램용으로 구분하는 데 쓴다.
    /// `/Applications`, `/System/Applications`, `~/Applications` 를 경로 경계(`/`)로 비교한다.
    func isApplicationsLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = ["/Applications",
                     "/System/Applications",
                     FileManager.default.homeDirectoryForCurrentUser
                         .appendingPathComponent("Applications").standardizedFileURL.path]
        return roots.contains { base in path == base || path.hasPrefix(base + "/") }
    }

    /// AI 파일 정리에서 항상 제외되는 보호 폴더인지 — 앱 번들·시스템 파일이 깨질 수 있어 기본 예외로 둔다.
    /// `/Applications`, `/System`, `/Library`, `~/Library` 는 하위 폴더까지 막고,
    /// `/Users` 는 그 폴더 자체만 막는다(`/Users/<내계정>` 홈과 그 하위는 정상적으로 정리 가능).
    func isProtectedLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let recursiveRoots = ["/Applications", "/System", "/Library", home + "/Library"]
        if recursiveRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        // 루트(/, Macintosh HD)와 사용자 목록(/Users)은 그 폴더 자체만 — 하위는 허용.
        return path == "/" || path == "/Users"
    }

    /// AI 파일 정리가 이 폴더에서 막혀 있는지 — 사용자가 지정한 예외 폴더이거나, 보호 폴더인 경우.
    /// 툴바 AI 아이콘 비활성화와 정리 실행 차단의 단일 기준.
    func aiOrganizeBlocked(_ url: URL) -> Bool {
        isExcluded(url) || isProtectedLocation(url)
    }

    // MARK: - Per-folder view mode (persisted)

    private static let folderViewModesKey = "XFinder.folderViewModes.v1"

    static func loadFolderViewModes() -> [String: ViewMode] {
        guard let raw = UserDefaults.standard.dictionary(forKey: folderViewModesKey) as? [String: String] else { return [:] }
        return raw.compactMapValues { ViewMode(rawValue: $0) }
    }

    private func saveFolderViewModes() {
        let raw = folderViewModes.mapValues { $0.rawValue }
        UserDefaults.standard.set(raw, forKey: AppModel.folderViewModesKey)
    }

    // MARK: - Appearance (persisted)

    private static let appearanceKey = "XFinder.appearance.v1"

    static func loadAppearance() -> AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    }

    static func loadTerminalApp() -> TerminalApp {
        TerminalApp(rawValue: UserDefaults.standard.string(forKey: SystemActions.terminalPrefKey) ?? "") ?? .auto
    }

    static let listScaleKey = "XFinder.listScale.v1"

    static func loadListScale() -> Double {
        let v = UserDefaults.standard.object(forKey: listScaleKey) as? Double ?? 1.0
        return min(1.8, max(0.8, v))
    }

    static let recentsCategoriesKey = "XFinder.recentsCategories.v1"

    static func loadRecentsCategories() -> Set<String> {
        if let arr = UserDefaults.standard.array(forKey: recentsCategoriesKey) as? [String] {
            return Set(arr)   // 사용자가 저장한 값(빈 집합 포함)
        }
        return ["문서", "이미지"]   // 기본: 문서 + 그림 위주
    }

    static let calculateFolderSizesKey = "XFinder.calculateFolderSizes.v1"

    static func loadCalculateFolderSizes() -> Bool {
        UserDefaults.standard.bool(forKey: calculateFolderSizesKey)   // 기본 false(미설정 시 끔)
    }

    static let aiProviderKey = "XFinder.aiProvider.v1"
    static let geminiKeyKey = "XFinder.geminiAPIKey.v1"
    static let geminiModelKey = "XFinder.geminiModel.v1"

    static func loadAIProvider() -> AIProvider {
        // 기본 제공자: Gemini(미설정 시). 사용자가 설정에서 바꾸면 그 값을 따른다.
        AIProvider(rawValue: UserDefaults.standard.string(forKey: aiProviderKey) ?? "") ?? .gemini
    }

    static func loadGeminiModel() -> String {
        let s = UserDefaults.standard.string(forKey: geminiModelKey) ?? ""
        return s.isEmpty ? "gemini-flash-latest" : s
    }

    /// Gemini API 키. 소스에는 키를 두지 않는다 — 설정 → AI 모델에서 입력한 값만 사용/저장.
    static func loadGeminiAPIKey() -> String {
        UserDefaults.standard.string(forKey: geminiKeyKey) ?? ""
    }

    static let ollamaBaseURLKey = "XFinder.ollamaBaseURL.v1"
    static let ollamaModelKey = "XFinder.ollamaModel.v1"

    static func loadOllamaBaseURL() -> String {
        let s = UserDefaults.standard.string(forKey: ollamaBaseURLKey) ?? ""
        return s.isEmpty ? AIService.defaultOllamaBaseURL : s
    }

    static func loadOllamaModel() -> String {
        let s = UserDefaults.standard.string(forKey: ollamaModelKey) ?? ""
        return s.isEmpty ? AIService.defaultOllamaModel : s
    }

    /// Apply the chosen mode to the whole app (includes the native titlebar / traffic lights).
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func favoriteTitle(_ url: URL) -> String {
        if url.path == "/Applications" { return "응용 프로그램" }
        let map = ["Desktop": "데스크탑", "Documents": "문서", "Downloads": "다운로드",
                   "Pictures": "사진", "Movies": "동영상", "Music": "음악",
                   "Public": "공용", "Library": "라이브러리"]
        return map[url.lastPathComponent] ?? url.lastPathComponent
    }

    static func favoriteIcon(_ url: URL) -> String {
        if url.path == "/Applications" { return "square.grid.2x2" }
        switch url.lastPathComponent {
        case "Desktop": return "menubar.dock.rectangle"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        case "Pictures": return "photo"
        case "Movies": return "film"
        case "Music": return "music.note"
        default: return "folder"
        }
    }

    func isFavorite(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return favoritePaths.contains { $0.standardizedFileURL.path == p }
    }

    func addFavorite(_ url: URL) {
        guard url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
        guard !isFavorite(url) else { return }
        favoritePaths.append(url.standardizedFileURL)
        saveFavorites()
        rebuildFavoritesSection()
    }

    func removeFavorite(_ url: URL) {
        let p = url.standardizedFileURL.path
        favoritePaths.removeAll { $0.standardizedFileURL.path == p }
        saveFavorites()
        rebuildFavoritesSection()
    }

    /// 즐겨찾기 순서 변경: `movedPath`의 즐겨찾기를 `target` 즐겨찾기 앞 위치로 옮긴다.
    /// `target`이 nil이면 맨 뒤로 보낸다. (드래그로 재정렬)
    func moveFavorite(fromPath movedPath: String, toBefore target: URL?) {
        let movedP = URL(fileURLWithPath: movedPath).standardizedFileURL.path
        guard let from = favoritePaths.firstIndex(where: { $0.standardizedFileURL.path == movedP }) else { return }
        var order = favoritePaths
        let moved = order.remove(at: from)
        if let target, let to = order.firstIndex(where: { $0.standardizedFileURL.path == target.standardizedFileURL.path }) {
            order.insert(moved, at: to)
        } else {
            order.append(moved)
        }
        guard order.map(\.path) != favoritePaths.map(\.path) else { return }   // 순서 변화 없으면 무시
        favoritePaths = order
        saveFavorites()
        reorderFavoritesSectionItems()
    }

    /// 즐겨찾기 섹션의 행을 favoritePaths 순서에 맞춰 "기존 인스턴스를 재배치"한다(새로 만들지 않음).
    /// 같은 SidebarItem 인스턴스 = 같은 identity라, withAnimation으로 감싸면 행이 부드럽게 이동한다.
    private func reorderFavoritesSectionItems() {
        guard let si = sections.firstIndex(where: { $0.title == "즐겨찾기" }) else { return }
        let existing = sections[si].items
        let recents = existing.filter { $0.kind == .recents }
        var byPath: [String: SidebarItem] = [:]
        for it in existing { if let u = it.url { byPath[u.standardizedFileURL.path] = it } }
        let folders = favoritePaths.compactMap { byPath[$0.standardizedFileURL.path] }
        sections[si].items = recents + folders
    }

    // MARK: - Navigation

    func select(_ url: URL, addHistory: Bool = true, sidebarID: SidebarItem.ID? = nil) {
        let target = url.standardizedFileURL
        selectedFolder = target
        detail.directory = target
        detail.selection = []
        detail.filter = ""
        detail.searchMode = false
        detail.recentsMode = false
        detail.tagMode = false
        detail.tagName = nil
        searchTask?.cancel()
        recentsLoader?.cancel()
        tagLoader?.cancel()
        detail.cursor = nil
        // Restore this folder's own view mode (목록/아이콘) — each folder remembers its last setting.
        detail.viewMode = folderViewModes[target.path] ?? .full
        if addHistory { pushHistory(target) }
        // Highlight exactly one sidebar row. An explicit click passes its id; otherwise pick the
        // best url match (preferring a real volume/folder over the computer node).
        selectedSidebarID = sidebarID ?? sidebarItem(matching: target)
        // Note: the sidebar tree is NOT auto-expanded on selection — the user expands it
        // explicitly with the disclosure triangles.
        // Read the directory OFF the main thread so a click never freezes the UI on a slow folder
        // (the freeze is what made rapid sidebar clicks feel "swallowed").
        loadDetail(target)
    }

    /// Load `dir`'s contents on a background task, then swap them in on the main actor. Cancels any
    /// in-flight load so rapid navigation always lands on the latest folder. Used by all navigation.
    private func loadDetail(_ dir: URL) {
        listTask?.cancel()
        sizeTask?.cancel()
        listTask = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                FileSystemService.list(dir)
            }.value
            guard !Task.isCancelled, detail.directory == dir else { return }
            switch result {
            case .success(let items): detail.rawItems = items; detail.loadError = nil
            case .failure(let error): detail.rawItems = []; detail.loadError = error.localizedDescription
            }
            detail.rebuild(showHidden: showHidden)
            detail.cursor = detail.items.first?.url
            computeFolderSizes()
            // 상태바 여유공간: volumeAvailableCapacityForImportantUsage는 느린(CacheDelete) 호출이라
            // 메인 스레드에서 매 렌더마다 부르면 간헐적 끊김이 생긴다. 백그라운드에서 계산해 캐시한다.
            let free = await Task.detached(priority: .utility) { FileSystemService.freeSpace(at: dir) }.value
            if detail.directory == dir { statusFreeSpace = free }
        }
    }

    func activateSidebar(_ item: SidebarItem) {
        switch item.kind {
        case .folder, .trash:
            if let url = item.url { select(url, sidebarID: item.id) }
        case .computer:
            select(URL(fileURLWithPath: "/"), sidebarID: item.id)
        case .recents:
            showRecents()
        case .tag:
            if let tag = TagService.standard.first(where: { $0.name == item.title }) {
                showTag(tag, sidebarID: item.id)
            }
        case .airDrop:
            break
        }
    }

    // MARK: - Recents (최근 항목)

    private func recentsSidebarID() -> SidebarItem.ID? {
        for section in sections {
            for item in section.items where item.kind == .recents { return item.id }
        }
        return nil
    }

    /// Show the system "Recents" list in the detail pane (like Finder's 최근 항목).
    func showRecents() {
        searchTask?.cancel()
        tagLoader?.cancel()
        detail.searchMode = false
        detail.filter = ""
        detail.recentsMode = true
        detail.tagMode = false
        detail.tagName = nil
        detail.selection = []
        detail.items = []
        detail.cursor = nil
        selectedSidebarID = recentsSidebarID()
        let loader = RecentsLoader()
        recentsLoader = loader
        loader.load(limit: 100, categories: recentsCategories) { [weak self] items in
            guard let self, self.detail.recentsMode else { return }
            self.detail.items = items
            self.detail.cursor = items.first?.url
        }
    }

    // MARK: - Tags (태그)

    @ObservationIgnored private var tagLoader: TagLoader?

    /// 특정 태그가 붙은 파일만 보여준다(파인더에서 사이드바 태그 클릭과 동일).
    func showTag(_ tag: FinderTag, sidebarID: SidebarItem.ID? = nil) {
        searchTask?.cancel()
        recentsLoader?.cancel()
        listTask?.cancel()
        detail.searchMode = false
        detail.recentsMode = false
        detail.filter = ""
        detail.tagMode = true
        detail.tagName = tag.name
        detail.selection = []
        detail.items = []
        detail.cursor = nil
        selectedSidebarID = sidebarID
        let loader = TagLoader()
        tagLoader = loader
        loader.load(tagName: tag.name) { [weak self] items in
            guard let self, self.detail.tagMode, self.detail.tagName == tag.name else { return }
            self.detail.items = items
            self.detail.cursor = items.first?.url
        }
    }

    /// The id of the single sidebar row that best represents `url` (folder/volume preferred over computer).
    private func sidebarItem(matching url: URL) -> SidebarItem.ID? {
        let target = url.standardizedFileURL.path
        var best: SidebarItem?
        func walk(_ item: SidebarItem) {
            if let u = item.url, u.standardizedFileURL.path == target {
                if best == nil || (best?.kind == .computer && item.kind != .computer) {
                    best = item
                }
            }
            item.children?.forEach(walk)
        }
        sections.forEach { $0.items.forEach(walk) }
        return best?.id
    }

    func reloadDetail() {
        switch FileSystemService.list(detail.directory) {
        case .success(let items): detail.rawItems = items; detail.loadError = nil
        case .failure(let error): detail.rawItems = []; detail.loadError = error.localizedDescription
        }
        detail.rebuild(showHidden: showHidden)
        computeFolderSizes()
    }

    /// User-initiated refresh: recompute folder sizes from scratch.
    func refresh() {
        if detail.recentsMode { showRecents(); return }
        for url in detail.rawItems.map(\.url) { folderSizeCache.removeValue(forKey: url) }
        reloadDetail()
    }

    // MARK: - Folder sizes (computed in the background)

    private var folderSizeCache: [URL: Int64] = [:]
    private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var recentsLoader: RecentsLoader?

    private func computeFolderSizes() {
        sizeTask?.cancel()
        // 파인더처럼 기본은 끔 — 설정에서 켤 때만 계산해 탐색 반응을 즉각적으로 유지한다.
        guard calculateFolderSizes else { return }
        let dir = detail.directory
        let folders = detail.items.filter { $0.isDirectory && !$0.isSymlink && !$0.isParent }
        guard !folders.isEmpty else { return }

        sizeTask = Task { @MainActor in
            // 캐시된 항목은 즉시 반영(스캔 불필요), 나머지는 백그라운드에서 병렬 계산.
            let uncached = folders.filter { folderSizeCache[$0.url] == nil }
            let cached = folders.filter { folderSizeCache[$0.url] != nil }
            if !cached.isEmpty {
                applyFolderSizes(cached.map { ($0.url, folderSizeCache[$0.url]!) })
            }
            guard !uncached.isEmpty else { return }

            // 하위 폴더들을 동시에 스캔(이전엔 하나씩 순차 처리해 느렸다).
            let computed = await withTaskGroup(of: (URL, Int64).self) { group in
                for item in uncached {
                    group.addTask(priority: .utility) {
                        (item.url, FileSystemService.folderSize(item.url))
                    }
                }
                var out: [(URL, Int64)] = []
                for await pair in group { out.append(pair) }
                return out
            }
            if Task.isCancelled || detail.directory != dir { return }
            for (url, size) in computed { folderSizeCache[url] = size }
            // 결과를 한 번에 반영해 목록 재렌더를 1회로 줄인다(이전엔 폴더마다 따로 갱신).
            applyFolderSizes(computed)
        }
    }

    /// Apply many folder sizes in one pass so the observed lists mutate (and the UI re-renders) once.
    private func applyFolderSizes(_ sizes: [(URL, Int64)]) {
        guard !sizes.isEmpty else { return }
        let map = Dictionary(sizes, uniquingKeysWith: { _, new in new })
        for i in detail.items.indices {
            if let size = map[detail.items[i].url] { detail.items[i].size = size }
        }
        for i in detail.rawItems.indices {
            if let size = map[detail.rawItems[i].url] { detail.rawItems[i].size = size }
        }
    }

    private func pushHistory(_ url: URL) {
        if historyIndex >= 0, history[historyIndex] == url { return }
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        history.append(url)
        historyIndex = history.count - 1
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        select(history[historyIndex], addHistory: false)
    }
    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        select(history[historyIndex], addHistory: false)
    }
    func goUp() {
        let parent = selectedFolder.deletingLastPathComponent()
        if parent != selectedFolder { select(parent) }
    }

    /// Open the cursor item: enter folder (select) or open file externally.
    func open(_ item: FileItem) {
        if item.isDirectory && !item.isBundle {
            select(item.url)
        } else {
            SystemActions.open(item.url)
        }
    }

    // MARK: - Sidebar tree

    func toggleExpand(_ item: SidebarItem) {
        item.isExpanded.toggle()
        if item.isExpanded {
            item.loadChildren(showHidden: showHidden)
            if selectedSidebarID == nil { selectedSidebarID = sidebarItem(matching: selectedFolder) }
        }
    }

    // MARK: - Sidebar keyboard navigation

    /// All currently-visible sidebar rows in top-to-bottom order (respecting tree expansion).
    var visibleSidebarItems: [SidebarItem] {
        var result: [SidebarItem] = []
        func walk(_ item: SidebarItem) {
            result.append(item)
            if item.isExpanded, let children = item.children { children.forEach(walk) }
        }
        sections.forEach { $0.items.forEach(walk) }
        return result
    }

    var selectedSidebarItem: SidebarItem? {
        visibleSidebarItems.first { $0.id == selectedSidebarID }
    }

    /// Switch keyboard focus between the sidebar and the detail list (Tab).
    func toggleFocusedPane() {
        focusedPane = focusedPane == .sidebar ? .detail : .sidebar
        // When entering the sidebar with nothing highlighted, land on the current folder's row.
        if focusedPane == .sidebar, selectedSidebarID == nil {
            selectedSidebarID = sidebarItem(matching: selectedFolder) ?? visibleSidebarItems.first?.id
        }
    }

    /// Move the sidebar highlight up/down and navigate to it immediately (Finder-style).
    func moveSidebarSelection(by delta: Int) {
        let items = visibleSidebarItems
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.id == selectedSidebarID } ?? 0
        let next = items[max(0, min(items.count - 1, idx + delta))]
        activateSidebar(next)
    }

    /// Right arrow: expand the highlighted row, or step into its first child if already open.
    func expandSidebarSelection() {
        guard let item = selectedSidebarItem else { return }
        if item.canExpand && !item.isExpanded {
            toggleExpand(item)
        } else if item.isExpanded {
            moveSidebarSelection(by: 1)
        }
    }

    /// Left arrow: collapse the highlighted row, or jump to its parent if it's a leaf.
    func collapseSidebarSelection() {
        guard let item = selectedSidebarItem else { return }
        if item.isExpanded {
            toggleExpand(item)
        } else if let parent = sidebarParent(of: item) {
            activateSidebar(parent)
        }
    }

    private func sidebarParent(of target: SidebarItem) -> SidebarItem? {
        var found: SidebarItem?
        func walk(_ item: SidebarItem) {
            if let children = item.children, children.contains(where: { $0.id == target.id }) {
                found = item
            }
            item.children?.forEach(walk)
        }
        sections.forEach { $0.items.forEach(walk) }
        return found
    }

    /// Return key in the sidebar: navigate to the highlighted row and hand focus back to the list.
    func activateSelectedSidebar() {
        if let item = selectedSidebarItem { activateSidebar(item) }
        focusedPane = .detail
    }

    private func refreshSidebar(at url: URL) {
        func walk(_ item: SidebarItem) {
            if item.url == url {
                item.children = nil
                if item.isExpanded { item.loadChildren(showHidden: showHidden) }
            }
            item.children?.forEach(walk)
        }
        sections.forEach { $0.items.forEach(walk) }
    }

    // MARK: - Helpers

    /// True when the detail pane is pointed at the (permission-restricted) Trash.
    var isViewingTrash: Bool {
        selectedFolder.standardizedFileURL.lastPathComponent == ".Trash"
    }

    func currentItem() -> FileItem? {
        if let c = detail.cursor, let item = detail.items.first(where: { $0.url == c }) { return item }
        return detail.items.first
    }

    // MARK: - Keyboard cursor navigation (driven by the global key monitor)

    func moveCursor(by delta: Int) {
        let items = detail.items
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.url == detail.cursor } ?? 0
        detail.cursor = items[max(0, min(items.count - 1, idx + delta))].url
        detail.selection = []                       // plain arrow collapses to a single cursor
        detail.selectionAnchor = detail.cursor
    }
    func cursorToTop() { detail.cursor = detail.items.first?.url; detail.selection = []; detail.selectionAnchor = detail.cursor }
    func cursorToBottom() { detail.cursor = detail.items.last?.url; detail.selection = []; detail.selectionAnchor = detail.cursor }

    /// Shift+arrow: extend the marked selection from the anchor to the moved cursor.
    func extendCursor(by delta: Int) {
        let items = detail.items
        guard !items.isEmpty else { return }
        if detail.selectionAnchor == nil { detail.selectionAnchor = detail.cursor ?? items.first?.url }
        let curIdx = items.firstIndex { $0.url == detail.cursor } ?? 0
        let newIdx = max(0, min(items.count - 1, curIdx + delta))
        detail.cursor = items[newIdx].url
        applyAnchorRange(to: newIdx)
    }

    func extendCursorToTop()    { extendCursorTo(0) }
    func extendCursorToBottom() { extendCursorTo(detail.items.count - 1) }

    private func extendCursorTo(_ index: Int) {
        let items = detail.items
        guard !items.isEmpty else { return }
        if detail.selectionAnchor == nil { detail.selectionAnchor = detail.cursor ?? items.first?.url }
        let clamped = max(0, min(items.count - 1, index))
        detail.cursor = items[clamped].url
        applyAnchorRange(to: clamped)
    }

    private func applyAnchorRange(to index: Int) {
        let items = detail.items
        guard let anchor = detail.selectionAnchor,
              let a = items.firstIndex(where: { $0.url == anchor }) else { return }
        let lo = min(a, index), hi = max(a, index)
        detail.selection = Set(items[lo...hi].filter { !$0.isParent }.map(\.url))
    }

    /// Select an index range (used by mouse drag-selection). Cursor follows the drag end.
    func selectRange(fromIndex a: Int, toIndex b: Int) {
        let items = detail.items
        guard !items.isEmpty else { return }
        let lo = max(0, min(a, b)), hi = min(items.count - 1, max(a, b))
        guard lo <= hi else { return }
        detail.selection = Set(items[lo...hi].filter { !$0.isParent }.map(\.url))
        detail.cursor = items[hi].url
        detail.selectionAnchor = items[lo].url
    }
    func openCursorItem() { if let item = currentItem() { open(item) } }

    // MARK: - Recursive search (현재 폴더/위치의 모든 하위 폴더를 검색)

    /// Drive the toolbar search field. Empty query → normal listing; otherwise run a recursive
    /// search of the selected folder (and all descendants) on a background task.
    func updateSearch(_ query: String) {
        detail.filter = query
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        searchTask?.cancel()

        if needle.isEmpty {
            detail.searchMode = false
            reloadDetail()
            detail.cursor = detail.items.first?.url
            return
        }

        tagLoader?.cancel()
        detail.tagMode = false
        detail.tagName = nil
        detail.recentsMode = false
        detail.searchMode = true
        detail.selection = []
        detail.items = []          // clear while the search runs
        let root = selectedFolder
        let includeHidden = showHidden
        searchTask = Task { @MainActor in
            let results = await Task.detached(priority: .userInitiated) {
                FileSystemService.searchRecursive(root: root, needle: needle, showHidden: includeHidden, limit: 1000)
            }.value
            // Ignore stale results (folder changed or query moved on).
            guard !Task.isCancelled, self.selectedFolder == root,
                  self.detail.filter.trimmingCharacters(in: .whitespaces).lowercased() == needle else { return }
            self.detail.items = results
            self.detail.cursor = results.first?.url
        }
    }

    /// Right-click a search result → jump to the folder that contains it and highlight it.
    func revealInList(_ item: FileItem) {
        let parent = item.url.deletingLastPathComponent()
        select(parent)
        detail.cursor = item.url
    }

    /// Display name for a search result: its path relative to the searched folder (shows location).
    func relativeDisplay(_ item: FileItem) -> String {
        var base = selectedFolder.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        let path = item.url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : item.name
    }

    /// Toggle the favourite status of the cursor item (must be a folder).
    func toggleFavoriteForCursor() {
        guard let item = currentItem(), item.isDirectory else { return }
        if isFavorite(item.url) { removeFavorite(item.url) } else { addFavorite(item.url) }
    }

    /// Place the cursor on a freshly listed item by name (the listed URL may differ from a
    /// constructed one — e.g. directories gain a trailing slash once they exist on disk).
    private func cursorToItem(named lastComponent: String) {
        if let match = detail.items.first(where: { $0.url.lastPathComponent == lastComponent }) {
            detail.cursor = match.url
        }
    }

    // MARK: - Operations

    func viewSelected() {
        guard let item = currentItem() else { return }
        SystemActions.quickLook(item.url)   // macOS native Quick Look
    }

    func editSelected() {
        if let item = currentItem() { SystemActions.open(item.url) }
    }

    func openSelected() {
        if let item = currentItem() { open(item) }
    }

    func requestNewFolder() { sheet = .newFolder }
    func requestGoToFolder() { sheet = .goToFolder }

    // MARK: - 확인 다이얼로그 키보드 조작 (방향키 포커스 이동 + Enter 실행)

    /// 좌/우(또는 상/하) 방향키로 확인/취소 버튼 사이 포커스를 이동.
    func moveConfirmFocus(_ delta: Int) {
        guard confirm != nil else { return }
        confirmFocus = (confirmFocus + delta + 2) % 2
    }

    /// 현재 포커스된 버튼을 실행 (Enter).
    func executeConfirmFocus() { executeConfirm(index: confirmFocus) }

    /// 인덱스 버튼 실행: 0 = 확인 동작, 1 = 취소.
    func executeConfirm(index: Int) {
        guard let request = confirm else { return }
        confirm = nil
        if index == 0 { request.action() }
    }

    func cancelConfirm() { confirm = nil }

    func requestRename() {
        if let item = currentItem() { sheet = .rename(item) }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 윈도우에서도 쓸 수 있는 폴더명으로 변환(금지 문자/예약 이름 처리).
        let safe = WindowsName.sanitize(trimmed)
        let dest = selectedFolder.appendingPathComponent(safe)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            reloadDetail()
            refreshSidebar(at: selectedFolder)
            cursorToItem(named: dest.lastPathComponent)
            if safe != trimmed {
                infoMessage = "윈도우 호환을 위해 폴더명을 “\(safe)”(으)로 저장했습니다."
            }
        } catch {
            errorMessage = "폴더를 만들 수 없습니다: \(error.localizedDescription)"
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        // 윈도우에서도 쓸 수 있는 이름으로 변환(금지 문자/예약 이름 처리).
        let safe = WindowsName.sanitize(trimmed)
        guard safe != item.name else { return }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(safe)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            reloadDetail()
            refreshSidebar(at: selectedFolder)
            cursorToItem(named: dest.lastPathComponent)
            if safe != trimmed {
                infoMessage = "윈도우 호환을 위해 이름을 “\(safe)”(으)로 저장했습니다."
            }
        } catch {
            errorMessage = "이름을 바꿀 수 없습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 한글 자소(NFD) 파일명 복원

    /// 현재 폴더(옵션: 하위 폴더 포함)에서 자소가 분리된 한글 파일명을 찾아 정상(NFC) 형태로
    /// 복원한다. 대상이 있으면 확인 다이얼로그를 띄우고, 확인 시 실제로 이름을 바꾼다.
    func fixDecomposedNames(recursive: Bool = false) {
        let dir = selectedFolder
        let targets = HangulNormalize.scan(directory: dir, recursive: recursive)
        guard !targets.isEmpty else {
            infoMessage = recursive
                ? "하위 폴더까지 살펴봤지만 자소가 분리된 한글 파일명이 없습니다."
                : "이 폴더에는 자소가 분리된 한글 파일명이 없습니다."
            return
        }
        let preview = targets.prefix(6)
            .map { "• \(HangulNormalize.recomposed($0.lastPathComponent))" }
            .joined(separator: "\n")
        let more = targets.count > 6 ? "\n…외 \(targets.count - 6)개" : ""
        let scope = recursive ? "하위 폴더까지 포함해 " : ""
        confirm = ConfirmRequest(
            title: "한글 파일명 복원",
            message: "\(scope)자소가 분리된 한글 파일명 \(targets.count)개를 찾았습니다. 정상 형태로 바꾸시겠습니까?\n\n\(preview)\(more)",
            confirmTitle: "복원",
            isDestructive: false,
            action: { [weak self] in self?.performHangulFix(targets) }
        )
    }

    private func performHangulFix(_ targets: [URL]) {
        let fm = FileManager.default
        // 가장 깊은 경로부터 처리해, 상위 폴더 이름을 바꿔도 이미 처리한 하위 항목 경로가 깨지지 않게 한다.
        let ordered = targets.sorted { $0.pathComponents.count > $1.pathComponents.count }
        var fixed = 0
        var failures: [String] = []
        for url in ordered {
            guard fm.fileExists(atPath: url.path) else { continue }   // 상위 폴더가 먼저 바뀐 경우 방지
            let original = url.lastPathComponent
            let nfcLeaf = HangulNormalize.recomposed(original)
            // 스칼라가 같으면 이미 정상(== 비교는 NFD/NFC를 같다고 보므로 스칼라로 비교).
            guard Array(nfcLeaf.unicodeScalars) != Array(original.unicodeScalars) else { continue }

            // 같은 폴더 안에서 NFD 이름 → NFC 이름으로 POSIX rename. 정규화 비구분 볼륨이라
            // 두 이름은 동일한 한 슬롯이므로 충돌이 생기지 않고 그 자리에서 NFC로 저장된다.
            let dstPath = url.deletingLastPathComponent().path + "/" + nfcLeaf
            if let err = HangulNormalize.rename(at: url.path, to: dstPath) {
                failures.append("\(original): \(err)")
            } else {
                fixed += 1
            }
        }
        reloadDetail()
        refreshSidebar(at: selectedFolder)
        if failures.isEmpty {
            infoMessage = "한글 파일명 \(fixed)개를 복원했습니다."
        } else {
            let shown = failures.prefix(5).joined(separator: "\n")
            let extra = failures.count > 5 ? "\n…외 \(failures.count - 5)개" : ""
            errorMessage = "\(fixed)개 복원, \(failures.count)개 실패:\n\(shown)\(extra)"
        }
    }

    // MARK: - AI 파일 정리 (로컬 LLM)

    /// 설정을 단독 창으로 연다(메뉴 ⌘, / ⋯ 작업 메뉴에서 호출).
    @MainActor func openSettings() { SettingsWindowPresenter.show(app: self) }

    /// 툴바 AI 버튼 → 프롬프트 입력 시트를 연다. 단, 현재 폴더가 예외로 지정됐거나 예외 폴더의
    /// 하위 폴더이면 정리 기능을 막고 안내만 한다.
    func requestAIOrganize() {
        if isProtectedLocation(selectedFolder) {
            errorMessage = isApplicationsLocation(selectedFolder)
                ? "응용 프로그램 폴더는 AI 파일 정리에서 제외됩니다."
                : "시스템 폴더는 AI 파일 정리에서 제외됩니다."
            return
        }
        if isExcluded(selectedFolder) {
            errorMessage = "이 폴더는 AI 정리 예외 폴더로 지정되어 정리할 수 없습니다."
            return
        }
        sheet = .aiOrganize
    }

    /// 현재 폴더의 최상위 항목 이름(숨김 제외). LLM에 넘길 후보 목록.
    func currentFolderEntries(limit: Int = 300) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: selectedFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Array(items.map { $0.lastPathComponent }.sorted().prefix(limit))
    }

    /// AI가 제안한 계획을 실제로 적용한다 — 이동(대상 하위 폴더 생성)과 삭제(휴지통으로 이동)를 처리.
    func applyAIPlan(_ ops: [AIOperation]) {
        let base = selectedFolder
        guard !aiOrganizeBlocked(base) else {
            errorMessage = isApplicationsLocation(base) ? "응용 프로그램 폴더는 AI 파일 정리에서 제외됩니다."
                : isProtectedLocation(base) ? "시스템 폴더는 AI 파일 정리에서 제외됩니다."
                : "이 폴더는 AI 정리 예외 폴더로 지정되어 정리할 수 없습니다."
            return
        }
        let fm = FileManager.default
        var moved = 0
        var trashed = 0
        var failures: [String] = []
        for op in ops {
            let src = base.appendingPathComponent(op.file)
            guard fm.fileExists(atPath: src.path) else { failures.append("\(op.file): 항목 없음"); continue }

            if op.isDelete {
                // 영구 삭제가 아니라 휴지통으로 — 복구 가능. 권한으로 막히면 Finder에 위임.
                do { try fm.trashItem(at: src, resultingItemURL: nil); trashed += 1 }
                catch {
                    if FileOperations.trashViaFinder([src]) != nil, !fm.fileExists(atPath: src.path) { trashed += 1 }
                    else { failures.append("\(op.file): \(error.localizedDescription)") }
                }
                continue
            }

            // 이동(move)
            guard AIService.isSafeDestination(op.destination ?? "") else { continue }
            let destDir = base.appendingPathComponent(op.destination ?? "")
            if src.standardizedFileURL == destDir.standardizedFileURL { continue }   // 자기 자신으로 이동 방지
            do {
                if !fm.fileExists(atPath: destDir.path) {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                }
                var dest = destDir.appendingPathComponent(op.file)
                if fm.fileExists(atPath: dest.path) {   // 대상에 같은 이름이 있으면 중복 회피
                    let b = (op.file as NSString).deletingPathExtension
                    let e = (op.file as NSString).pathExtension
                    dest = FileOperations.uniqueURL(directory: destDir, base: b, ext: e)
                }
                try fm.moveItem(at: src, to: dest)
                moved += 1
            } catch {
                failures.append("\(op.file): \(error.localizedDescription)")
            }
        }
        reloadDetail()
        refreshSidebar(at: selectedFolder)

        // 결과 요약 — 이동/삭제 건수를 함께 알린다.
        var done: [String] = []
        if moved > 0 { done.append("\(moved)개 정리") }
        if trashed > 0 { done.append("\(trashed)개 휴지통으로 이동") }
        let doneText = done.isEmpty ? "처리한 항목이 없습니다" : "AI가 " + done.joined(separator: ", ") + "했습니다."
        if failures.isEmpty {
            infoMessage = doneText
        } else {
            let shown = failures.prefix(5).joined(separator: "\n")
            let extra = failures.count > 5 ? "\n…외 \(failures.count - 5)개" : ""
            errorMessage = "\(doneText)\n\(failures.count)개 실패:\n\(shown)\(extra)"
        }
    }

    func requestDelete() {
        let targets = detail.actionTargets()
        guard !targets.isEmpty else { return }
        let names = targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count)개 항목"
        confirm = ConfirmRequest(
            title: "휴지통으로 이동",
            message: "\(names)을(를) 휴지통으로 옮기시겠습니까?",
            confirmTitle: "휴지통으로 이동",
            isDestructive: true,
            action: { [weak self] in self?.performDelete(targets) }
        )
    }

    private func performDelete(_ targets: [FileItem]) {
        var failures: [String] = []
        var removed: [URL] = []
        for item in targets {
            do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil); removed.append(item.url) }
            catch { failures.append("\(item.name): \(error.localizedDescription)") }
        }
        // 최근 항목/검색 결과는 디렉터리 리스팅이 아니므로 삭제한 항목을 목록에서 직접 제거한다.
        if detail.recentsMode || detail.searchMode {
            removeFromListing(removed)
        } else {
            reloadDetail()
            refreshSidebar(at: selectedFolder)
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    // MARK: - 응용 프로그램 삭제 (AppCleaner 스타일)

    /// 응용 프로그램 삭제 시트를 연다 — 관련 파일(캐시·환경설정·컨테이너 등)을 찾아 선택해 휴지통으로 옮긴다.
    func requestUninstall(_ item: FileItem) {
        guard AppUninstaller.isApp(item) else { return }
        sheet = .uninstall(item)
    }

    /// 시트에서 선택된 항목(앱 번들 + 관련 파일)을 휴지통으로 옮긴다.
    ///
    /// 일반 사용자 파일은 `trashItem`으로 바로 지우고, macOS 개인정보 보호(TCC)가 막는 항목 — 다른 앱
    /// 번들(앱 관리 보호)·샌드박스 컨테이너·root 소유 앱 — 은 **Finder에 위임**한다. Finder는 시스템
    /// 권한과 root 항목용 관리자 인증을 이미 갖고 있어, 임시(ad-hoc) 서명이라 전체 디스크 접근이 불안정한
    /// 이 앱에서도 안정적으로 동작한다.
    func performUninstall(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default

        // 1) 직접 휴지통으로 — 권한 문제로 실패한 것만 Finder로 넘긴다.
        var pending: [URL] = []
        for url in urls {
            do { try fm.trashItem(at: url, resultingItemURL: nil) }
            catch { pending.append(url) }
        }

        // 2) 보호된 항목은 Finder가 처리(필요 시 관리자 암호 프롬프트를 띄움).
        var automationDenied = false
        if !pending.isEmpty {
            if FileOperations.trashViaFinder(pending) == -1743 { automationDenied = true }   // 자동화 권한 거부
        }

        reloadDetail()
        refreshSidebar(at: selectedFolder)

        // 3) 그래도 남아 있는 것이 실제 실패다(휴지통으로 옮겨졌으면 원래 경로엔 없음).
        let failures = urls.filter { fm.fileExists(atPath: $0.path) }
        guard !failures.isEmpty else { return }

        if automationDenied {
            confirm = ConfirmRequest(
                title: "‘자동화’ 권한이 필요합니다",
                message: "보호된 항목을 삭제하려면 XFinder가 Finder를 제어하도록 허용해야 합니다.\n\n"
                    + "시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 XFinder 아래의 Finder를 켠 뒤 다시 시도하세요.",
                confirmTitle: "자동화 설정 열기",
                isDestructive: false,
                action: { SystemActions.openAutomationSettings() }
            )
        } else {
            errorMessage = "다음 항목을 삭제하지 못했습니다:\n"
                + failures.map { "• \($0.lastPathComponent)" }.joined(separator: "\n")
        }
    }

    /// Remove the given URLs from the current listing in place (used in Recents/Search where there's
    /// no directory to re-list), keeping the cursor sensible.
    private func removeFromListing(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let set = Set(urls)
        let oldIndex = detail.items.firstIndex { $0.url == detail.cursor }
        detail.items.removeAll { set.contains($0.url) }
        detail.rawItems.removeAll { set.contains($0.url) }
        detail.selection.subtract(set)
        if detail.cursor == nil || set.contains(detail.cursor!) {
            if detail.items.isEmpty {
                detail.cursor = nil
            } else if let i = oldIndex {
                detail.cursor = detail.items[min(i, detail.items.count - 1)].url
            } else {
                detail.cursor = detail.items.first?.url
            }
        }
    }

    func duplicate() {
        let targets = detail.actionTargets()
        guard !targets.isEmpty else { return }
        var failures: [String] = []
        var last: URL?
        for item in targets {
            let dest = FileOperations.uniqueURL(
                directory: selectedFolder,
                base: WindowsName.sanitize(item.url.deletingPathExtension().lastPathComponent) + " copy",
                ext: item.url.pathExtension
            )
            do { try FileManager.default.copyItem(at: item.url, to: dest); last = dest }
            catch { failures.append("\(item.name): \(error.localizedDescription)") }
        }
        reloadDetail()
        if let last { cursorToItem(named: last.lastPathComponent) }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    // MARK: Clipboard

    /// If a text field/editor currently has focus, perform the standard text action there and
    /// report true; otherwise false (so the caller can act on files instead). Lets ⌘C/⌘X/⌘V keep
    /// working for the search field while also driving file copy/cut/paste in the list.
    private func forwardToTextResponder(_ selectorName: String) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder,
              responder is NSText || responder is NSTextView else { return false }
        return NSApp.sendAction(Selector(selectorName), to: responder, from: nil)
    }

    func copyShortcut()  { if !forwardToTextResponder("copy:")  { copySelection() } }
    func cutShortcut()   { if !forwardToTextResponder("cut:")   { cutSelection() } }
    func pasteShortcut() { if !forwardToTextResponder("paste:") { paste() } }

    func copySelection() {
        let urls = detail.actionTargets().map(\.url)
        guard !urls.isEmpty else { return }
        clipboard = Clipboard(urls: urls, isCut: false)
        writeFilesToPasteboard(urls)   // also expose to Finder / other apps
    }

    /// 선택한 파일의 경로(들)를 클립보드에 텍스트로 복사한다(여러 개면 줄바꿈으로 구분).
    func copySelectedPath() {
        let paths = detail.actionTargets().map(\.url.path)
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func cutSelection() {
        let urls = detail.actionTargets().map(\.url)
        guard !urls.isEmpty else { return }
        clipboard = Clipboard(urls: urls, isCut: true)
        writeFilesToPasteboard(urls)   // external paste copies; our own paste moves
    }

    /// Put file URLs on the system pasteboard so ⌘C here can be pasted into Finder or any other app.
    private func writeFilesToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        pasteboardChangeCount = pb.changeCount
    }

    /// File URLs currently sitting on the system pasteboard (from Finder, another app, or us).
    private func filesOnPasteboard() -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
    }

    func paste() {
        let pb = NSPasteboard.general
        let pbURLs = filesOnPasteboard()
        let weOwnPasteboard = pb.changeCount == pasteboardChangeCount

        // Files copied in another app (Finder, etc.) → copy them in. Our own ⌘X → move; our ⌘C → copy.
        let urls: [URL]
        let move: Bool
        if !weOwnPasteboard, !pbURLs.isEmpty {
            urls = pbURLs
            move = false
        } else if let clip = clipboard, !clip.urls.isEmpty {
            urls = clip.urls
            move = clip.isCut
        } else if !pbURLs.isEmpty {
            urls = pbURLs
            move = false
        } else {
            return
        }

        runTransfer(urls, to: selectedFolder, move: move, clearClipboardOnSuccess: true)
    }

    /// Copy or move files dropped onto a folder inside the app. Plain drop moves; ⌥/⌘ held copies.
    func dropFiles(_ urls: [URL], onto folder: URL, copy: Bool) {
        let destPath = folder.standardizedFileURL.path
        let valid = urls.filter { src in
            let s = src.standardizedFileURL.path
            if s == destPath { return false }                       // can't drop onto itself
            if destPath.hasPrefix(s + "/") { return false }         // can't drop a folder into its own subtree
            if !copy, src.deletingLastPathComponent().standardizedFileURL.path == destPath { return false } // move no-op
            return true
        }
        runTransfer(valid, to: folder, move: !copy)
    }

    /// Shared copy/move runner: shows progress, performs the transfer, then refreshes affected views.
    private func runTransfer(_ urls: [URL], to destDir: URL, move: Bool, clearClipboardOnSuccess: Bool = false) {
        guard !urls.isEmpty else { return }
        let progress = OperationProgress(title: move ? "이동 중…" : "복사 중…")
        let sourceParents = Set(urls.map { $0.deletingLastPathComponent() })
        sheet = .progress(progress)
        Task { @MainActor in
            let result = await FileOperations.transfer(items: urls, toDirectory: destDir, move: move, progress: progress)
            self.dismissProgress(progress)
            if clearClipboardOnSuccess, move, case .success = result { self.clipboard = nil }   // keep clipboard if not fully moved
            self.reloadDetail()
            self.refreshSidebar(at: destDir)
            for parent in sourceParents where parent != destDir { self.refreshSidebar(at: parent) }
            if case .failure(let message) = result { self.errorMessage = message }
        }
    }

    /// Dismiss the progress sheet only if it still belongs to `progress` (avoid clobbering a sheet
    /// the user opened, or another operation's progress, while this one ran).
    private func dismissProgress(_ progress: OperationProgress) {
        if case .progress(let shown) = sheet, shown === progress { sheet = nil }
    }

    func compressSelected() {
        let targets = detail.actionTargets()
        guard !targets.isEmpty else { return }
        let base = targets.count == 1 ? targets[0].url.deletingPathExtension().lastPathComponent : "Archive"
        let zipURL = FileOperations.uniqueURL(directory: selectedFolder, base: base, ext: "zip")
        let progress = OperationProgress(title: "압축 중…")
        sheet = .progress(progress)
        Task { @MainActor in
            let result = await FileOperations.zip(items: targets.map(\.url), to: zipURL, progress: progress)
            self.dismissProgress(progress)
            self.reloadDetail()
            self.cursorToItem(named: zipURL.lastPathComponent)
            if case .failure(let message) = result { self.errorMessage = message }
        }
    }

    func extractSelected() {
        guard let item = currentItem(), item.ext == "zip" else {
            errorMessage = "압축을 풀 .zip 파일을 선택하세요."
            return
        }
        let destDir = selectedFolder
        let progress = OperationProgress(title: "압축 푸는 중…")
        sheet = .progress(progress)
        Task { @MainActor in
            let result = await FileOperations.unzip(archive: item.url, toDirectory: destDir, progress: progress)
            self.dismissProgress(progress)
            self.reloadDetail()
            self.refreshSidebar(at: destDir)
            if case .failure(let message) = result { self.errorMessage = message }
        }
    }

    func revealInFinder() {
        if let item = currentItem() { SystemActions.reveal(item.url) }
        else { SystemActions.reveal(selectedFolder) }
    }

    func openTerminal() { SystemActions.openTerminal(at: selectedFolder) }

    func openDayflow() { SystemActions.showDayflow() }

    func toggleHidden() {
        showHidden.toggle()
        reloadDetail()
        // Re-evaluate already-expanded sidebar branches so hidden folders appear/disappear.
        func reset(_ item: SidebarItem) {
            if item.children != nil {
                item.children = nil
                if item.isExpanded { item.loadChildren(showHidden: showHidden) }
            }
            item.children?.forEach(reset)
        }
        sections.forEach { $0.items.forEach(reset) }
    }

    func toggleViewMode() {
        detail.viewMode = detail.viewMode == .full ? .icon : .full
        // Remember this folder's choice so returning to it restores the same view.
        folderViewModes[selectedFolder.standardizedFileURL.path] = detail.viewMode
        saveFolderViewModes()
    }

    func goToFolder(_ path: String) {
        var expanded = (path as NSString).expandingTildeInPath
        expanded = (expanded as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "폴더를 찾을 수 없습니다:\n\(path)"
            return
        }
        select(URL(fileURLWithPath: expanded))
    }

    func showHelp() { infoMessage = AppModel.helpText }
}
