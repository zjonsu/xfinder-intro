import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Col {
    static let icon: CGFloat = 18
    static let size: CGFloat = 70
    static let modified: CGFloat = 120
    static let created: CGFloat = 120
    static let kind: CGFloat = 96
    static let rowHeight: CGFloat = 22
}

/// The right-hand contents pane: column header + scrollable file list for the selected folder.
struct DetailView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var isFocused: Bool
    @State private var lastClickURL: URL?
    @State private var lastClickAt: Date = .distantPast
    /// True when the cursor was just moved by a mouse click — suppresses the auto-scroll-to-center
    /// (which is meant for keyboard navigation) so clicking a file doesn't make the list jump.
    @State private var suppressCursorScroll = false

    private var tab: PaneTab { app.detail }
    private var scale: CGFloat { CGFloat(app.listScale) }
    private var rowH: CGFloat { Col.rowHeight * scale }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader()
            Divider()
            list
                // Drop onto the list to add files to the folder being viewed — including from another
                // window, so you can move/copy files between windows.
                .modifier(FolderDropModifier(enabled: !tab.searchMode && !tab.recentsMode,
                                             folder: tab.directory, app: app))
            Divider()
            StatusBar()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if tab.loadError != nil, app.isViewingTrash {
                    VStack(spacing: 10) {
                        Image(systemName: "trash").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text("휴지통은 Finder에서만 열 수 있습니다")
                            .font(.system(size: 13, weight: .semibold))
                        Text("macOS가 앱의 휴지통 직접 접근을 제한합니다.\n아래 버튼으로 Finder에서 휴지통을 여세요.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            SystemActions.openTrash()
                        } label: {
                            Label("Finder에서 휴지통 열기", systemImage: "arrow.up.forward.app")
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200).padding()
                } else if let error = tab.loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140).padding()
                } else if tab.items.isEmpty {
                    Text("빈 폴더")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else if tab.viewMode == .full {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tab.items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                        }
                    }
                    .coordinateSpace(name: "listSpace")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112 * scale), spacing: 8)], spacing: 8) {
                        ForEach(tab.items) { iconCell($0) }
                    }
                    .padding(12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            // Right-click on the empty list area (not on a row) → Finder-style background menu:
            // 새 폴더 만들기 · 붙여넣기 · 보기/정렬 옵션. Row context menus take precedence on rows.
            .contextMenu { backgroundMenu() }
            .onTapGesture { isFocused = true; app.focusedPane = .detail; tab.selection = [] }
            // Hold (invisible) keyboard focus so the toolbar/breadcrumb doesn't show a focus ring
            // at launch. Actual key handling is global via KeyboardMonitor.
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { DispatchQueue.main.async { isFocused = true } }
            .onChange(of: app.selectedFolder) { _, _ in
                isFocused = true
                if let c = tab.cursor { proxy.scrollTo(c, anchor: .center) }
            }
            .onChange(of: tab.cursor) { _, cursor in
                if suppressCursorScroll { suppressCursorScroll = false; return }   // mouse click → don't jump
                if let cursor { proxy.scrollTo(cursor, anchor: .center) }
            }
        }
    }


    /// A row is "draggable" (a drag MOVES it, vs. rubber-band selecting) when it was already part of the
    /// selection — either marked (multi-selection) or the single cursor item — before the press.
    private func isDraggable(_ item: FileItem) -> Bool {
        !item.isParent && (tab.selection.contains(item.url) || tab.cursor == item.url)
    }

    /// True for real folders that should accept dropped files (not bundles like .app, not "..").
    private func isDropTarget(_ item: FileItem) -> Bool {
        item.isDirectory && !item.isBundle && !item.isParent
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: FileItem, index: Int) -> some View {
        let isCursor = tab.cursor == item.url
        let isMarked = tab.selection.contains(item.url)
        FileRowView(item: item, isCursor: isCursor, isMarked: isMarked,
                    displayName: tab.searchMode ? app.relativeDisplay(item) : nil, scale: scale,
                    rowIndex: index)
            .id(item.url)
            .contentShape(Rectangle())
            // Instant select on mouse-DOWN (onPress, non-blocking). Drag a selected row → move it;
            // drag an unselected row → rubber-band multi-select; second press within interval → open.
            .modifier(FileDrag(canDrag: { isDraggable(item) },
                               urls: { dragURLs(for: item) },
                               onClick: { clickUp(item) },
                               onPress: { pressDown(item) },
                               onRubberBand: { dy in rubberBand(from: index, downward: dy) }))
            .modifier(FolderDropModifier(enabled: isDropTarget(item), folder: item.url, app: app))
            .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func iconCell(_ item: FileItem) -> some View {
        let isCursor = tab.cursor == item.url
        let isMarked = tab.selection.contains(item.url)
        IconCellView(item: item, isCursor: isCursor, isMarked: isMarked, scale: scale)
            .id(item.url)
            .contentShape(Rectangle())
            .modifier(FileDrag(canDrag: { isDraggable(item) },
                               urls: { dragURLs(for: item) },
                               onClick: { clickUp(item) },
                               onPress: { pressDown(item) }))
            .modifier(FolderDropModifier(enabled: isDropTarget(item), folder: item.url, app: app))
            .contextMenu { contextMenu(for: item) }
    }

    /// Files a drag starting on `item` should carry: the whole marked selection when `item` is part of
    /// it, otherwise just `item` (Finder-style — dragging an unmarked row drags it alone).
    private func dragURLs(for item: FileItem) -> [URL] {
        if tab.selection.contains(item.url) {
            let marked = tab.items.filter { tab.selection.contains($0.url) && !$0.isParent }
            if !marked.isEmpty { return marked.map(\.url) }
        }
        return item.isParent ? [] : [item.url]
    }


    /// 더블클릭 인식 간격 — 시스템 기본값(≈0.5s)보다 짧게 잡아 "딱딱" 빠른 더블클릭에만 열린다.
    private static let doubleClickInterval: TimeInterval = 0.3

    /// Mouse-DOWN: select instantly (Finder feel). Plain press selects just this row; a press on a row
    /// that's already part of a multi-selection keeps the group (so a drag can move it all) and only
    /// collapses on mouse-up. A second press within the interval opens.
    private func pressDown(_ item: FileItem) {
        app.focusedPane = .detail
        let now = Date()
        if lastClickURL == item.url, now.timeIntervalSince(lastClickAt) < Self.doubleClickInterval {
            app.open(item)
            lastClickURL = nil; lastClickAt = .distantPast
            return
        }
        lastClickURL = item.url; lastClickAt = now

        // Moving the cursor by mouse must NOT scroll the list (only keyboard nav should).
        if tab.cursor != item.url { suppressCursorScroll = true }

        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            tab.toggleMark(item.url); tab.cursor = item.url
        } else if mods.contains(.shift) {
            selectRange(to: item); tab.cursor = item.url
        } else if tab.selection.contains(item.url) {
            tab.cursor = item.url                       // keep the group; collapse deferred to mouse-up
        } else {
            tab.cursor = item.url; tab.selection = []   // plain press → select just this, immediately
        }
    }

    /// Mouse-UP without a drag: collapse a deferred multi-selection down to the single clicked row.
    private func clickUp(_ item: FileItem) {
        let mods = NSEvent.modifierFlags
        if !mods.contains(.command), !mods.contains(.shift), !tab.selection.isEmpty {
            tab.cursor = item.url; tab.selection = []
        }
    }

    /// Rubber-band select: extend marks from the pressed row to the row `dy` points downward.
    private func rubberBand(from index: Int, downward dy: CGFloat) {
        let target = max(0, min(tab.items.count - 1, index + Int((dy / rowH).rounded())))
        app.selectRange(fromIndex: index, toIndex: target)
    }

    // MARK: - Background (empty-area) menu

    /// Context menu shown when right-clicking the empty list area (not on any file/folder).
    /// Mirrors macOS Finder's background menu: new folder, paste, and view/sort options.
    @ViewBuilder
    private func backgroundMenu() -> some View {
        let canEdit = !tab.searchMode && !tab.recentsMode && !tab.tagMode
        if canEdit {
            Button { app.requestNewFolder() } label: { Label("새 폴더", systemImage: "folder.badge.plus") }
            if app.clipboard != nil {
                Button { app.paste() } label: { Label("붙여넣기", systemImage: "clipboard") }
            }
            Divider()
        }
        viewModeMenu()
        sortByMenu()
        Button { app.toggleHidden() } label: {
            Label("숨김 항목 보기", systemImage: app.showHidden ? "checkmark" : "eye.slash")
        }
        Divider()
        Button { app.reloadDetail() } label: { Label("새로 고침", systemImage: "arrow.clockwise") }
    }

    /// "보기" 하위 메뉴 — 목록/아이콘 보기 전환(현재 모드에 체크).
    @ViewBuilder
    private func viewModeMenu() -> some View {
        Menu {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button { setViewMode(mode) } label: {
                    Label(mode.label, systemImage: tab.viewMode == mode ? "checkmark" : (mode == .icon ? "square.grid.2x2" : "list.bullet"))
                }
            }
        } label: {
            Label("보기", systemImage: "rectangle.grid.1x2")
        }
    }

    /// "정렬 기준" 하위 메뉴 — 정렬 키 선택(현재 키에 체크) + 오름/내림차순 전환.
    @ViewBuilder
    private func sortByMenu() -> some View {
        Menu {
            ForEach([SortKey.name, .size, .kind, .modified, .created], id: \.self) { key in
                Button { setSort(key) } label: {
                    Label(sortLabel(key), systemImage: tab.sortKey == key ? "checkmark" : "")
                }
            }
            Divider()
            Button { tab.sortAscending.toggle(); tab.rebuild(showHidden: app.showHidden) } label: {
                Label(tab.sortAscending ? "오름차순" : "내림차순",
                      systemImage: tab.sortAscending ? "arrow.up" : "arrow.down")
            }
        } label: {
            Label("정렬 기준", systemImage: "arrow.up.arrow.down")
        }
    }

    private func sortLabel(_ key: SortKey) -> String {
        switch key {
        case .name: return "이름"
        case .ext: return "확장자"
        case .size: return "크기"
        case .modified: return "수정일"
        case .created: return "생성일"
        case .kind: return "종류"
        }
    }

    private func setSort(_ key: SortKey) {
        if tab.sortKey == key { tab.sortAscending.toggle() }
        else { tab.sortKey = key; tab.sortAscending = true }
        tab.rebuild(showHidden: app.showHidden)
    }

    private func setViewMode(_ mode: ViewMode) {
        if tab.viewMode != mode { app.toggleViewMode() }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        let openIcon = item.isDirectory && !item.isBundle ? "folder" : "arrow.up.forward.app"
        Button { app.open(item) } label: { Label("열기", systemImage: openIcon) }
        openWithMenu(for: item)
        if tab.searchMode || tab.recentsMode {
            Button { app.revealInList(item) } label: { Label("위치로 이동", systemImage: "scope") }
        }
        Button { SystemActions.reveal(item.url) } label: { Label("Finder에서 보기", systemImage: "magnifyingglass") }
        shareMenu(for: item)
        tagMenu(for: item)
        Divider()
        Button { selectIfNeeded(item); app.copySelection() } label: { Label("복사", systemImage: "doc.on.doc") }
        Button { selectIfNeeded(item); app.copySelectedPath() } label: { Label("경로 복사", systemImage: "doc.on.clipboard") }
            .keyboardShortcut("c", modifiers: [.option, .command])
        Button { selectIfNeeded(item); app.cutSelection() } label: { Label("잘라내기", systemImage: "scissors") }
        if app.clipboard != nil { Button { app.paste() } label: { Label("붙여넣기", systemImage: "clipboard") } }
        Button { selectIfNeeded(item); app.duplicate() } label: { Label("복제", systemImage: "plus.square.on.square") }
        Button { tab.cursor = item.url; app.requestRename() } label: { Label("이름 변경…", systemImage: "pencil") }
        if item.isDirectory {
            if app.isFavorite(item.url) {
                Button { app.removeFavorite(item.url) } label: { Label("즐겨찾기에서 제거", systemImage: "star.slash") }
            } else {
                Button { app.addFavorite(item.url) } label: { Label("즐겨찾기에 추가", systemImage: "star") }
            }
            // AI 정리 예외 폴더 등록/해제 — 등록 시 이 폴더와 하위 폴더 전체에서 AI 정리가 막힌다.
            if app.isDirectlyExcluded(item.url) {
                Button { app.removeExcludedFolder(item.url) } label: { Label("AI 정리 예외 해제", systemImage: "sparkles") }
            } else {
                Button { app.addExcludedFolder(item.url) } label: { Label("AI 정리 예외 폴더로 등록", systemImage: "hand.raised") }
            }
        }
        Divider()
        Button { selectIfNeeded(item); app.compressSelected() } label: { Label("압축", systemImage: "archivebox") }
        if item.ext == "zip" {
            Button { tab.cursor = item.url; app.extractSelected() } label: { Label("압축 풀기", systemImage: "doc.zipper") }
        }
        Divider()
        Button(role: .destructive) { selectIfNeeded(item); app.requestDelete() } label: { Label("휴지통으로 이동", systemImage: "trash") }
        if AppUninstaller.isApp(item) {
            Button(role: .destructive) { app.requestUninstall(item) } label: { Label("응용 프로그램 삭제…", systemImage: "xmark.bin") }
        }
    }

    /// macOS 기본 공유(AirDrop·메시지·메일·메모 등) 하위 메뉴 — Finder의 "공유"와 동일하게,
    /// 선택한 파일에 적용 가능한 시스템 공유 서비스를 그대로 나열한다.
    /// macOS Finder 태그(색상) 하위 메뉴 — 선택 파일에 색 태그를 토글하거나 모두 제거.
    /// 렌더 중 xattr를 읽지 않도록(목록 지연 방지) 현재 상태 체크마크는 표시하지 않고 클릭 시 토글한다.
    @ViewBuilder
    private func tagMenu(for item: FileItem) -> some View {
        Menu {
            ForEach(TagService.standard) { tag in
                Button {
                    TagService.toggle(tag, on: contextTargets(for: item))
                } label: {
                    // 컬러 NSImage 점(메뉴에서 색이 보이도록 non-template)
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(nsImage: TagService.colorDot(tag))
                    }
                }
            }
            Divider()
            Button("태그 모두 제거") { TagService.clear(on: contextTargets(for: item)) }
        } label: {
            Label("태그", systemImage: "tag")
        }
    }

    @ViewBuilder
    private func shareMenu(for item: FileItem) -> some View {
        // IMPORTANT: SwiftUI builds a row's `.contextMenu` content eagerly during list rendering —
        // even nested `Menu` content closures are evaluated immediately — so anything here runs for
        // *every* row on every paint. The old custom submenu called `NSSharingService.sharingServices`
        // (a slow per-item system query) which cost ~750ms across a folder's rows and *was* the
        // navigation "delay". `ShareLink` is cheap to build (it only needs the URLs) and lets the
        // system populate the share destinations lazily when the user actually opens it.
        let urls = contextTargets(for: item)
        if !urls.isEmpty {
            ShareLink("공유", items: urls)
        }
    }

    /// "다음으로 열기" 하위 메뉴 — 파일을 열 수 있는 앱들을 아이콘과 함께 나열(기본 앱 표시)하고,
    /// "기타…"로 다른 앱을 직접 고를 수 있다. Finder의 Open With와 동일.
    @ViewBuilder
    private func openWithMenu(for item: FileItem) -> some View {
        // Same rule as shareMenu: defer the app-lookup system calls into the Menu content closure so
        // they run on open, not during every row's render.
        if !item.isParent {
            Menu {
                let urls = contextTargets(for: item)
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
                if urls.isEmpty || apps.isEmpty {
                    Button("열 수 있는 앱 없음") {}.disabled(true)
                } else {
                    let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: item.url)?.standardizedFileURL
                    ForEach(Array(apps.enumerated()), id: \.offset) { _, appURL in
                        let isDefault = appURL.standardizedFileURL == defaultApp
                        Button {
                            openURLs(urls, with: appURL)
                        } label: {
                            Label { Text(appName(appURL) + (isDefault ? " (기본)" : "")) }
                                icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)) }
                        }
                    }
                    Divider()
                    Button("기타…") { chooseAppAndOpen(urls) }
                }
            } label: {
                Label("다음으로 열기", systemImage: "square.grid.2x2")
            }
        }
    }

    private func appName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName ?? url.lastPathComponent)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func openURLs(_ urls: [URL], with app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { _, _ in }
    }

    /// "기타…": /응용 프로그램에서 앱을 직접 골라 선택 파일을 그 앱으로 연다.
    private func chooseAppAndOpen(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "열기"
        panel.message = "이 파일을 열 응용 프로그램을 선택하세요."
        if panel.runModal() == .OK, let app = panel.url {
            openURLs(urls, with: app)
        }
    }

    /// 컨텍스트 메뉴 대상: 우클릭한 항목이 현재 선택에 포함되면 선택 전체, 아니면 그 항목 하나(Finder와 동일).
    private func contextTargets(for item: FileItem) -> [URL] {
        if tab.selection.contains(item.url) {
            let marked = tab.items.filter { tab.selection.contains($0.url) && !$0.isParent }.map(\.url)
            if !marked.isEmpty { return marked }
        }
        return item.isParent ? [] : [item.url]
    }

    private func selectIfNeeded(_ item: FileItem) {
        if !tab.selection.contains(item.url) {
            tab.cursor = item.url
            tab.selection = []
        }
    }

    // MARK: - Mouse

    private func click(_ item: FileItem) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            tab.toggleMark(item.url)
            tab.cursor = item.url
        } else if mods.contains(.shift) {
            selectRange(to: item)
            tab.cursor = item.url
        } else {
            tab.cursor = item.url
            tab.selection = []
        }
    }

    private func selectRange(to item: FileItem) {
        let list = tab.items
        let anchor = tab.cursor ?? list.first?.url
        guard let anchor,
              let a = list.firstIndex(where: { $0.url == anchor }),
              let b = list.firstIndex(where: { $0.url == item.url }) else { return }
        let range = a <= b ? a...b : b...a
        tab.selection = Set(list[range].map(\.url))
    }

}

