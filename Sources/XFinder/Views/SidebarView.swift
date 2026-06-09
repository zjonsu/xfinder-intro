import SwiftUI
import AppKit

extension View {
    /// 조건에 따라 서로 다른 수정자를 적용할 때 쓰는 헬퍼(@ViewBuilder로 분기 타입을 합쳐준다).
    @ViewBuilder func modify<V: View>(@ViewBuilder _ transform: (Self) -> V) -> some View {
        transform(self)
    }
}

/// The Finder-style left sidebar: titled sections of pinned links plus an expandable folder tree.
struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(app.sections) { section in
                    Text(section.title)
                        .font(.system(size: 11 * CGFloat(app.listScale), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(section.items) { item in
                        SidebarRowView(item: item)
                    }
                }
            }
            .padding(6)
        }
        // No opaque background: let the NavigationSplitView's translucent Liquid Glass sidebar
        // material (behind-window blur) show through — matching native Finder on macOS 26.
        .scrollContentBackground(.hidden)
    }
}

private struct SidebarRowView: View {
    @Environment(AppModel.self) private var app
    @Bindable var item: SidebarItem
    @State private var lastTapAt: Date = .distantPast

    private var scale: CGFloat { CGFloat(app.listScale) }

    private var isSelected: Bool {
        app.selectedSidebarID == item.id
    }

    /// Highlight is full-accent only when the sidebar holds keyboard focus; otherwise it dims
    /// (matching macOS, so you can see which pane the arrow keys will drive).
    private var isFocusedSelection: Bool {
        isSelected && app.focusedPane == .sidebar
    }

    private var rowBackground: Color {
        if isFocusedSelection { return Color.accentColor }
        if isSelected { return Color.secondary.opacity(0.25) }
        return .clear
    }

    /// 폴더 행은 밖으로 끌어 이동/복사할 수 있는 드래그 소스가 된다(오른쪽 패널이나 다른 즐겨찾기 폴더로).
    private var isDraggable: Bool {
        item.kind == .folder && item.url != nil
    }

    /// 즐겨찾기 섹션의 최상위 항목인가(드래그로 순서 변경 가능). 위치/드라이브/하위 폴더는 제외.
    private var isReorderableFavorite: Bool {
        item.kind == .folder && item.depth == 0 && item.url.map { app.isFavorite($0) } == true
    }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(item.depth) * 15 * scale)

                if item.canExpand {
                    Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundStyle(isFocusedSelection ? Color.white.opacity(0.9) : .secondary)
                        .frame(width: 13 * scale, height: 13 * scale)
                        .contentShape(Rectangle())
                        .onTapGesture { app.focusedPane = .sidebar; app.toggleExpand(item) }
                } else {
                    Color.clear.frame(width: 13 * scale)
                }

                // 아이콘 + 이름. 폴더 행은 여기서 끌어내 이동/복사한다(⌃ = 복사).
                // 디스클로저(▶) 화살표는 위에서 따로 탭을 받으므로 펼치기/접기가 그대로 동작한다.
                HStack(spacing: 5) {
                    // 태그는 색 점, 나머지는 파인더처럼 외곽선(non-fill) 심볼 + 흑백으로 통일
                    // (응용 프로그램도 동일하게 모노크롬 심볼을 써서 다른 항목과 어울리게).
                    if item.kind == .tag {
                        Circle()
                            .fill(TagService.standard.first { $0.name == item.title }?.color ?? .secondary)
                            .frame(width: 11 * scale, height: 11 * scale)
                            .frame(width: 22 * scale)
                    } else {
                        Image(systemName: item.icon.replacingOccurrences(of: ".fill", with: ""))
                            .font(.system(size: 14.5 * scale))
                            .foregroundStyle(isFocusedSelection ? .white : .primary)
                            .frame(width: 22 * scale)
                    }

                    Text(item.title)
                        .font(.system(size: 13.5 * scale))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 5 * scale)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .foregroundStyle(isFocusedSelection ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // 행 전체(아이콘·이름은 물론 여백·빈 공간까지)를 클릭/드래그 영역으로 삼는다. 파인더처럼
            // 이름을 살짝 벗어나도 선택되도록 탭 제스처를 안쪽 HStack이 아니라 행 컨테이너에 붙인다.
            // 디스클로저(▶) 화살표는 자체 탭을 따로 받으므로 그 위에서는 펼치기/접기가 우선한다.
            .contentShape(Rectangle())
            .onTapGesture { handleTap() }
            // 폴더 행을 드래그 소스로. 즐겨찾기 항목이면 드래그 시작 시 app.draggingFavorite에 표시해,
            // 다른 즐겨찾기 위에 놓으면 순서 변경(아래 FolderDrop이 실제 페이로드로 검증해 처리)으로 동작.
            .modify { view in
                if isDraggable, let url = item.url {
                    view.onDrag {
                        app.draggingFavorite = isReorderableFavorite ? url : nil
                        return NSItemProvider(object: url as NSURL)
                    }
                } else {
                    view
                }
            }
            // 즐겨찾기/트리 폴더 행 위로 파일을 끌어다 놓으면 그 폴더로 이동(⌃ = 복사)한다.
            .modifier(FolderDropModifier(enabled: item.kind == .folder && item.url != nil,
                                         folder: item.url ?? URL(fileURLWithPath: "/"), app: app))
            .contextMenu {
                if item.kind == .folder, let url = item.url {
                    if app.isFavorite(url) {
                        Button("즐겨찾기에서 제거") { app.removeFavorite(url) }
                    } else {
                        Button("즐겨찾기에 추가") { app.addFavorite(url) }
                    }
                    Divider()
                    Button("Finder에서 보기") { SystemActions.reveal(url) }
                    Button("터미널에서 열기") { SystemActions.openTerminal(at: url) }
                }
            }

            if item.isExpanded, let children = item.children {
                ForEach(children) { child in
                    SidebarRowView(item: child)
                }
            }
        }
    }

    /// 단일 클릭: 즉시 이동. 빠른 더블클릭: 하위 폴더 펼치기/접기.
    private func handleTap() {
        app.focusedPane = .sidebar
        let now = Date()
        if now.timeIntervalSince(lastTapAt) < NSEvent.doubleClickInterval {
            if item.canExpand { app.toggleExpand(item) }
            lastTapAt = .distantPast
        } else {
            app.activateSidebar(item)
            lastTapAt = now
        }
    }
}

