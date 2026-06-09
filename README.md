# XFinder

macOS용 네이티브 파일 관리자 — **macOS Finder / Windows 탐색기 스타일**의 사이드바 + 상세 보기 레이아웃.
SwiftUI + Swift Package Manager로 작성되었으며 Xcode 프로젝트 없이 빌드/실행됩니다.

![layout](docs/layout.png)

## 레이아웃

```
┌──────────────┬──────────────────────────────────────────┐
│  즐겨찾기      │  ‹ › ⌃  Macintosh HD › Users › zjonsu     │  ← 경로(브레드크럼) + 툴바
│   AirDrop     ├──────────────────────────────────────────┤
│   응용 프로그램 │  이름            크기   수정일      종류    │
│   데스크탑     │  📁 Applications  --    2026-…    Folder  │
│   문서         │  📁 Documents     --    2026-…    Folder  │  ← 선택한 폴더의 내용
│   다운로드     │  📄 report.pdf   1.2MB  2026-…    PDF     │
│  위치          │  …                                        │
│   ▸ 내 Mac     │                                          │
│   ▾ zjonsu    │                                          │
│     ▸ Desktop │                                          │
│     ▸ Documents                                          │
│   휴지통        │  16개 항목              122 GB 사용 가능   │  ← 상태 표시줄
└──────────────┴──────────────────────────────────────────┘
```

- **왼쪽 사이드바** — macOS Finder처럼 `즐겨찾기`/`위치` 섹션과 고정 링크(AirDrop, 응용 프로그램, 데스크탑,
  문서, 다운로드, 사진, 동영상, 음악, 내 Mac, 홈, 볼륨, 휴지통)를 표시. 폴더 항목은 디스클로저 삼각형으로
  **트리처럼 펼쳐집니다.**
- **오른쪽 상세 보기** — 사이드바/트리에서 선택한 폴더의 파일·폴더를 `이름 / 크기 / 수정일 / 종류` 열로 표시.
- 선택한 폴더는 사이드바에서 자동으로 강조되고, 경로 막대도 동기화됩니다.

## 기능

- 사이드바 트리 탐색 + Finder식 즐겨찾기/위치
- 폴더 더블클릭 진입, 경로 막대 클릭 이동, 뒤로/앞으로/상위 이동(히스토리)
- 파일 작업: **새 폴더, 이름 변경, 복제, 휴지통으로 이동**
- **복사 / 잘라내기 / 붙여넣기** 클립보드 (다른 폴더로 이동·복사)
- **ZIP 압축 / 압축 풀기** (`zip`, `ditto` 사용), 진행 표시
- **macOS 기본 Quick Look** 미리 보기 (Space / F3)
- **숨김 파일** 토글, **목록/아이콘** 보기 전환, 이름·크기·날짜·종류 정렬
- 빠른 **필터/검색**, 상태 표시줄(항목 수·선택·여유 공간)
- Finder에서 보기, 터미널 열기, 기본 앱으로 열기
- 다중 선택(⌘-클릭 / ⇧-클릭)

## 빌드 & 실행

```bash
# 개발 빌드/실행
swift run XFinder

# .app 번들 생성 후 실행 (Dock 아이콘 + 메뉴 막대)
./Scripts/bundle.sh release
open build/XFinder.app
```

요구사항: macOS 14+ (개발은 macOS 26 / Swift 6.3 / Xcode 26 에서 진행), Apple Silicon 또는 Intel.

## 키보드 단축키

전역 키 모니터(`KeyboardMonitor`)로 처리하므로 **목록을 클릭하지 않아도 항상 동작**합니다.
(대화상자·텍스트 입력 중에는 자동으로 비활성화됩니다.)

