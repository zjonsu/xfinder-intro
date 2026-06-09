import SwiftUI
import AppKit

// MARK: - File viewer (fallback; Space uses the native Quick Look via SystemActions.quickLook)

struct ViewerSheet: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var content: Content = .loading

    enum Content {
        case loading
        case image(NSImage)
        case text(String)
        case none(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name).font(.headline).lineLimit(1)
                Spacer()
                Button("앱으로 열기") { SystemActions.open(item.url) }
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            Group {
                switch content {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .image(let image):
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().scaledToFit().padding()
                    }
                case .text(let string):
                    ScrollView {
                        Text(string)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                case .none(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                        Text(message).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 640, height: 520)
        .task(id: item.url) { content = await Self.load(item) }
    }

    /// Read/decode off the main thread so large files or slow volumes don't freeze the UI.
    private static func load(_ item: FileItem) async -> Content {
        await Task.detached(priority: .userInitiated) {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp", "icns"]
            if imageExts.contains(item.ext), let image = NSImage(contentsOf: item.url) {
                return Content.image(image)
            }
            if let handle = try? FileHandle(forReadingFrom: item.url) {
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 1_000_000)) ?? Data()
                if let string = String(data: data, encoding: .utf8) {
                    return Content.text(string)
                }
            }
            return Content.none("“\(item.name)”은(는) 미리 볼 수 없습니다.")
        }.value
    }
}

// MARK: - Go to folder (⇧⌘G)

struct GoToFolderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("폴더로 이동").font(.headline)
            TextField("/경로/폴더  또는  ~/Documents", text: $path)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .focused($focused)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("이동") { go() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            path = app.selectedFolder.path
            DispatchQueue.main.async { focused = true }
        }
    }

    private func go() {
        app.goToFolder(path)
        dismiss()
    }
}

// MARK: - New folder (F7)

struct NewFolderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = "제목 없는 폴더"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("새 폴더").font(.headline)
            TextField("폴더 이름", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("생성") { create() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func create() {
        app.createFolder(named: name)
        dismiss()
    }
}

// MARK: - Rename (F2)

struct RenameSheet: View {
    let item: FileItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이름 변경").font(.headline)
            TextField("이름", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($focused)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("변경") { rename() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            name = item.name
            DispatchQueue.main.async { focused = true }
        }
    }

    private func rename() {
        app.rename(item, to: name)
        dismiss()
    }
}

// MARK: - Operation progress

struct ProgressSheet: View {
    let progress: OperationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.title).font(.headline)
            ProgressView(value: progress.fraction)
                .frame(width: 360)
            Text(progress.currentFile)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 360, alignment: .leading)
            HStack {
                Text("\(progress.completedUnits) / \(progress.totalUnits)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("취소") { progress.isCancelled = true }
            }
            .frame(width: 360)
        }
        .padding(20)
    }
}

// MARK: - About (앱 정보)

