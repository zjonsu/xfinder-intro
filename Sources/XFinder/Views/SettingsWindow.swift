import SwiftUI
import AppKit

/// 설정을 툴바에 붙은 팝오버가 아니라 **단독 창**으로 띄운다. 메뉴(⌘,)나 ⋯ 작업 메뉴에서 호출하며,
/// 한 번에 하나의 창만 유지한다(이미 열려 있으면 앞으로 가져온다). 창은 호출한 윈도우의 AppModel을
/// 환경으로 캡처하므로, 설정 창이 키 윈도우가 되어도 그 모델을 계속 편집한다.
@MainActor
enum SettingsWindowPresenter {
    private static var controller: NSWindowController?

    static func show(app: AppModel) {
        // 이미 열려 있으면 다시 만들지 않고 앞으로.
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView()
            .environment(app)
            .fontDesign(.rounded)   // 앱 전체 톤과 동일하게 둥근 폰트
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        window.titlebarAppearsTransparent = false

        let wc = NSWindowController(window: window)
        controller = wc
        // 창을 닫으면 컨트롤러 참조를 비워 다음에 새로 만들도록 한다.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            MainActor.assumeIsolated { controller = nil }
        }

        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
