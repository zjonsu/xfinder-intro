import SwiftUI
import AppKit

/// AI 파일 정리 시트 — 자연어 명령을 받아 로컬 LLM(Ollama)이 이동 계획을 만들고,
/// 미리보기로 확인한 뒤 적용한다.  입력 → 분석(로딩) → 미리보기 → 적용 흐름.
struct AIOrganizeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case input, loading, preview, empty, error }

    @State private var instruction = ""
    @State private var phase: Phase = .input
    @State private var plan: AIPlan?
    @State private var errorText: String?
    @State private var files: [String] = []
    @State private var showLocalAIGuide = false
    @FocusState private var fieldFocused: Bool

    private let examples = [
        "확장자 종류별로 폴더를 만들어 정리해줘",
        "이미지 파일만 ‘이미지’ 폴더로 모아줘",
        "날짜(연-월)별 폴더로 분류해줘",
        "스크린샷을 ‘스크린샷’ 폴더로 옮겨줘",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch phase {
                case .input:   inputView
                case .loading: loadingView
                case .preview: previewView
                case .empty:   emptyView
                case .error:   errorView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            files = app.currentFolderEntries()
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        // ZStack 기본(중앙) 정렬로 제목을 세로 가운데에 두고, 닫기 버튼만 상단 우측에 오버레이한다.
        ZStack {
            LinearGradient(colors: [Color(red: 0.49, green: 0.31, blue: 0.96),
                                    Color(red: 0.21, green: 0.55, blue: 0.99)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 파일 정리").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    Text("‘\(app.selectedFolder.lastPathComponent)’ · 항목 \(files.count)개 · \(app.aiProvider.label)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 74)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain).focusEffectDisabled().keyboardShortcut(.cancelAction).padding(10)
        }
    }

    // MARK: Input

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("어떻게 정리할까요? 자연어로 알려 주세요.")
                .font(.system(size: 13, weight: .semibold))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                if instruction.isEmpty {
                    Text("예: 확장자별로 폴더를 만들어 정리해줘")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 11)
                }
                TextEditor(text: $instruction)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($fieldFocused)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(height: 96)

            Text("빠른 예시").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            FlowChips(items: examples) { instruction = $0 }

            Spacer(minLength: 0)

            HStack {
                Label(app.aiProvider == .ollama
                        ? "로컬 LLM(Ollama)으로 처리 — 파일이 외부로 나가지 않습니다."
                        : "Gemini(클라우드)로 처리 — 파일 ‘이름’이 구글로 전송됩니다.",
                      systemImage: app.aiProvider == .ollama ? "lock.shield" : "cloud")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("정리 분석") { analyze() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            // 하단: 로컬 AI(Ollama) 설치/설정 안내를 새 팝업으로 여는 링크.
            Button {
                showLocalAIGuide = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle")
                    Text("로컬 AI 설정 방법 — Ollama 설치 안내")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showLocalAIGuide, arrowEdge: .top) {
                LocalAIGuideView()
            }
        }
        .padding(18)
    }

    // MARK: Loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("AI가 파일을 분석하고 있습니다…")
                .font(.system(size: 13, weight: .medium))
            Text("로컬 모델이라 수십 초 걸릴 수 있어요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    // MARK: Preview

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let plan {
                let moves = plan.operations.filter { !$0.isDelete }
                let deletes = plan.operations.filter { $0.isDelete }

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(plan.summary).font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(summaryLine(moves: moves.count,
                                 folders: Set(moves.compactMap(\.destination)).count,
                                 deletes: deletes.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 이동: 대상 폴더별로 묶어 표시
                        ForEach(groupedDestinations(moves), id: \.self) { dest in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(dest, systemImage: "folder.fill")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                                ForEach(moves.filter { ($0.destination ?? "") == dest }) { op in
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9)).foregroundStyle(.secondary)
                                        Text(op.file).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    }
                                    .padding(.leading, 6)
                                }
                            }
                        }

                        // 삭제: 휴지통으로 이동(복구 가능) — 빨간색으로 구분
                        if !deletes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("휴지통으로 이동 (복구 가능)", systemImage: "trash.fill")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
                                ForEach(deletes) { op in
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9)).foregroundStyle(.secondary)
                                        Text(op.file).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    }
                                    .padding(.leading, 6)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                if !deletes.isEmpty {
                    Label("삭제 항목은 영구 삭제가 아니라 휴지통으로 이동되며, 필요하면 복구할 수 있습니다.",
                          systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("다시 입력") { phase = .input }
                Spacer()
                Button("취소") { dismiss() }
                Button("적용") {
                    if let plan { app.applyAIPlan(plan.operations) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }

    /// 미리보기 상단 한 줄 요약 — 이동/삭제 건수를 상황에 맞게 조합한다.
    private func summaryLine(moves: Int, folders: Int, deletes: Int) -> String {
        var parts: [String] = []
        if moves > 0 { parts.append("파일 \(moves)개를 \(folders)개 폴더로 이동") }
        if deletes > 0 { parts.append("\(deletes)개를 휴지통으로 이동") }
        return parts.isEmpty ? "적용할 항목이 없습니다." : parts.joined(separator: " · ") + "합니다."
    }

    // MARK: Empty / Error

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("옮길 파일이 없다고 판단했어요.").font(.system(size: 13, weight: .medium))
            Text(plan?.summary ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("다시 입력") { phase = .input }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
            Text(errorText ?? "오류가 발생했습니다.")
                .font(.system(size: 12)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("다시 시도") { phase = .input }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }

    // MARK: Logic

    private func analyze() {
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty else { return }
        let folderName = app.selectedFolder.lastPathComponent
        let fileList = files
        let config = app.aiConfig
        phase = .loading
        Task {
            do {
                let p = try await AIService.organize(folderName: folderName, files: fileList,
                                                     instruction: instr, config: config)
                await MainActor.run {
                    plan = p
                    phase = p.operations.isEmpty ? .empty : .preview
                }
            } catch {
                await MainActor.run {
                    errorText = (error as? AIError)?.errorDescription ?? error.localizedDescription
                    phase = .error
                }
            }
        }
    }

    private func groupedDestinations(_ ops: [AIOperation]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for o in ops {
            let dest = o.destination ?? ""
            if !dest.isEmpty, !seen.contains(dest) { seen.insert(dest); order.append(dest) }
        }
        return order
    }
}

/// 로컬 AI(Ollama) 설치/설정 안내 팝업. AI 정리 시트 하단 링크에서 새 팝업으로 열린다.
/// 로컬 LLM이 없을 때 무엇을 설치하고 어떻게 켜는지 단계별로 보여 준다.
private struct LocalAIGuideView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// 현재 설정된 로컬 모델 이름(설정에서 바꾸면 안내도 그 모델 기준으로 바뀐다).
    private var model: String {
        let s = app.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? AIService.defaultOllamaModel : s
    }
    /// `ollama pull` 에 쓸 형태 — 태그가 없으면 그대로, 있으면 그대로 사용(둘 다 유효).
    private var pullName: String { model }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 헤더
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("로컬 AI 설정 방법").font(.system(size: 14, weight: .bold))
                    Text("Ollama로 내 Mac에서 직접 정리 — 파일이 외부로 나가지 않습니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "Ollama 설치") {
                        Text("아래 버튼으로 Ollama 공식 사이트에서 macOS용 앱을 받아 설치하세요.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            if let url = URL(string: "https://ollama.com/download") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("ollama.com/download 열기", systemImage: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }

                    step(2, "‘\(model)’ 모델 내려받기") {
                        Text("터미널에서 아래 명령으로 현재 설정된 모델(\(model))을 한 번 받아 두세요. 다른 모델을 쓰려면 설정 → ‘AI 모델’에서 모델 이름을 바꾸면 안내도 그에 맞춰 바뀝니다.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        commandRow("ollama pull \(pullName)")
                    }

                    step(3, "Ollama 실행 확인") {
                        Text("Ollama 앱이 실행 중이면 자동으로 준비됩니다. 수동 실행이 필요하면:")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        commandRow("ollama serve")
                        Text("받은 모델 목록은 아래 명령으로 확인할 수 있어요.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        commandRow("ollama list")
                    }

                    step(4, "xFinder에서 로컬 AI 켜기") {
                        Text("설정(⚙️) → ‘AI 모델’에서 제공자를 ‘로컬 (Ollama)’로 바꾸세요. 서버 주소와 모델 이름도 같은 화면에서 바꿀 수 있습니다. 이후 AI 파일 정리가 내 Mac에서 ‘\(model)’ 모델로 처리됩니다.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 360, height: 440)
    }

    /// 번호가 매겨진 단계 블록.
    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                content()
            }
        }
    }

    /// 복사 버튼이 달린 명령어 행(모노스페이스).
    @ViewBuilder
    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("명령어 복사")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

/// 간단한 가로 줄바꿈 칩 목록(예시 프롬프트). 누르면 onTap으로 값을 전달.
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