/// 예쁜 앱 정보 화면 — 앱 아이콘 + 이름/버전 + 개발자 정보.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let poem = """
    저것은 벽
    어쩔 수 없는 벽이라고 우리가 느낄 때
    그때 담쟁이는 말없이 그 벽을 오른다

    물 한 방울 없고 씨앗 한 톨 살아남을 수 없는
    저것은 절망의 벽이라고 말할 때
    담쟁이는 서두르지 않고 앞으로 나아간다

    한 뼘이라도 꼭 여럿이 함께 손을 잡고 올라간다
    푸르게 절망을 다 덮을 때까지
    바로 그 절망을 잡고 놓지 않는다

    저것은 넘을 수 없는 벽이라고
    고개를 떨구고 있을 때
    담쟁이 잎 하나는 담쟁이 잎 수천 개를 이끌고
    결국 그 벽을 넘는다
    """

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b != nil ? "버전 \(v) (\(b!))" : "버전 \(v)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 컴팩트한 그라데이션 헤더 — 앱 아이콘 + 타이틀/버전을 한 줄로.
            ZStack {
                LinearGradient(colors: [Color(red: 0.21, green: 0.55, blue: 0.99),
                                        Color(red: 0.49, green: 0.31, blue: 0.96)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 52, height: 52)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("XFinder").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        Text(version).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
            }
            .frame(height: 92)

            VStack(spacing: 14) {
                Text("사이드바 + 상세 보기 파일 관리자")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                // 개발자 정보 — 한 줄(아이콘 + 이름 · 역할 · 이메일).
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [.indigo, .blue],
                                                     startPoint: .top, endPoint: .bottom))
                            .frame(width: 30, height: 30)
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    }
                    Text("정종수").font(.system(size: 13, weight: .semibold))
                    Text("·").foregroundStyle(.secondary)
                    Text("Developer").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    // 일반 Text로 표시해 키보드 포커스 테두리(파란 박스)가 생기지 않게 한다.
                    // 클릭하면 메일 작성이 열린다.
                    Text("zjonsu@gmail.com")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.blue)
                        .onTapGesture { NSWorkspace.shared.open(URL(string: "mailto:zjonsu@gmail.com")!) }
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))

                // 담쟁이 — 도종환 (애플명조로 예쁘게)
                VStack(spacing: 8) {
                    Text("담쟁이").font(.system(size: 14, weight: .semibold))
                    Text("— 도종환").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(Self.poem)
                        .font(.custom("AppleMyungjo", size: 13))
                        .foregroundStyle(.primary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)

                Button("확인") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 420)
    }
}

// MARK: - 사용설명서 (User manual)

/// 앱 전체 사용설명서 — 그라데이션 헤더 + 스크롤되는 섹션 카드 + 실제 화면 캡처 + 키보드 단축키 표.
struct ManualSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    layoutSection
                    navigationSection
                    fileOpsSection
                    dragDropSection
                    sidebarSection
                    tagSection
                    recentsSearchSection
                    viewSection
                    contextMenuSection
                    monitorSection
                    shortcutSection
                    footer
                }
                .padding(22)
            }
        }
        .frame(width: 660, height: 760)
    }

    // MARK: 헤더

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.21, green: 0.55, blue: 0.99),
                                    Color(red: 0.49, green: 0.31, blue: 0.96)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("XFinder 사용설명서")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Text("사이드바 + 상세 보기 파일 관리자 — 한눈에 보는 전체 안내")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()       // 사각형 포커스 테두리 제거
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
        .frame(height: 96)
    }

    // MARK: 섹션 1 — 화면 구성 (실제 캡처 + 범례)

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("rectangle.3.group", .blue, "화면 구성")
            card {
                feature("slider.horizontal.3", .blue,   "도구 막대", "창 위쪽 — 뒤로·앞으로·상위 이동, 검색창, CPU/메모리/디스크 사용량")
                feature("sidebar.left",        .indigo, "사이드바",  "왼쪽 — 즐겨찾기와 위치(드라이브) 트리. 클릭해서 폴더로 이동")
                feature("list.bullet",         .teal,   "파일 목록", "가운데 — 이름·크기·수정일. 더블클릭으로 열기/폴더 진입")
                feature("info.circle",         .gray,   "상태 막대", "창 아래쪽 — 현재 폴더의 항목 수와 선택 정보")
            }
        }
    }

    // MARK: 섹션 2 — 기본 탐색

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("arrow.up.arrow.down", .green, "기본 탐색")
            card {
                feature("cursorarrow.rays", .green, "커서 이동", "↑ ↓ 로 항목 사이를 이동하고, PageUp/PageDown · Home/End 로 빠르게 건너뜁니다.")
                feature("arrow.turn.down.right", .green, "폴더 진입 / 열기", "Return 으로 폴더에 들어가거나 파일을 엽니다. 더블클릭도 동일합니다.")
                feature("arrow.uturn.backward", .green, "뒤로 · 앞으로 · 상위", "⌘[ ⌘] (또는 ⌘← ⌘→)로 방문 기록을 오가고, ⌘↑ 또는 ⌫ 로 상위 폴더로 갑니다.")
                feature("sidebar.left", .green, "포커스 전환", "Tab 으로 사이드바 ⇄ 파일 목록 포커스를 전환합니다. 사이드바에서는 ↑↓ 이동, → 펼치기, ← 접기.")
                feature("plus.rectangle.on.rectangle", .green, "새 창", "⌘N 으로 독립된 새 창을 엽니다. 창마다 탐색·선택·히스토리가 따로 유지됩니다.")
                feature("text.cursor", .green, "폴더로 이동", "⇧⌘G 로 경로를 직접 입력해 그 폴더로 한 번에 이동합니다.")
                feature("arrow.up.forward.app", .green, "Finder · 터미널 열기", "‘이동’ 메뉴 또는 우클릭으로 현재/선택 위치를 macOS Finder에서 보거나 터미널로 엽니다.")
            }
        }
    }

    // MARK: 섹션 3 — 파일 작업

    private var fileOpsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("doc.on.doc", .orange, "파일 작업")
            card {
                feature("doc.on.doc", .orange, "복사 · 잘라내기 · 붙여넣기", "⌘C / ⌘X 로 담고 ⌘V 로 붙여넣습니다. 여러 항목을 ⌘·⇧ 클릭으로 선택할 수 있습니다.")
                feature("doc.on.clipboard", .orange, "경로 복사", "⌥⌘C 로 선택 항목의 전체 경로를 텍스트로 복사합니다(여러 개면 줄바꿈으로 구분). 우클릭 메뉴에도 있습니다.")
                feature("plus.square.on.square", .orange, "복제", "⌘D 로 같은 폴더에 사본을 만듭니다.")
                feature("pencil", .orange, "이름 변경", "F2 를 누르고 새 이름을 입력한 뒤 Return.")
                feature("folder.badge.plus", .orange, "새 폴더", "⇧⌘N 으로 현재 위치에 새 폴더를 만듭니다.")
                feature("archivebox", .orange, "압축 · 압축 풀기", "선택 항목을 우클릭 → 압축(.zip), zip 파일은 우클릭 → 압축 풀기.")
                feature("square.and.arrow.up", .orange, "공유", "우클릭 → ‘공유’로 macOS 공유 시트(메일·메시지·AirDrop 등)에 선택 파일을 바로 넘깁니다.")
                feature("trash", .red, "휴지통으로 이동", "⌘⌫ 로 선택 항목을 휴지통에 넣습니다.")
                feature("xmark.bin", .red, "응용 프로그램 삭제", "`응용 프로그램`의 앱을 우클릭 → ‘응용 프로그램 삭제…’ 하면 환경설정·캐시·지원 파일 등 관련 항목을 함께 찾아 체크해 한 번에 휴지통으로 보냅니다(AppCleaner 방식).")
            }
        }
    }

    // MARK: 섹션 4 — 드래그 & 드롭

    private var dragDropSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("hand.draw", .pink, "드래그 & 드롭")
            card {
                feature("arrow.right.doc.on.clipboard", .pink, "목록에서 끌어 이동", "파일을 폴더 위로 끌어다 놓으면 그 폴더로 이동합니다.")
                feature("star", .pink, "사이드바로 끌기", "왼쪽 사이드바의 즐겨찾기·폴더 위로 끌어다 놓아도 이동/복사됩니다.")
                feature("square.and.arrow.up", .pink, "다른 앱으로 내보내기", "파일을 메일·메신저·바탕화면 등 다른 앱으로 끌면 복사됩니다.")
                tipRow("끌어 놓을 때 ⌃(Control) 을 누르고 있으면 ‘이동’ 대신 ‘복사’가 됩니다.")
            }
        }
    }

    // MARK: 섹션 5 — 즐겨찾기 & 사이드바

    private var sidebarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("star.fill", .yellow, "즐겨찾기 & 사이드바")
            card {
                feature("star.circle", .yellow, "즐겨찾기 추가/제거", "폴더를 우클릭 → ‘즐겨찾기에 추가/제거’. 자주 쓰는 위치를 사이드바 맨 위에 고정합니다.")
                feature("chevron.right", .yellow, "폴더 트리 펼치기", "사이드바 항목의 ▶ 화살표로 하위 폴더를 펼치거나 접습니다.")
                feature("externaldrive", .yellow, "위치(드라이브)", "‘위치’ 섹션에서 홈 폴더와 연결된 드라이브/볼륨에 바로 접근합니다.")
            }
        }
    }

    // MARK: 섹션 — 색 태그

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("tag.fill", .red, "색 태그")
            card {
                feature("tag", .red, "태그 지정", "파일/폴더를 우클릭 → ‘태그’에서 빨강·주황·노랑·초록·파랑·보라·회색을 켜고 끕니다. 여러 색을 동시에 붙일 수 있고, macOS Finder 태그와 호환됩니다.")
                feature("tag.slash", .gray, "태그 제거", "우클릭 → ‘태그’ → ‘태그 모두 제거’로 선택 항목의 색 태그를 한 번에 지웁니다.")
                feature("line.3.horizontal.decrease.circle", .red, "태그로 모아보기", "사이드바 ‘태그’ 섹션에서 색을 클릭하면 그 태그가 붙은 파일만 시스템 전체에서 모아 보여줍니다(Spotlight 기반). 우클릭 → ‘위치로 이동’으로 실제 폴더로 갈 수 있습니다.")
            }
        }
    }

    // MARK: 섹션 6 — 최근 항목 & 검색

    private var recentsSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("clock.arrow.circlepath", .blue, "최근 항목 & 검색")
            card {
                feature("clock", .blue, "최근 항목", "사이드바 ‘최근 항목’은 최근 사용한 파일을 최신순으로 보여줍니다(Spotlight 기반).")
                feature("magnifyingglass", .blue, "검색", "도구 막대 오른쪽 검색창에 입력하면 현재 폴더 안을 빠르게 걸러냅니다.")
                feature("arrow.uturn.left", .blue, "위치로 이동", "검색/최근 항목에서 파일을 우클릭 → ‘위치로 이동’ 하면 실제 폴더로 이동합니다.")
            }
        }
    }

    // MARK: 섹션 7 — 보기 & 미리보기

    private var viewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("eye", .purple, "보기 & 미리보기")
            card {
                feature("square.grid.2x2", .purple, "목록 / 아이콘 전환", "⌃M 으로 목록 보기와 아이콘 보기를 전환합니다. 폴더마다 마지막 보기 방식을 기억합니다.")
                feature("eye", .purple, "빠른 보기", "Space (또는 F3) 로 선택 파일을 즉시 미리봅니다(이미지·텍스트 등).")
                feature("app.badge", .purple, "기본 앱으로 열기 / 다른 앱으로", "F4 로 macOS 기본 앱에서 열거나, 우클릭 → ‘다음으로 열기’에서 앱을 골라(‘기타…’ 포함) 엽니다.")
                feature("arrow.up.arrow.down", .purple, "정렬", "열 머리글(이름·크기·종류·수정일·생성일)을 클릭하면 그 기준으로 정렬되고, 다시 누르면 오름/내림차순이 바뀝니다. 빈 영역 우클릭 → ‘정렬 기준’에서도 선택할 수 있습니다.")
                feature("circle.lefthalf.filled", .purple, "화면 모드", "‘작업 ▸ 화면 모드’에서 시스템 · 라이트 · 다크를 전환합니다. 선택은 다음 실행에도 유지됩니다.")
                feature("eye.slash", .purple, "숨김 파일", "⇧⌘. 로 숨김 파일 표시를 켜고 끕니다.")
            }
        }
    }

    // MARK: 섹션 — 우클릭 메뉴

    private var contextMenuSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("contextualmenu.and.cursorarrow", .indigo, "우클릭 메뉴")
            card {
                feature("doc.text", .indigo, "항목 메뉴", "파일/폴더를 우클릭하면 열기·다음으로 열기·Finder에서 보기·공유·태그·복사/경로 복사/잘라내기/붙여넣기·복제·이름 변경·즐겨찾기·압축/풀기·휴지통이 한 메뉴에 모입니다.")
                feature("rectangle.dashed", .indigo, "빈 영역 메뉴", "목록의 빈 공간을 우클릭하면 새 폴더·붙여넣기·보기(목록/아이콘)·정렬 기준·숨김 항목 보기·새로 고침이 나오는 배경 메뉴가 열립니다.")
                tipRow("검색·최근 항목·태그 모아보기처럼 실제 폴더가 아닐 때는 ‘새 폴더·붙여넣기’가 숨겨지고 보기/정렬만 표시됩니다.")
            }
        }
    }

    // MARK: 섹션 8 — 시스템 모니터

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("speedometer", .red, "시스템 모니터")
            card {
                feature("cpu", .red, "CPU", "도구 막대의 CPU 사용량을 클릭하면 추이 그래프·온도·부하가 큰 프로세스를 봅니다.")
                feature("memorychip", .red, "메모리", "메모리 사용량을 클릭하면 앱·캐시·스왑 등 상세 내역이 열립니다.")
                feature("internaldrive", .red, "디스크", "디스크 사용량을 클릭하면 용량 분류와 S.M.A.R.T. 상태를 확인합니다.")
            }
        }
    }

    // MARK: 섹션 9 — 키보드 단축키 표

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("keyboard", .gray, "키보드 단축키")
            VStack(alignment: .leading, spacing: 14) {
                shortcutGroup("탐색", [
                    (["↑", "↓"], "커서 이동"),
                    (["Return"], "열기 / 폴더 진입"),
                    (["⌘", "↓"], "선택 항목 열기"),
                    (["⌘", "↑"], "상위 폴더 (또는 ⌫)"),
                    (["⌘", "["], "뒤로 (또는 ⌘←)"),
                    (["⌘", "]"], "앞으로 (또는 ⌘→)"),
                    (["Tab"], "사이드바 ⇄ 목록"),
                ])
                shortcutGroup("파일", [
                    (["⌘", "C"], "복사"),
                    (["⌥", "⌘", "C"], "경로 복사"),
                    (["⌘", "X"], "잘라내기"),
                    (["⌘", "V"], "붙여넣기"),
                    (["⌘", "D"], "복제"),
                    (["F2"], "이름 변경"),
                    (["⌘", "⌫"], "휴지통으로"),
                    (["⇧", "⌘", "N"], "새 폴더"),
                ])
                shortcutGroup("보기 · 기타", [
                    (["Space"], "빠른 보기 (F3)"),
                    (["F4"], "기본 앱으로 열기"),
                    (["⌃", "M"], "목록 / 아이콘"),
                    (["⌘", "R"], "새로고침 (F5)"),
                    (["⇧", "⌘", "."], "숨김 파일"),
                    (["⇧", "⌘", "G"], "폴더로 이동"),
                    (["⌘", "N"], "새 창"),
                    (["⌘", "/"], "이 사용설명서"),
                ])
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("XFinder · 정종수")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - 재사용 구성요소

    private func sectionHeader(_ symbol: String, _ color: Color, _ title: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(color.gradient).frame(width: 30, height: 30)
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            Text(title).font(.system(size: 17, weight: .bold))
            Spacer(minLength: 0)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(color).frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill").font(.system(size: 12)).foregroundStyle(.yellow)
            Text(text).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.yellow.opacity(0.12)))
    }

    private func shortcutGroup(_ title: String, _ rows: [([String], String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        ForEach(Array(row.0.enumerated()), id: \.offset) { _, k in KeyCap(k) }
                    }
                    .frame(width: 132, alignment: .leading)
                    Text(row.1).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                    Spacer(minLength: 0)
                }
            }
        }
    }

}

/// 단축키 한 글자를 키캡 모양으로 그린다.
private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(minWidth: 18)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}
