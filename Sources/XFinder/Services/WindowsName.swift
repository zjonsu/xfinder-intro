import Foundation

/// 파일/폴더 이름을 윈도우(NTFS/FAT)에서도 그대로 쓸 수 있는 형태로 바꾼다.
/// macOS(APFS)에서는 `:`·`?`·`*`·`|`·`<`·`>`·`"` 같은 문자가 허용되지만 윈도우에서는 금지된다.
/// 파일 복사·폴더 생성·이름 변경 시 이 변환을 거쳐 양쪽에서 깨지지 않는 이름으로 저장한다.
enum WindowsName {
    /// 윈도우에서 파일명에 쓸 수 없는 문자들.
    private static let forbidden: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]

    /// 윈도우 예약 장치 이름(확장자가 붙어도 예약됨). 대소문자 무시.
    private static let reserved: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 1...9 { s.insert("COM\(i)"); s.insert("LPT\(i)") }
        return s
    }()

    /// 경로의 한 구성요소(파일명 또는 폴더명)를 윈도우 호환 이름으로 변환한다.
    /// - 금지 문자는 `_` 로 치환, 제어문자는 제거
    /// - 끝의 공백/마침표 제거(윈도우에서 금지)
    /// - 예약 장치 이름(CON, NUL, COM1 …)은 앞에 `_` 를 붙여 회피
    static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 { continue }                 // 제어문자 제거
            let ch = Character(scalar)
            out.append(forbidden.contains(ch) ? "_" : ch)
        }
        // 끝의 공백·마침표 제거(윈도우는 이런 이름을 허용하지 않음).
        while let last = out.last, last == " " || last == "." { out.removeLast() }
        // 예약 장치 이름 회피 — 첫 마침표 앞부분으로 판정("CON", "NUL.txt" 등).
        let stem = out.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? out
        if reserved.contains(stem.uppercased()) { out = "_" + out }
        // 변환 결과가 비면 안전한 대체 이름 사용.
        if out.isEmpty { out = "_" }
        // 한글 자소 분리(NFD) 방지 — 항상 완성형(NFC)으로 정규화한다. macOS가 파일명을 자소 분리
        // 형태로 돌려줘도 여기서 합쳐 저장하므로 복사·생성 시 "ㄱ ㅏ" 식으로 깨지지 않는다.
        return out.precomposedStringWithCanonicalMapping
    }

    /// 변환이 실제로 필요한지(원본과 달라지는지) 여부.
    static func needsSanitizing(_ name: String) -> Bool {
        sanitize(name) != name
    }
}
