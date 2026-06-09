import SwiftUI
import AppKit

/// CPU 상세 팝업 (칩 이름 + 사용률 추이 그래프 + 사용 가능/사용자/시스템 + 가동시간/온도 + 상위 프로세스).
/// macAppCalender 참고. 스타일/크기는 메모리 상세 팝업과 동일.
struct CPUDetailView: View {
    let monitor: SystemMonitor
    @State private var procs: [CPUProc] = []
    @State private var timer: Timer?

    private var c: CPUStat { monitor.cpu }

    private let userColor = Color.blue
    private let systemColor = Color.red
    private let idleColor = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(monitor.cpuName)
                .font(.system(size: 18, weight: .bold))

            graphSection
            Divider()
            cardsSection
            Divider()
            processSection
        }
        .padding(16)
        .frame(width: 360, alignment: .top)   // 높이는 내용에 맞춰 자동 — 스크롤 없음
        .onAppear { reload(); startTimer() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    // MARK: - 그래프 + 사용률 수치

    private var graphSection: some View {
        VStack(spacing: 14) {
            CPUChart(history: monitor.cpuHistory, userColor: userColor, systemColor: systemColor)
                .frame(height: 120)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                readout(color: idleColor, value: c.idle, label: "사용 가능")
                readout(color: userColor, value: c.user, label: "사용자")
                readout(color: systemColor, value: c.system, label: "시스템")
            }
        }
    }

    private func readout(color: Color, value: Double, label: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%.1f%%", value))
                    .font(.system(size: 17, weight: .bold))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 가동시간 / 온도 카드

    private var cardsSection: some View {
        HStack(spacing: 10) {
            infoCard(title: "가동시간", value: uptimeText, desc: uptimeDesc)
            if let t = monitor.cpuTemperature {
                infoCard(title: "온도", value: String(format: "%.0f°C", t), desc: tempDesc(t))
            } else {
                infoCard(title: "발열 상태", value: thermalText, desc: thermalDesc)
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
            if procs.isEmpty {
                Text("측정 중…").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(procs) { p in
                HStack(spacing: 8) {
                    if let icon = appIcon(for: p.id) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 18)
                    }
                    Text(displayName(p)).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", p.cpuPercent))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.cpuPercent >= 50 ? .orange : .primary)
                    Button("종료") { monitor.quit(pid: p.id); reloadSoon() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: - 텍스트 헬퍼

    private var uptimeText: String {
        let s = Int(monitor.uptime)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)일" }
        if h > 0 { return "\(h)시간" }
        return "\(m)분"
    }

    private var uptimeDesc: String {
        let d = Int(monitor.uptime) / 86400
        if d == 0 { return "시스템을 아주 최근에 시작했습니다." }
        if d < 7 { return "재시작 없이 잘 작동하고 있습니다." }
        return "한동안 재시작하지 않았습니다."
    }

    private func tempDesc(_ t: Double) -> String {
        switch t {
        case ..<70:  return "정상 작동 범위 내에 있습니다."
        case ..<90:  return "온도가 다소 높습니다."
        default:     return "온도가 매우 높습니다."
        }
    }

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "정상"
        case .fair:     return "보통"
        case .serious:  return "높음"
        case .critical: return "심각"
        @unknown default: return "—"
        }
    }

    private var thermalDesc: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "발열이 정상 범위 내에 있습니다."
        case .fair:     return "발열이 약간 있는 정상 상태입니다."
        case .serious:  return "발열이 높습니다. 부하를 줄여 보세요."
        case .critical: return "발열이 매우 심각합니다."
        @unknown default: return "발열 상태를 확인할 수 없습니다."
        }
    }

    // MARK: - 로드

    private func reload() { procs = monitor.topCPUProcesses(limit: 5) }
    private func reloadSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { reload() } }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { reload() }
        }
    }

    private func appIcon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// 앱으로 식별되면 앱 이름, 아니면 프로세스 실행 파일명.
    private func displayName(_ p: CPUProc) -> String {
        if let name = NSRunningApplication(processIdentifier: p.id)?.localizedName, !name.isEmpty {
            return name
        }
        return p.name
    }
}

// MARK: - CPU 추이 라인 차트

private struct CPUChart: View {
    let history: [CPUStat]
    var userColor: Color
    var systemColor: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                grid(w: w, h: h)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                line(values: history.map { $0.user }, w: w, h: h)
                    .stroke(userColor, lineWidth: 1.5)
                line(values: history.map { $0.system }, w: w, h: h)
                    .stroke(systemColor, lineWidth: 1.5)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func grid(w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        let cols = 8, rows = 4
        for i in 0...cols {
            let x = w * CGFloat(i) / CGFloat(cols)
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
        }
        for j in 0...rows {
            let y = h * CGFloat(j) / CGFloat(rows)
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
        }
        return p
    }

    private func line(values: [Double], w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let maxX = CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let x = w * CGFloat(i) / maxX
            let y = h * (1 - CGFloat(min(100, max(0, v)) / 100))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}
