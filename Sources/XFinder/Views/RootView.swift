import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var keyMonitor: Any?

    /// 파일 목록 크기(설정 슬라이더)에 맞춰 툴바 아이콘·글꼴도 함께 커지고 작아진다.
    private var scale: CGFloat { CGFloat(app.listScale) }

    /// Native window title — classic Finder shows the current folder name (or "최근 항목" in recents mode).
    private var windowTitle: String {
        if app.detail.recentsMode { return "최근 항목" }
        return app.selectedFolder.path == "/" ? "Macintosh HD" : app.selectedFolder.lastPathComponent
    }

    var body: some View {
        @Bindable var app = app

        // NavigationSplitView gives the native macOS 26 Liquid Glass sidebar (translucent, behind-window
        // blur), the native sidebar toggle, and native column resize. Our custom row tap handlers still
        // drive navigation, so KeyboardMonitor / focusedPane logic is untouched.
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 340)
        } detail: {
            VStack(spacing: 0) {
                PathBar()
                Divider()
                DetailView()
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(windowTitle)
            .toolbar { toolbarContent }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 460)
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .viewer(let item): ViewerSheet(item: item)
            case .goToFolder: GoToFolderSheet()
            case .newFolder: NewFolderSheet()
            case .rename(let item): RenameSheet(item: item)
            case .progress(let progress): ProgressSheet(progress: progress)
            case .about: AboutSheet()
            case .manual: ManualSheet()
            case .uninstall(let item): UninstallSheet(appItem: item)
            case .aiOrganize: AIOrganizeSheet()
            }
        }
        // 확인 다이얼로그: 방향키로 버튼 포커스 이동 + Enter 실행 (KeyboardMonitor가 구동).
        .overlay {
            if let request = app.confirm {
                ConfirmDialog(request: request, focus: app.confirmFocus)
            }
        }
        .alert("오류",
               isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(app.errorMessage ?? "") }
        .alert("XFinder",
               isPresented: Binding(get: { app.infoMessage != nil }, set: { if !$0 { app.infoMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(app.infoMessage ?? "") }
        .background(WindowAccessor { app.window = $0 })
        .onAppear { keyMonitor = KeyboardMonitor.install(app: app) }
        .onDisappear { KeyboardMonitor.remove(keyMonitor); keyMonitor = nil }
    }
}

/// Resolves the hosting NSWindow so the model can tell its own key events from other windows'.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

/// 확인 다이얼로그. 방향키(←→/↑↓/Tab)로 버튼 포커스를 옮기고 Enter로 실행, Esc로 취소.
/// 키 입력은 KeyboardMonitor가 처리하고, 이 뷰는 현재 포커스(`focus`)를 시각적으로 강조한다.
private struct ConfirmDialog: View {
    @Environment(AppModel.self) private var app
    let request: ConfirmRequest
    let focus: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { app.cancelConfirm() }

            VStack(spacing: 14) {
                Text(request.title).font(.system(size: 15, weight: .bold))
                Text(request.message)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    button(request.confirmTitle, index: 0, destructive: request.isDestructive)
                    button("취소", index: 1, destructive: false)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(width: 320)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
        .transition(.opacity)
    }

    private func button(_ title: String, index: Int, destructive: Bool) -> some View {
        let isFocused = focus == index
        let base: Color = destructive ? .red : Color.secondary.opacity(0.28)
        return Button { app.executeConfirm(index: index) } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(destructive ? .white : .primary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(base.opacity(destructive ? (isFocused ? 1 : 0.75) : 1)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.accentColor, lineWidth: isFocused ? 3 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Native unified toolbar
//
// The window uses the unified-compact toolbar style (see XFinderApp), so these items render
// inside the title bar — the system handles traffic-light spacing and window dragging.
private extension RootView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // Leading: system stats │ navigation arrows · location actions.
        // Each logical section is one clustered item with gaps/dividers between, so the toolbar
        // reads as distinct sections instead of one cramped run of icons.
        ToolbarItemGroup(placement: .navigation) {
            SystemStatsView()
                .padding(.leading, 8)
            sectionDivider
            HStack(spacing: 2) {
                NavButton("chevron.backward", "뒤로 — 이전 폴더로 이동 (⌘[)", disabled: !app.canGoBack) { app.goBack() }
                NavButton("chevron.forward", "앞으로 — 다음 폴더로 이동 (⌘])", disabled: !app.canGoForward) { app.goForward() }
                NavButton("chevron.up", "상위 폴더로 이동 (⌘↑)") { app.goUp() }
            }
            sectionGap
            HStack(spacing: 2) {
                NavButton("terminal", "현재 폴더를 터미널에서 열기") { app.openTerminal() }
                NavButton("calendar", "Dayflow 캘린더 열기") { app.openDayflow() }
                NavButton(text: "가나", "한글 자소 분리(NFD) 파일명 복원 — 클릭: 이 폴더 / 우클릭: 하위 폴더까지") {
                    app.fixDecomposedNames(recursive: false)
                }
                .contextMenu {
                    Button("이 폴더의 한글 파일명 복원") { app.fixDecomposedNames(recursive: false) }
                    Button("하위 폴더까지 복원") { app.fixDecomposedNames(recursive: true) }
                }
                NavButton("sparkles",
                          app.isApplicationsLocation(app.selectedFolder)
                            ? "응용 프로그램 폴더는 AI 파일 정리에서 제외됩니다"
                            : app.isProtectedLocation(app.selectedFolder)
                                ? "시스템 폴더는 AI 파일 정리에서 제외됩니다"
                                : "AI 파일 정리 — 프롬프트로 현재 폴더 파일 정리 (로컬 LLM)",
                          disabled: app.aiOrganizeBlocked(app.selectedFolder)) {
                    app.requestAIOrganize()
                }
            }
            .padding(.trailing, 14)   // 타이틀과 자연스럽게 떨어지도록 마지막 영역에 여백
        }
        // Trailing: view controls · action menu · hidden/settings │ search.
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 2) {
                iconButton(app.detail.viewMode == .full ? "square.grid.2x2" : "list.bullet",
                           app.detail.viewMode == .full ? "아이콘 보기로 전환 (⌃M)" : "목록 보기로 전환 (⌃M)") { app.toggleViewMode() }
                iconButton("folder.badge.plus", "현재 위치에 새 폴더 만들기 (⇧⌘N)") { app.requestNewFolder() }
                actionMenu
                iconButton(app.showHidden ? "eye.fill" : "eye.slash",
                           app.showHidden ? "숨김 파일 숨기기 (⇧⌘.)" : "숨김 파일 표시 (⇧⌘.)") { app.toggleHidden() }
            }
            sectionDivider
            searchField
        }
    }

    /// Whitespace between toolbar sections.
    private var sectionGap: some View { Color.clear.frame(width: 10) }

    /// A thin vertical hairline (with margin) marking a section boundary.
    private var sectionDivider: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 5)
    }

    private var actionMenu: some View {
        Menu {
            Button("열기") { app.openSelected() }
            Button("미리 보기") { app.viewSelected() }
            Divider()
            Button("복사") { app.copySelection() }
            Button("잘라내기") { app.cutSelection() }
            Button("붙여넣기") { app.paste() }.disabled(app.clipboard == nil)
            Button("복제") { app.duplicate() }
            Button("이름 변경…") { app.requestRename() }
            Divider()
            Button("압축") { app.compressSelected() }
            Button("압축 풀기") { app.extractSelected() }
            Divider()
            Button("Finder에서 보기") { app.revealInFinder() }
            Button("터미널 열기") { app.openTerminal() }
            Divider()
            Menu("한글 파일명 복원") {
                Button("이 폴더") { app.fixDecomposedNames(recursive: false) }
                Button("하위 폴더까지") { app.fixDecomposedNames(recursive: true) }
            }
            Button("AI 파일 정리…") { app.requestAIOrganize() }
            Divider()
            Button("설정…") { app.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button("휴지통으로 이동") { app.requestDelete() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14 * scale))
        }
        .menuIndicator(.hidden)
        .help("작업 — 열기·복사·이동·압축·이름 변경 등")
    }

    private var searchField: some View {
        // 기본 .roundedBorder 는 포커스 시 파란 테두리(포커스 링)를 그리고 .focusEffectDisabled()로도
        // 양옆 잔상이 남는다. plain 스타일 + 커스텀 배경으로 직접 그려 포커스 링을 완전히 없앤다.
        TextField("하위 폴더까지 검색", text: Binding(
            get: { app.detail.filter },
            set: { app.updateSearch($0) }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: 13 * scale))
        .frame(width: 170 * scale)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        )
        .focusEffectDisabled()
        .help("이름으로 검색 — 현재 폴더(하위 폴더 포함)에서 걸러냅니다")
        .padding(.trailing, 18)
    }

    private func iconButton(_ name: String, _ help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13 * scale))
                .frame(width: 26 * scale, height: 24 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
        .help(help)
    }
}

