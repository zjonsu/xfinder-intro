import SwiftUI
import AppKit

/// 메모리 상세 팝업 (도넛 + 내역 + 압력/스왑 + 상위 프로세스). macAppCalender 참고.
struct MemoryDetailView: View {
    let monitor: SystemMonitor
    @State private var procs: [MemProc] = []
    @State private var timer: Timer?

    private var m: MemStat { monitor.memory }
    private var used: Double { max(0, m.totalGB - m.freeGB) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("메모리")
                    .font(.system(size: 18, weight: .bold))

                donutSection
                Divider()
                cardsSection
                Divider()
                processSection
            }
            .padding(16)
        }
        .frame(width: 360, height: 540)
        .onAppear { reload(); startTimer() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    // MARK: - 도넛 + 내역

    private var donutSection: some View {
        HStack(spacing: 16) {
            ZStack {
                ForEach(Array(segments().enumerated()), id: \.offset) { _, seg in
                    Circle()
                        .trim(from: seg.from, to: seg.to)
                        .stroke(seg.color, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: min(used / max(m.totalGB, 0.01), 1), to: 1)
                    .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 16))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(String(format: "%.2fGB", used))
                        .font(.system(size: 19, weight: .bold))
                    Text(String(format: "/ %.0fGB", m.totalGB))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, height: 130)

            VStack(alignment: .leading, spacing: 10) {
                legend("활성화", m.active, .blue)
                legend("와이어드", m.wired, .purple)
                legend("압축됨", m.compressed, .indigo)
            }
            Spacer(minLength: 0)
        }
    }

    private func legend(_ name: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(String(format: "%.2fGB", value)).font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func segments() -> [(from: Double, to: Double, color: Color)] {
        let total = max(m.totalGB, 0.01)
        let other = max(0, used - m.active - m.wired - m.compressed)
        var acc = 0.0
        var out: [(Double, Double, Color)] = []
        for (val, color) in [(m.active, Color.blue), (m.wired, Color.purple),
                             (m.compressed, Color.indigo), (other, Color.gray.opacity(0.6))] {
            let from = acc / total
            let to = min((acc + val) / total, 1)
            if to > from { out.append((from, to, color)) }
            acc += val
        }
        return out
    }

    // MARK: - 압력 / 스왑 카드

    private var cardsSection: some View {
        HStack(spacing: 10) {
            infoCard(title: "압력", value: String(format: "%.0f%%", m.pressure),
                     desc: m.pressure < 70 ? "여유로운 상태입니다." : "메모리 사용량이 높습니다.")
            infoCard(title: "스왑 파일", value: String(format: "%.2fGB", m.swapUsed),
                     desc: "메모리 성능을 돕는 디스크 영역입니다.")
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

    // MARK: - 상위 프로세스

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("부하가 가장 큰 프로세스")
                .font(.system(size: 13, weight: .semibold))
            HStack {
                Text("프로세스 이름").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("사용량").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(procs) { p in
                HStack(spacing: 8) {
                    if let icon = appIcon(for: p.id) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 18)
                    }
                    Text(p.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(String(format: "%.2fGB", p.rssGB))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.rssGB >= 2 ? .orange : .primary)
                    Button("종료") { monitor.quit(pid: p.id); reloadSoon() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: - 로드

    private func reload() { procs = monitor.topMemoryProcesses(limit: 6) }
    private func reloadSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { reload() } }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { reload() }
        }
    }

    private func appIcon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}