// MARK: - Column header

private struct ColumnHeader: View {
    @Environment(AppModel.self) private var app
    private var tab: PaneTab { app.detail }
    private var scale: CGFloat { CGFloat(app.listScale) }

    private func header(_ title: String, _ key: SortKey, width: CGFloat?, align: Alignment) -> some View {
        let sorted = tab.sortKey == key
        return Button {
            if tab.sortKey == key { tab.sortAscending.toggle() }
            else { tab.sortKey = key; tab.sortAscending = true }
            tab.rebuild(showHidden: app.showHidden)
        } label: {
            HStack(spacing: 2) {
                if align == .trailing { Spacer(minLength: 0) }
                Text(title).font(.system(size: 11 * scale, weight: .semibold))
                if sorted {
                    Image(systemName: tab.sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 7 * scale))
                }
                if align == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: Col.icon * scale)
            header("이름", .name, width: nil, align: .leading)
            header("크기", .size, width: Col.size * scale, align: .trailing)
            header("수정일", .modified, width: Col.modified * scale, align: .leading)
            header("생성일", .created, width: Col.created * scale, align: .leading)
            header("종류", .kind, width: Col.kind * scale, align: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - File row

struct FileRowView: View {
    let item: FileItem
    let isCursor: Bool
    let isMarked: Bool
    var displayName: String? = nil   // search results show their path relative to the searched folder
    var scale: CGFloat = 1           // 설정의 "파일 목록 크기" 배율
    var rowIndex: Int = 0            // 줄무늬(교대 배경)용 행 번호

    private var background: Color {
        if isCursor { return Color.accentColor.opacity(0.85) }
        if isMarked { return Color.accentColor.opacity(0.22) }
        // macOS Finder처럼 홀수 행에 옅은 배경을 깔아 행을 구분.
        return rowIndex.isMultiple(of: 2) ? .clear : Color(nsColor: .alternatingContentBackgroundColors[1])
    }
    private var foreground: Color {
        if isCursor { return .white }
        if isMarked { return .accentColor }
        return item.isHidden ? .secondary : .primary
    }
    private var secondaryColor: Color { isCursor ? Color.white.opacity(0.85) : .secondary }

    var body: some View {
        HStack(spacing: 6) {
            SystemActions.swiftUIImage(for: item)
                .resizable().frame(width: 18 * scale, height: 18 * scale)
            Text(displayName ?? item.name)
                .font(.system(size: 12 * scale)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.size(item.size, isDirectory: item.isDirectory))
                .font(.system(size: 11 * scale)).frame(width: Col.size * scale, alignment: .trailing)
            Text(Format.date(item.modified))
                .font(.system(size: 11 * scale)).foregroundStyle(secondaryColor)
                .frame(width: Col.modified * scale, alignment: .leading)
            Text(Format.date(item.created))
                .font(.system(size: 11 * scale)).foregroundStyle(secondaryColor)
                .frame(width: Col.created * scale, alignment: .leading)
            Text(Format.kindLabel(item))
                .font(.system(size: 11 * scale)).foregroundStyle(secondaryColor)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: Col.kind * scale, alignment: .leading)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: Col.rowHeight * scale)
        .background(background)
    }
}

/// One cell in the large-icon grid view: a thumbnail above a (highlighted when selected) filename.
struct IconCellView: View {
    let item: FileItem
    let isCursor: Bool
    let isMarked: Bool
    var scale: CGFloat = 1

    private var labelBackground: Color {
        if isCursor { return Color.accentColor }
        if isMarked { return Color.accentColor.opacity(0.22) }
        return .clear
    }

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(item: item, size: 70 * scale)
            Text(item.name)
                .font(.system(size: 11 * scale))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(labelBackground))
                .foregroundStyle(isCursor ? .white : (item.isHidden ? .secondary : .primary))
        }
        .frame(width: 104 * scale, height: 104 * scale, alignment: .top)
        .padding(.top, 4)
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppModel.self) private var app
    private var tab: PaneTab { app.detail }

    var body: some View {
        HStack(spacing: 8) {
            let marked = tab.selection.count
            Text(marked > 0 ? "\(tab.items.count)개 중 \(marked)개 선택" : "\(tab.items.count)개 항목")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let clip = app.clipboard {
                Text("· 클립보드: \(clip.urls.count)개 \(clip.isCut ? "(잘라냄)" : "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            // 캐시된 값 사용 — 느린 freeSpace 호출은 AppModel이 폴더 진입 시 백그라운드에서 갱신한다.
            if let free = app.statusFreeSpace {
                Text("\(free) 사용 가능").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
