import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Makes a folder row / icon cell a drop target: files dragged onto it (from within XFinder, Finder,
/// or any other app) are moved into it — or copied when ⌃ (Control) is held. Highlights while targeted.
struct FolderDropModifier: ViewModifier {
    let enabled: Bool
    let folder: URL
    let app: AppModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrop(of: [.fileURL], delegate: FolderDrop(folder: folder, app: app))
        } else {
            content
        }
    }
}

private struct FolderDrop: DropDelegate {
    let folder: URL
    let app: AppModel

    /// ⌃ (Control) held → copy, otherwise move.
    private var copyHeld: Bool {
        NSEvent.modifierFlags.contains(.control)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: copyHeld ? .copy : .move)
    }

    /// 드래그가 행 위로 들어오는 순간 라이브로 처리한다. 즐겨찾기를 다른 즐겨찾기 위로 끌면, 그 즉시
    /// 순서를 바꿔(애니메이션) 파인더처럼 다른 행이 밀려나게 한다. 비-즐겨찾기 영역(상세 패널/일반
    /// 폴더)에 파일 드래그가 들어오면 잔존 플래그를 정리해 오작동을 막는다.
    func dropEntered(info: DropInfo) {
        guard let dragged = app.draggingFavorite else { return }
        if app.isFavorite(folder) {
            if dragged.standardizedFileURL.path != folder.standardizedFileURL.path {
                withAnimation(.easeInOut(duration: 0.16)) {
                    app.moveFavorite(fromPath: dragged.path, toBefore: folder)
                }
            }
        } else {
            app.draggingFavorite = nil   // 파일 드래그가 비-즐겨찾기 영역에 들어옴 → 플래그 정리
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let copy = copyHeld
        let folder = folder
        let app = app
        let dragged = app.draggingFavorite
        app.draggingFavorite = nil
        loadFileURLs(from: info.itemProviders(for: [.fileURL])) { urls in
            let droppedIsDragged = dragged != nil && urls.count == 1
                && urls[0].standardizedFileURL.path == dragged!.standardizedFileURL.path
            if droppedIsDragged {
                // 즐겨찾기 재정렬: dropEntered에서 이미 라이브로 반영·저장됨 → 추가 동작 없음.
                // (비-즐겨찾기 위에 떨궈도 폴더를 이동시키지 않는다.)
            } else {
                app.dropFiles(urls, onto: folder, copy: copy)
            }
        }
        return true
    }
}

/// Resolve file URLs from drag item providers, then deliver them on the main actor.
func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    guard !providers.isEmpty else { completion([]); return }
    var urls: [URL] = []
    let lock = NSLock()
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            if let url = object as? URL, url.isFileURL {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}
