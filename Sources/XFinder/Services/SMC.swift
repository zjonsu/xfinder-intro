import Foundation
import IOKit

/// AppleSMC 에서 센서 값을 읽는 최소 구현.
/// CPU 온도(℃)를 읽기 위해 사용한다. (Intel / Apple Silicon 모두 시도)
///
/// 구조체 레이아웃은 널리 검증된 SMCKit(beltex) 정의를 따른다.
final class SMC {
    static let shared = SMC()

    private var connection: io_connect_t = 0
    private let isOpen: Bool

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { isOpen = false; return }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        isOpen = (IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess)
        connection = conn
    }

    deinit { if isOpen { IOServiceClose(connection) } }

    // MARK: - 공개 API

    /// CPU 온도(℃). 칩별로 키가 달라 후보 키들을 평균낸다. 못 읽으면 nil.
    func cpuTemperature() -> Double? {
        guard isOpen else { return nil }
        // Apple Silicon 성능/효율 코어 센서 + Intel 패키지 센서 후보.
        let keys = ["TC0P", "TC0D", "TC0E", "TC0F",
                    "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
                    "Tp0b", "Tp0f", "Tp0j", "Tp0n"]
        var sum = 0.0
        var n = 0
        for k in keys {
            // 동작 중인 CPU 의 현실적 범위만 채택(잘못된 센서/단위 값 배제).
            if let v = readTemperature(key: k), v >= 20, v <= 110 {
                sum += v; n += 1
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// 내장 SSD/드라이브 온도(℃) 추정. 칩마다 키가 달라 후보들을 평균낸다. 못 읽으면 nil.
    func driveTemperature() -> Double? {
        guard isOpen else { return nil }
        let keys = ["TaLP", "TaRP", "TH0a", "TH0b", "TH0c", "TH0x",
                    "TH1a", "TH1b", "TH1c", "TH1x", "Ts0P", "Ts1P"]
        var sum = 0.0
        var n = 0
        for k in keys {
            if let v = readTemperature(key: k), v >= 10, v <= 100 { sum += v; n += 1 }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    // MARK: - 내부

    private func readTemperature(key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // kSMCReadKey
        guard call(&input, &output) else { return nil }

        let type = fourCCString(info.dataType)
        let b = output.bytes
        switch type {
        case "flt ":
            // 4바이트 리틀엔디언 Float
            let bits = UInt32(b.0) | (UInt32(b.1) << 8) | (UInt32(b.2) << 16) | (UInt32(b.3) << 24)
            return Double(Float(bitPattern: bits))
        case "sp78":
            // 부호있는 8.8 고정소수점 (빅엔디언)
            let raw = (Int(b.0) << 8) | Int(b.1)
            let signed = raw > 32767 ? raw - 65536 : raw
            return Double(signed) / 256.0
        case "ioft":
            // 8바이트 고정소수점 (1<<16 스케일)
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64([b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7][i]) << (8 * UInt64(i)) }
            return Double(v) / 65536.0
        default:
            return nil
        }
    }

    private func keyInfo(_ key: String) -> SMCKeyInfoData? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = 9 // kSMCGetKeyInfo
        guard call(&input, &output) else { return nil }
        return output.keyInfo
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> Bool {
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, 2 /* kSMCHandleYPCEvent */,
                                           &input, inputSize, &output, &outputSize)
        return kr == kIOReturnSuccess && output.result == 0
    }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for ch in s.utf8.prefix(4) { r = (r << 8) | UInt32(ch) }
        return r
    }

    private func fourCCString(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                     UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - SMC 구조체 (C 레이아웃 미러)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