/// A rounded, hover-highlighting navigation button (back / forward / up).
/// Renders either an SF Symbol (`NavButton("chevron.left", …)`) or a short text
/// glyph (`NavButton(text: "가나", …)`); both carry a hover tooltip via `.help`.
private struct NavButton: View {
    @Environment(AppModel.self) private var app
    let symbol: String?
    let text: String?
    let help: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    private var scale: CGFloat { CGFloat(app.listScale) }

    init(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.text = nil
        self.help = help
        self.disabled = disabled
        self.action = action
    }

    init(text: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.symbol = nil
        self.text = text
        self.help = help
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(width: (text == nil ? 30 : 34) * scale, height: 26 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering && !disabled ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary)
        .onHover { hovering = $0 }
        .help(help)
    }

    @ViewBuilder
    private var label: some View {
        if let text {
            Text(text).font(.system(size: 12 * scale, weight: .semibold))
        } else {
            Image(systemName: symbol ?? "").font(.system(size: 13 * scale, weight: .semibold))
        }
    }
}

/// 설정 팝오버 — 화면 모드(시스템/라이트/다크) 선택.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var tab: SettingsTab = .general

    /// 설정 카테고리(상단 탭). 스크린샷의 Preferences처럼 아이콘+이름으로 구분한다.
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general, display, ai
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "일반"
            case .display: return "보기"
            case .ai:      return "AI"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .display: return "rectangle.grid.1x2"
            case .ai:      return "sparkles"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .general: generalTab
                    case .display: displayTab
                    case .ai:      aiTab
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 500, idealWidth: 520, minHeight: 560, idealHeight: 620)
    }

    // MARK: 상단 카테고리 탭 바

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 19))
                        Text(t.label).font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 74)
                    .padding(.vertical, 9)
                    .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(tab == t ? Color.accentColor.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
    }

    // MARK: 일반 탭 — 화면 모드 · 터미널 앱

    @ViewBuilder private var generalTab: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("화면 모드", "circle.lefthalf.filled")
            Picker("화면 모드", selection: $app.appearance) {
                ForEach(AppearanceMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.segmented).labelsHidden()
            hint("시스템: macOS 설정을 따릅니다.")
        }
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("터미널 앱", "terminal")
            Picker("터미널 앱", selection: $app.terminalApp) {
                ForEach(TerminalApp.allCases) { t in Text(t.label).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden()
            hint(terminalHint)
        }
    }

    // MARK: 보기 탭 — 목록 크기 · 폴더 용량 · 최근 항목

    @ViewBuilder private var displayTab: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("파일 목록 크기", "textformat.size")
                Spacer()
                Text("\(Int((app.listScale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    app.listScale = max(0.8, (((app.listScale - 0.05) * 20).rounded() / 20))
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).help("5% 작게")
                Slider(value: $app.listScale, in: 0.8...1.8, step: 0.05)
                Button {
                    app.listScale = min(1.8, (((app.listScale + 0.05) * 20).rounded() / 20))
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).help("5% 크게")
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("폴더 용량 계산", "sum")
            Toggle("폴더 용량 계산 및 표시", isOn: $app.calculateFolderSizes)
                .toggleStyle(.checkbox).font(.system(size: 12))
            hint("끄면 파인더처럼 폴더 용량을 계산하지 않아 탐색이 빠릅니다(폴더는 -- 로 표시).")
        }
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("최근 항목 표시 종류", "clock")
            ForEach(FileSystemService.fileTypeOrder, id: \.self) { cat in
                Toggle(cat, isOn: Binding(
                    get: { app.recentsCategories.contains(cat) },
                    set: { on in
                        if on { app.recentsCategories.insert(cat) }
                        else { app.recentsCategories.remove(cat) }
                    }
                ))
                .toggleStyle(.checkbox).font(.system(size: 12))
            }
            hint("선택한 종류만 최근 항목에 표시 (아무것도 선택 안 하면 전체).")
        }
    }

    // MARK: AI 탭 — 모델 · 정리 예외 폴더

    @ViewBuilder private var aiTab: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("AI 모델", "sparkles")
            Picker("AI 제공자", selection: $app.aiProvider) {
                ForEach(AIProvider.allCases) { p in Text(p.label).tag(p) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if app.aiProvider == .gemini {
                SecureField("Gemini API 키", text: $app.geminiAPIKey)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                TextField("모델 (예: gemini-2.5-flash)", text: $app.geminiModel)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                hint("키는 aistudio.google.com 에서 발급합니다. 정리 시 파일 이름이 구글로 전송됩니다.")
            } else {
                hint("서버 주소")
                TextField("http://localhost:11434", text: $app.ollamaBaseURL)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                hint("모델 이름")
                TextField(AIService.defaultOllamaModel, text: $app.ollamaModel)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                HStack(spacing: 6) {
                    Button("기본값") {
                        app.ollamaBaseURL = AIService.defaultOllamaBaseURL
                        app.ollamaModel = AIService.defaultOllamaModel
                    }
                    .controlSize(.small)
                    Spacer()
                }
                hint("로컬 Ollama 사용 — 입력한 모델이 없으면 자동 감지. 데이터가 기기 밖으로 나가지 않습니다.")
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("AI 정리 예외 폴더", "hand.raised")
                Spacer()
                Text("\(app.excludedPaths.count)개")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if app.excludedPaths.isEmpty {
                hint("등록된 예외 폴더가 없습니다. 폴더를 우클릭해 ‘AI 정리 예외 폴더로 등록’을 선택하세요.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(app.excludedPaths, id: \.self) { url in excludedRow(url) }
                    }
                }
                .frame(maxHeight: 132)
                hint("등록된 폴더와 그 하위 폴더 전체에서 AI 정리가 동작하지 않습니다.")
            }
        }
    }

    /// 섹션 제목(아이콘 + 굵은 회색 텍스트) — 모든 탭에서 공통 사용.
    private func sectionLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// 설명용 작은 회색 문구.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 예외 폴더 한 줄: 폴더명·경로 + Finder에서 보기·삭제 버튼.
    @ViewBuilder
    private func excludedRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(url.path).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button { SystemActions.reveal(url) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Finder에서 보기")
            Button { app.removeExcludedFolder(url) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("예외 해제")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private var terminalHint: String {
        let hasITerm = SystemActions.iTermURL() != nil
        switch app.terminalApp {
        case .auto:     return hasITerm ? "자동: iTerm이 설치되어 iTerm으로 엽니다." : "자동: iTerm이 없어 기본 터미널로 엽니다."
        case .terminal: return "기본 터미널로 엽니다."
        case .iterm:    return hasITerm ? "iTerm으로 엽니다." : "iTerm이 설치되어 있지 않아 기본 터미널로 엽니다."
        }
    }
}

/// Compact CPU / memory / disk readout for the toolbar: a coloured icon + percentage + usage bar.
/// Clicking CPU or 메모리 opens a detailed popup. Each metric has its own colour.
struct SystemStatsView: View {
    @Environment(AppModel.self) private var app
    private let monitor = SystemMonitor.shared
    @State private var showCPU = false
    @State private var showMemory = false
    @State private var showDisk = false

    private var scale: CGFloat { CGFloat(app.listScale) }

    var body: some View {
        HStack(spacing: 11 * scale) {
            Button { showCPU = true } label: { stat("cpu", .blue, monitor.cpuUsage) }
                .buttonStyle(.plain)
                .help("CPU 사용량 — 클릭하면 추이·온도·부하 프로세스 보기")
                .popover(isPresented: $showCPU, arrowEdge: .bottom) { CPUDetailView(monitor: monitor) }

            Button { showMemory = true } label: { stat("memorychip", .purple, monitor.memoryUsage) }
                .buttonStyle(.plain)
                .help("메모리 사용량 — 클릭하면 앱·캐시·스왑 상세 보기")
                .popover(isPresented: $showMemory, arrowEdge: .bottom) { MemoryDetailView(monitor: monitor) }

            Button { showDisk = true } label: { stat("internaldrive", .orange, monitor.diskUsage) }
                .buttonStyle(.plain)
                .help("디스크 사용량 — 클릭하면 용량 분류·S.M.A.R.T. 상태 보기")
                .popover(isPresented: $showDisk, arrowEdge: .bottom) {
                    DiskDetailView(monitor: monitor)
                }
        }
    }

    private func stat(_ icon: String, _ color: Color, _ value: Double) -> some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: icon).font(.system(size: 12 * scale)).foregroundStyle(color)
            Text(pct(value)).font(.system(size: 11 * scale, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1).fixedSize()                 // "100%"도 한 줄로 (디자인 깨짐 방지)
        }
        .contentShape(Rectangle())
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", (v * 100).rounded()) }
}

