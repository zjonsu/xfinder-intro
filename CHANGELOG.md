# 변경 내역 (Changelog)

## 2026-06-08 — DayFinder → **XFinder** 리브랜딩

- 앱 이름을 **DayFinder → XFinder**로 변경 (번들 ID `com.zjonsu.dayfinder` → `com.zjonsu.xfinder`,
  소스 디렉터리 `Sources/DayFinder` → `Sources/XFinder`, SwiftPM 타깃·실행 파일·About/설명서 표기 포함).
- **앱 아이콘 교체** — macOS Finder 스타일의 둥근 사각형 + 반밝음/반진함 파란 얼굴에
  XFinder를 상징하는 **X 모티프**를 더한 새 아이콘 (`Resources/AppIcon.icns`).
- **폰트 변경** — 앱 전체 UI를 둥근(SF Rounded) 시스템 폰트로 통일 (`.fontDesign(.rounded)`).

## 2026-06-08

### 오른쪽 패널 빈 영역 우클릭 메뉴 추가

오른쪽 콘텐츠 패널에서 파일/폴더가 아닌 **빈 영역을 우클릭**하면
macOS 기본 Finder의 배경 메뉴와 유사한 컨텍스트 메뉴가 나타나도록 했습니다.

**메뉴 구성**

| 항목 | 동작 |
|------|------|
| 새 폴더 | 현재 폴더에 새 폴더 생성 (`app.requestNewFolder()`) |
| 붙여넣기 | 클립보드에 항목이 있을 때만 표시 (`app.paste()`) |
| 보기 ▸ | 목록 / 아이콘 보기 전환 (현재 모드에 체크 표시) |
| 정렬 기준 ▸ | 이름·크기·종류·수정일·생성일 선택(현재 키 체크) + 오름/내림차순 전환 |
| 숨김 항목 보기 | 숨김 파일 표시 토글 |
| 새로 고침 | 현재 목록 다시 로드 (`app.reloadDetail()`) |

**동작 규칙**

- 행(파일/폴더)에는 기존 컨텍스트 메뉴가 우선 적용되고, 빈 공간에서만 이 배경 메뉴가 뜬다.
- 검색 / 최근 항목 / 태그 모드처럼 실제 폴더가 아닐 때는
  "새 폴더 · 붙여넣기"는 숨기고 보기 / 정렬 옵션만 노출한다.

**구현 위치**

- `Sources/XFinder/Views/DetailView.swift`
  - ScrollView 빈 영역에 `.contextMenu { backgroundMenu() }` 부착
  - `backgroundMenu()`, `viewModeMenu()`, `sortByMenu()`,
    `setSort(_:)`, `setViewMode(_:)`, `sortLabel(_:)` 헬퍼 추가

**참고**

- 이미지로 제공된 macOS "보기 옵션" 패널의 일부 항목(텍스트 크기, 계층 보기 컬럼 토글,
  다음으로 그룹화, 아이콘 미리보기 등)은 현재 앱 모델에 대응 상태가 없어 메뉴에 포함하지 않음.
  필요 시 모델에 상태를 추가해 확장 가능.
