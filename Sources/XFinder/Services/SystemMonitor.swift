import Foundation
import Darwin
import Observation

// MARK: - Sample value types (shared with the CPU / memory detail popups)

struct CPUStat { var total = 0.0; var system = 0.0; var user = 0.0; var idle = 100.0 }

struct MemStat {
    var usedPercent = 0.0
    var app = 0.0, active = 0.0, wired = 0.0, compressed = 0.0, freeGB = 0.0, totalGB = 0.0
    var swapUsed = 0.0, swapTotal = 0.0
    /// 메모리 압력(근사): (와이어드+압축됨)/전체
    var pressure: Double { totalGB > 0 ? (wired + compressed) / totalGB * 100 : 0 }
}

struct MemProc: Identifiable { let id: pid_t; let name: String; let rssGB: Double }
struct CPUProc: Identifiable { let id: pid_t; let name: String; let cpuPercent: Double }
struct DiskCategory: Identifiable, Sendable { let id: Int; let name: String; let bytes: Int64 }

/// Live CPU / memory / disk usage, sampled on a timer. Drives the compact stats readout in the
/// toolbar plus the detailed CPU / memory popups. (Ported from the macAppCalender reference.)
@Observable
final class SystemMonitor {
    /// Shared instance so views created outside the SwiftUI environment observe the same samples.
    static let shared = SystemMonitor()

    // Rich samples (detail popups).
    var cpu = CPUStat()
    var memory = MemStat()
    /// CPU 사용률 추이(그래프용, 최근 N개). 오래된 것이 앞.
    var cpuHistory: [CPUStat] = []
    /// CPU 온도(℃). 못 읽으면 nil.
    var cpuTemperature: Double?

    // Compact convenience values (toolbar) — 0...1 fractions + formatted disk text.
    var cpuUsage: Double = 0
    var memoryUsage: Double = 0
    var diskUsage: Double = 0
    var diskUsedText: String = "--"
    var diskTotalText: String = "--"

    // Disk breakdown cache — computed lazily (folder scans are slow) and reused across popup opens.
    // The detail popup shows these immediately; a "다시 계산" button forces a recompute.
    var diskVolumeName = "디스크"
    var diskTotalBytes: Int64 = 0
    var diskFreeBytes: Int64 = 0
    var diskCategories: [DiskCategory] = []
    var diskTrashBytes: Int64?
    var diskTemperature: Double?
    var diskHealthValue: String?
    var diskHealthDesc: String?
    var diskComputedAt: Date?
    var diskComputing = false

    var diskUsedBytes: Int64 { max(0, diskTotalBytes - diskFreeBytes) }

    @ObservationIgnored private let historyLimit = 60
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var prevCPU: host_cpu_load_info?
    @ObservationIgnored private var prevProcCPU: [pid_t: UInt64] = [:]
    @ObservationIgnored private var prevProcSampleTime: Date?