/// Clickable breadcrumb of the selected folder. Double-click (or the pencil) switches to a text
/// field so a path can be typed directly; Return navigates, Esc cancels.
private struct PathBar: View {
    @Environment(AppModel.self) private var app
    @State private var isEditing = false
    @State private var pathText = ""
    @FocusState private var fieldFocused: Bool

    private var segments: [(name: String, url: URL)] {
        var parts: [(String, URL)] = []
        var current = app.selectedFolder
        while true {
            let name = current.path == "/" ? "Macintosh HD" : current.lastPathComponent
            parts.append((name, current))
            if current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return parts.reversed()
    }

    var body: some View {
        if app.detail.recentsMode {
            specialBar(icon: "clock.fill", title: "최근 항목", color: .secondary)
        } else if app.detail.tagMode, let name = app.detail.tagName {
            specialBar(icon: "circle.fill", title: name,
                       color: TagService.standard.first { $0.name == name }?.color ?? .secondary)
        } else {
            editableBar
        }
    }

    private func specialBar(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var editableBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
            if isEditing {
                TextField("경로 입력 (예: ~/Downloads)", text: $pathText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                Button { commit() } label: {
                    Image(systemName: "arrow.right.circle.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("이동")
            } else {
                breadcrumb
                Button { beginEditing() } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("경로 직접 입력")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: app.selectedFolder) { _, _ in isEditing = false }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    Button { app.select(segment.url) } label: {
                        Text(segment.name).font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == segments.count - 1 ? Color.primary : Color.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEditing() }
    }

    private func beginEditing() {
        pathText = app.selectedFolder.path
        isEditing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        if !trimmed.isEmpty { app.goToFolder(trimmed) }
    }
}
