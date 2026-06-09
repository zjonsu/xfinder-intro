import SwiftUI
import AppKit

@main
struct XFinderApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowRoot()
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)   // toolbar merged into the native title bar (Liquid Glass)
        .commands { AppCommands() }
    }
}

/// One independent browser window: each gets its own `AppModel`, so navigation, selection and history
/// are separate per window. The system stats monitor is a shared singleton across all windows.
private struct WindowRoot: View {
    @State private var app = AppModel()

    var body: some View {
        RootView()
            .environment(app)
            .environment(SystemMonitor.shared)
            .fontDesign(.rounded)   // 앱 전체 UI를 둥근(SF Rounded) 시스템 폰트로 통일
            .frame(minWidth: 760, minHeight: 460)
            .focusedSceneValue(\.appModel, app)   // routes menu commands to the active window
            .onAppear { app.bootstrap(); SystemMonitor.shared.start(); app.applyAppearance() }
    }
}

// MARK: - Active-window routing for menu commands

private struct AppModelFocusedKey: FocusedValueKey { typealias Value = AppModel }
extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedKey.self] }
        set { self[AppModelFocusedKey.self] = newValue }
    }
}

/// Menu bar commands. They act on the *focused* window's `AppModel` (via `@FocusedValue`), so each
/// window's menu/shortcuts drive that window. The global `KeyboardMonitor` covers list navigation keys.
private struct AppCommands: Commands {
    @FocusedValue(\.appModel) private var app: AppModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("XFinder 정보") { app?.sheet = .about }
        }
        // macOS 앱 메뉴(XFinder ▸)의 표준 "설정…"(⌘,) 자리에 단독 설정 창 열기를 연결.
        CommandGroup(replacing: .appSettings) {
            Button("설정…") { app?.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        // The menu items carry real keyboard shortcuts so the OS always routes them, even when the
        // global KeyboardMonitor can't (e.g. a text field holds focus). No double-fire: when the
        // monitor handles a key it returns nil, so the event never reaches the menu.
        CommandGroup(replacing: .newItem) {
            Button("새 창") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: .command)
            Button("새 폴더") { app?.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.shift, .command])
        }
        // Replace the system Cut/Copy/Paste so OUR items own ⌘X/⌘C/⌘V (otherwise the system items
        // claim the shortcuts but stay disabled over a file list, swallowing the keys). The actions
        // forward to the focused text field when one is editing, so search-field copy/paste still works.
        CommandGroup(replacing: .pasteboard) {
            Button("복사") { app?.copyShortcut() }
                .keyboardShortcut("c", modifiers: .command)
            Button("경로 복사") { app?.copySelectedPath() }
                .keyboardShortcut("c", modifiers: [.option, .command])
            Button("잘라내기") { app?.cutShortcut() }
                .keyboardShortcut("x", modifiers: .command)
            Button("붙여넣기") { app?.pasteShortcut() }
                .keyboardShortcut("v", modifiers: .command)
            Button("복제") { app?.duplicate() }
                .keyboardShortcut("d", modifiers: .command)
            Button("이름 변경 (F2)") { app?.requestRename() }
            Button("휴지통으로 이동") { app?.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandMenu("이동") {
            Button("뒤로") { app?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("앞으로") { app?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Button("상위 폴더") { app?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("선택 항목 열기") { app?.openSelected() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("폴더로 이동") { app?.requestGoToFolder() }
                .keyboardShortcut("g", modifiers: [.shift, .command])
            Button("Finder에서 보기") { app?.revealInFinder() }
            Button("터미널 열기") { app?.openTerminal() }
        }
        CommandMenu("작업") {
            Button("기본 앱으로 열기 (F4)") { app?.editSelected() }
            Button("미리 보기 (Space)") { app?.viewSelected() }
            Divider()
            Button("압축") { app?.compressSelected() }
            Button("압축 풀기") { app?.extractSelected() }
            Divider()
            Button("새로고침") { app?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("숨김 파일 표시/숨기기") { app?.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.shift, .command])
            Button("보기 전환 목록/아이콘") { app?.toggleViewMode() }
                .keyboardShortcut("m", modifiers: .control)
            Divider()
            Menu("화면 모드") {
                Button("시스템") { app?.appearance = .system }
                Button("라이트") { app?.appearance = .light }
                Button("다크") { app?.appearance = .dark }
            }
            Divider()
            Button("키보드 단축키") { app?.showHelp() }
        }
        // 상단 macOS "도움말(Help)" 메뉴에 사용설명서를 추가한다.
        CommandGroup(replacing: .help) {
            Button("XFinder 사용설명서") { app?.sheet = .manual }
                .keyboardShortcut("/", modifiers: .command)
            Button("키보드 단축키") { app?.showHelp() }
        }
    }
}
