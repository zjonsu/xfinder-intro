import SwiftUI
import AppKit

/// 디스크(부팅 볼륨) 상세 팝업 — 도넛(카테고리별 용량) + 건강/온도 카드 + 파일 계산(선택 폴더 기준).
/// 무거운 폴더 스캔 결과는 SystemMonitor 에 캐시되어, 팝업을 다시 열어도 바로 보여준다.
/// "다시 계산" 버튼을 눌렀을 때만 재스캔한다.
struct DiskDetailView: View {
    let monitor: SystemMonitor

    private static let palette: [Color] = [.red, .pink, .blue, .teal, .gray]

    /// 종류별 메타(아이콘/색) — FileSystemService.fileTypeOrder 와 같은 순서.
    private static let typeMeta: [(icon: String, color: Color)] = [
        ("doc.text", .blue),      // 문서
        ("photo", .green),        // 이미지
        ("film", .pink),          // 동영상
        ("music.note", .purple),  // 음악
        ("archivebox", .orange),  // 압축
        ("ellipsis.circle", .gray) // 기타
    ]

    @State private var typeStats: [TypeStat]?

    private struct TypeStat: Identifiable { let id: Int; let name: String; let bytes: Int64; let count: Int }

    /// 종류별 계산 대상은 항상 사용자 홈 폴더.
    private var homeFolder: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var totalBytes: Int64 { monitor.diskTotalBytes }
    private var freeBytes: Int64 { monitor.diskFreeBytes }
    private var cats: [DiskCategory] { monitor.diskCategories }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            donutSection
            Divider()
            cardsSection
            Divider()
            fileCalcSection
        }
        .padding(16)
        .frame(width: 380, alignment: .top)   // 높이는 내용에 맞춰 자동 — 세로 스크롤 없음
        .task { await monitor.refreshDisk(force: false) }   // uses cache if already computed
        .task { await computeFileCalc() }
    }

    // MARK: - 제목 + 다시 계산

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(monitor.diskVolumeName).font(.system(size: 18, weight: .bold))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Button {
                    Task { await monitor.refreshDisk(force: true) }
                    Task { await computeFileCalc() }
                } label: {
                    Label(monitor.diskComputing ? "계산 중…" : "다시 계산",
                          systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()          // 파란 포커스 테두리 제거
                .foregroundStyle(.blue)
                .disabled(monitor.diskComputing)
                if let at = monitor.diskComputedAt, !monitor.diskComputing {
                    Text("계산: \(timeText(at))").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 도넛 + 카테고리 범례

    private var donutSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 16)
                ForEach(Array(segments().enumerated()), id: \.offset) { _, seg in
                    Circle()
                        .trim(from: seg.from, to: seg.to)
                        .stroke(seg.color, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 1) {
                    Text(human(freeBytes)).font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.orange)
                    Text("/ \(human(totalBytes))").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("사용 가능").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)

            VStack(alignment: .leading, spacing: 9) {
                if cats.isEmpty {
                    Text(monitor.diskComputing ? "계산 중…" : "—")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(cats) { legend($0.name, $0.bytes, color(for: $0.id)) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func legend(_ name: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(human(bytes)).font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func color(for id: Int) -> Color { Self.palette[min(id, Self.palette.count - 1)] }

    private func segments() -> [(from: Double, to: Double, color: Color)] {
        let total = Double(max(totalBytes, 1))
        var acc = 0.0
        var out: [(Double, Double, Color)] = []
        for c in cats {
            let from = acc / total
            let to = min((acc + Double(c.bytes)) / total, 1)
            if to > from { out.append((from, to, color(for: c.id))) }
            acc += Double(c.bytes)
        }
        return out
    }

    // MARK: - 건강 / 온도 카드

    private var cardsSection: some View {
        HStack(spacing: 10) {
            infoCard(title: "건강 상태",
                     value: monitor.diskHealthValue ?? (monitor.diskComputing ? "확인 중…" : "—"),
                     desc: monitor.diskHealthDesc ?? "드라이브 상태를 확인하고 있습니다.")
            if let t = monitor.diskTemperature {
                infoCard(title: "온도", value: String(format: "%.0f°C", t), desc: tempDesc(t))
            } else {
                infoCard(title: "온도", value: "—", desc: "이 Mac에서는 드라이브 온도를 읽을 수 없습니다.")
            }
        }
    }

    private func infoCard(title: String, value: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 14, weight: .bold))
            }
            Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func tempDesc(_ t: Double) -> String {
        switch t {
        case ..<50:  return "드라이브 온도가 정상 작동 범위 내에 있습니다."
        case ..<70:  return "드라이브 온도가 다소 높습니다."
        default:     return "드라이브 온도가 높습니다."
        }
    }

    // MARK: - 파일 계산 (홈 폴더의 종류별 용량)

    private var fileCalcSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("파일 계산").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(homeFolder.path).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            VStack(spacing: 0) {
                if let stats = typeStats {
                    ForEach(stats) { row in
                        typeRow(row)
                        if row.id != stats.count - 1 { Divider() }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("종류별로 계산 중…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        }
    }

    private func typeRow(_ row: TypeStat) -> some View {
        let meta = Self.typeMeta[min(row.id, Self.typeMeta.count - 1)]
        return HStack(spacing: 10) {
            Image(systemName: meta.icon).font(.system(size: 14)).foregroundStyle(meta.color).frame(width: 20)
            Text(row.name).font(.system(size: 13, weight: .medium))
            Spacer()
            Text("\(row.count.formatted())개").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(human(row.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private func computeFileCalc() async {
        typeStats = nil
        let folder = homeFolder
        let result = await Task.detached(priority: .userInitiated) {
            FileSystemService.sizeByFileType(folder)
        }.value
        typeStats = result.enumerated().map { TypeStat(id: $0.offset, name: $0.element.name,
                                                       bytes: $0.element.bytes, count: $0.element.count) }
    }

    // MARK: - 포맷

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func human(_ bytes: Int64) -> String {
        let b = Double(bytes)
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024, tb = gb * 1024
        if b >= tb { return String(format: "%.2fTB", b / tb) }
        if b >= gb { return String(format: "%.2fGB", b / gb) }
        if b >= mb { return String(format: "%.1fMB", b / mb) }
        if b >= kb { return String(format: "%.0fKB", b / kb) }
        return "\(Int(b))B"
    }
}