| 단축키 | 동작 | 단축키 | 동작 |
|---|---|---|---|
| ↑ ↓ / PageUp·Down / Home·End | 커서 이동 | Return | 열기 / 폴더 진입 |
| ⌘↓ | 선택 항목 열기 | ⌘↑ / ⌫ | 상위 폴더 |
| ⌘[ ⌘] / ⌘← ⌘→ | 뒤로 / 앞으로 | Space, F3 | 미리 보기 |
| ⌘C / ⌘X / ⌘V | 복사 / 잘라내기 / 붙여넣기 | ⌘D | 복제 |
| ⌘⌫ | 휴지통으로 | ⇧⌘N | 새 폴더 |
| F2 | 이름 변경 | F4 | 기본 앱으로 열기 |
| ⌘R / F5 | 새로고침 | ⇧⌘. | 숨김 파일 |
| ⇧⌘G | 폴더로 이동 | ⌃M | 목록/아이콘 전환 |

사이드바 클릭, 툴바 버튼, 우클릭 컨텍스트 메뉴, 상단 메뉴 막대로도 모든 기능을 쓸 수 있습니다.

## 즐겨찾기

- 상세 목록 또는 사이드바에서 **폴더를 우클릭 → "즐겨찾기에 추가 / 제거"**.
- 즐겨찾기 목록은 `UserDefaults`에 저장되어 재실행해도 유지됩니다.

## 구조

```
Sources/XFinder/
  App.swift                 @main, 메뉴 커맨드
  Model/
    AppModel.swift          @Observable 루트 상태(사이드바·선택 폴더·히스토리·클립보드·작업)
    SidebarItem.swift       사이드바/트리 노드
    PaneTab.swift           상세 목록 상태(항목·선택·정렬·필터)
    FileItem.swift          파일 항목 값 타입 + 포맷팅
    Enums.swift             정렬키 / 보기 모드
  Services/
    FileSystemService.swift 디렉터리·하위폴더 나열
    FileOperations.swift    복사·이동·압축·해제(비동기 + 진행률)
    SystemActions.swift     열기·Finder에서 보기·아이콘·터미널·AirDrop
  Views/
    RootView.swift          NavigationSplitView + 툴바 + 경로 막대
    SidebarView.swift       섹션 + 트리(재귀)
    DetailView.swift        상세 목록 + 키보드/마우스 처리 + 상태 표시줄
    Sheets.swift            미리보기·새 폴더·이름 변경·폴더로 이동·진행률
Scripts/bundle.sh           .app 번들 생성(ad-hoc 코드서명 포함)
Resources/Info.plist        번들 메타데이터
```

## 참고 / 제한

- App Sandbox를 사용하지 **않습니다**(휴지통·임의 경로·`Process`/`ditto` 접근을 위해).
  실행 사용자 권한으로 동작합니다.
- `문서`·`데스크탑`·`다운로드` 등 보호된 폴더에 처음 접근하면 macOS 개인정보 보호 권한(TCC)
  요청이 한 번 표시됩니다 — 정상 동작입니다.
- `위치` 섹션에는 실제로 마운트된(탐색 가능한) 볼륨만 표시됩니다 — 부트 볼륨의 `/Volumes` 심볼릭
  링크로 인한 중복 "Macintosh HD"는 제거했습니다.
- 사이드바 선택은 항목 단위로 강조됩니다 — `/`를 가리키는 컴퓨터·볼륨 행이 동시에 강조되지 않습니다.
- 사이드바 트리는 디스클로저 삼각형(▸)을 직접 누를 때만 펼쳐집니다 — 폴더 선택 시 자동으로
  펼쳐지지 않습니다.
- Space / F3 미리 보기는 macOS 기본 Quick Look(`qlmanage`)을 사용합니다.
- 창은 **보더리스 커스텀 윈도우**입니다: 투명 윈도우 + SwiftUI 둥근 클리핑으로 모서리 곡률을 줄였고
  (`WindowChrome.cornerRadius`로 조절), 시스템 신호등·리사이즈·드래그는 그대로 사용합니다. 툴바는
  타이틀바 세이프영역을 피해 일반 콘텐츠 행으로 그립니다. (macOS 26은 `CGSSetWindowCornerRadius`를
  제거해 표준 타이틀바 창에서는 곡률을 못 바꾸므로 이 방식이 필요합니다.)