    /// 칩/프로세서 이름 (예: "Apple M4 Pro").
    @ObservationIgnored let cpuName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "프로세서" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let name = String(cString: buf)
        return name.isEmpty ? "프로세서" : name
    }()

    /// 시스템 가동 시간(초).
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        // CPU·메모리는 가벼운 커널 호출이라 메인에서 바로 읽는다(prevCPU 연속성도 유지).
        cpu = readCPU()
        memory = readMemory()
        cpuUsage = max(0, min(1, cpu.total / 100))
        memoryUsage = max(0, min(1, memory.usedPercent / 100))
        cpuHistory.append(cpu)
        if cpuHistory.count > historyLimit {
            cpuHistory.removeFirst(cpuHistory.count - historyLimit)
        }

        // 디스크 여유공간(volumeAvailableCapacityForImportantUsage → 느린 CacheDelete 계산)과 SMC
        // 온도 읽기는 느리고 변동이 커서, 메인 스레드에서 2초마다 돌리면 클릭이 그 틱과 겹칠 때 간헐적
        // 끊김이 생긴다. 백그라운드에서 읽고 결과만 메인으로 반영한다.
        Task { @MainActor [weak self] in
            let disk = await Task.detached(priority: .utility) { SystemMonitor.diskUsageSnapshot() }.value
            let temp = await Task.detached(priority: .utility) { SMC.shared.cpuTemperature() }.value
            guard let self else { return }
            if let disk {
                self.diskUsage = disk.usage
                self.diskUsedText = disk.used
                self.diskTotalText = disk.total
            }
            // SMC 읽기는 간헐적으로 실패하므로 정상값을 얻었을 때만 갱신해 깜빡임을 막는다.
            if let temp { self.cpuTemperature = temp }
        }
    }

    // MARK: - CPU

    private func readCPU() -> CPUStat {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return cpu }
        defer { prevCPU = info }
        guard let prev = prevCPU else { return CPUStat() }

        let dUser = Double(info.cpu_ticks.0) - Double(prev.cpu_ticks.0)
        let dSys  = Double(info.cpu_ticks.1) - Double(prev.cpu_ticks.1)
        let dIdle = Double(info.cpu_ticks.2) - Double(prev.cpu_ticks.2)
        let dNice = Double(info.cpu_ticks.3) - Double(prev.cpu_ticks.3)
        let total = dUser + dSys + dIdle + dNice
        guard total > 0 else { return cpu }
        let user = (dUser + dNice) / total * 100
        let sys = dSys / total * 100
        let idle = dIdle / total * 100
        return CPUStat(total: user + sys, system: sys, user: user, idle: idle)
    }

    // MARK: - Memory

    private func readMemory() -> MemStat {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return memory }
        let ps = Double(vm_kernel_page_size)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let free = Double(stats.free_count) * ps
        let active = Double(stats.active_count) * ps
        let wired = Double(stats.wire_count) * ps
        let compressed = Double(stats.compressor_page_count) * ps
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * ps
        let used = total - free
        let giB = 1024.0 * 1024 * 1024

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsed = 0.0, swapTotal = 0.0
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = Double(swap.xsu_used) / giB
            swapTotal = Double(swap.xsu_total) / giB
        }

        return MemStat(usedPercent: used / total * 100,
                       app: app / giB, active: active / giB, wired: wired / giB, compressed: compressed / giB,
                       freeGB: free / giB, totalGB: total / giB,
                       swapUsed: swapUsed, swapTotal: swapTotal)
    }

    // MARK: - Disk

    /// 메인 스레드를 막지 않도록 백그라운드에서 호출하는 디스크 사용량 스냅샷.
    private static func diskUsageSnapshot() -> (usage: Double, used: String, total: String)? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        let available = v.volumeAvailableCapacityForImportantUsage ?? 0
        let used = Int64(total) - available
        return (max(0, min(1, Double(used) / Double(total))),
                ByteCountFormatter.string(fromByteCount: used, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))
    }

    // MARK: - Disk breakdown (cached; recomputed only on demand)

    /// Refresh the disk popup data. Capacity & temperature are cheap and always refreshed; the slow
    /// folder scans (categories, trash, SMART) run only when there's no cache yet or `force` is set.
    @MainActor
    func refreshDisk(force: Bool = false) async {
        readDiskCapacity()
        diskTemperature = SMC.shared.driveTemperature()
        if diskComputing { return }
        if !force && diskComputedAt != nil { return }   // already have a cached result — reuse it
        diskComputing = true
        let used = diskUsedBytes
        let cats = await Self.scanCategories(usedBytes: used)
        let health = await Self.scanHealth()
        diskCategories = cats
        diskHealthValue = health.value
        diskHealthDesc = health.desc
        diskComputedAt = Date()
        diskComputing = false
    }

    @MainActor
    func emptyTrash() async {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let items = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        for url in items { try? FileManager.default.removeItem(at: url) }
        diskTrashBytes = await Self.scanTrash()
    }

    private func readDiskCapacity() {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                     .volumeAvailableCapacityForImportantUsageKey]) {
            diskVolumeName = v.volumeName ?? "Macintosh HD"
            diskTotalBytes = Int64(v.volumeTotalCapacity ?? 0)
            diskFreeBytes = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    private static func scanCategories(usedBytes: Int64) async -> [DiskCategory] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defs: [(String, URL)] = [
            ("응용 프로그램", URL(fileURLWithPath: "/Applications")),
            ("다운로드", home.appendingPathComponent("Downloads")),
            ("문서", home.appendingPathComponent("Documents")),
            ("데스크탑", home.appendingPathComponent("Desktop")),
        ]
        var sizes = [Int: Int64](minimumCapacity: defs.count)
        await withTaskGroup(of: (Int, Int64).self) { group in
            for (i, d) in defs.enumerated() {
                let url = d.1
                group.addTask { (i, FileSystemService.folderSize(url)) }
            }
            for await (i, s) in group { sizes[i] = s }
        }
        var result = defs.enumerated().map { DiskCategory(id: $0.offset, name: $0.element.0, bytes: sizes[$0.offset] ?? 0) }
        let other = max(0, usedBytes - result.reduce(0) { $0 + $1.bytes })
        result.append(DiskCategory(id: defs.count, name: "기타", bytes: other))
        return result
    }

    private static func scanTrash() async -> Int64 {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return await Task.detached { FileSystemService.folderSize(trash) }.value
    }

    private static func scanHealth() async -> (value: String, desc: String) {
        let status = await Task.detached { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            p.arguments = ["info", "-plist", "/"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let dict = plist as? [String: Any]
            return (dict?["SMARTDeviceStatus"] as? String) ?? (dict?["SMARTStatus"] as? String)
        }.value

        switch status {
        case "Verified":
            return ("정상", "드라이브 상태가 정상(Verified)으로 확인되었습니다.")
        case "Failing":
            return ("주의", "드라이브에 문제가 감지되었습니다. 백업을 권장합니다.")
        case .some(let s) where !s.isEmpty:
            return (s, "드라이브 S.M.A.R.T. 상태입니다.")
        default:
            return ("지원 안 함", "이 드라이브는 S.M.A.R.T. 상태를 제공하지 않습니다.")
        }
    }

    // MARK: - Top processes / quit

    func topMemoryProcesses(limit: Int = 6) -> [MemProc] {
        let maxPids = 8192
        var pids = [pid_t](repeating: 0, count: maxPids)
        let bytes = proc_listallpids(&pids, Int32(maxPids * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        let giB = 1024.0 * 1024 * 1024
        var result: [MemProc] = []
        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            var info = proc_taskinfo()
            let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
            guard r == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            let rss = Double(info.pti_resident_size)
            guard rss > 1_000_000 else { continue }
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, 256)
            let name = String(cString: nameBuf)
            result.append(MemProc(id: pid, name: name.isEmpty ? "PID \(pid)" : name, rssGB: rss / giB))
        }
        return Array(result.sorted { $0.rssGB > $1.rssGB }.prefix(limit))
    }

    /// CPU 사용률이 높은 프로세스. 이전 호출과의 CPU 시간 차이로 % 를 계산하므로 주기적으로 호출해야 한다.
    func topCPUProcesses(limit: Int = 5) -> [CPUProc] {
        let maxPids = 8192
        var pids = [pid_t](repeating: 0, count: maxPids)
        let bytes = proc_listallpids(&pids, Int32(maxPids * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        let now = Date()
        let dt = prevProcSampleTime.map { now.timeIntervalSince($0) } ?? 0
        var current: [pid_t: UInt64] = [:]
        var result: [CPUProc] = []

        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            guard let nanos = cpuTimeNanos(pid: pid) else { continue }
            current[pid] = nanos
            guard dt > 0, let prev = prevProcCPU[pid], nanos >= prev else { continue }
            let percent = Double(nanos - prev) / 1_000_000_000.0 / dt * 100.0
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, 256)
            let name = String(cString: nameBuf)
            result.append(CPUProc(id: pid, name: name.isEmpty ? "PID \(pid)" : name, cpuPercent: percent))
        }

        prevProcCPU = current
        prevProcSampleTime = now
        return Array(result.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    private func cpuTimeNanos(pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard r == 0 else { return nil }
        return usage.ri_user_time + usage.ri_system_time
    }

    func quit(pid: pid_t) { kill(pid, SIGTERM) }
}
