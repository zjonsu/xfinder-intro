import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds and repairs file names whose Hangul has been stored in *decomposed* form
/// (Unicode NFD — conjoining jamo like `ㅎㅏㄴ`), which renders as "broken" 자소 on
/// many systems/terminals. The fix recomposes them to NFC (`한`).
///
/// Two macOS gotchas this works around:
///  1. Swift `String ==` compares by **canonical equivalence**, so an NFD string and
///     its NFC form test as *equal*. Detection therefore compares raw Unicode scalars.
///  2. `FileManager`/`URL` re-decompose an NFC name back to NFD via
///     `fileSystemRepresentation`, so the rename uses the POSIX `rename(2)` syscall
///     with the composed UTF-8 bytes passed through unchanged.
enum HangulNormalize {

    /// True when `name`'s Hangul is decomposed (its scalars differ from the NFC form
    /// *and* it contains conjoining Hangul jamo), i.e. it should be recomposed.
    static func isDecomposed(_ name: String) -> Bool {
        let nfc = name.precomposedStringWithCanonicalMapping
        // Compare scalars, not `==` (which is canonical-equivalence and hides NFD↔NFC).
        guard Array(name.unicodeScalars) != Array(nfc.unicodeScalars) else { return false }
        return name.unicodeScalars.contains { s in
            (0x1100...0x11FF).contains(s.value)   // Hangul Jamo (conjoining)
                || (0xA960...0xA97F).contains(s.value)   // Hangul Jamo Extended-A
                || (0xD7B0...0xD7FF).contains(s.value)   // Hangul Jamo Extended-B
        }
    }

    /// The recomposed (NFC) form of a name.
    static func recomposed(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Scans `directory` for entries with decomposed-Hangul names.
    /// - Parameter recursive: when true, descends into sub-folders (skipping package bundles).
    static func scan(directory: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        if recursive {
            guard let en = fm.enumerator(at: directory,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsPackageDescendants]) else { return [] }
            for case let url as URL in en where isDecomposed(url.lastPathComponent) {
                results.append(url)
            }
        } else {
            let items = (try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil)) ?? []
            for url in items where isDecomposed(url.lastPathComponent) {
                results.append(url)
            }
        }
        return results
    }

    /// Renames `src` → `dst` via POSIX `rename(2)`, passing the destination's UTF-8
    /// bytes through unchanged so the composed (NFC) name is what gets stored.
    /// Returns `nil` on success, or a human-readable error string on failure.
    static func rename(at src: String, to dst: String) -> String? {
        let ok = src.withCString { s in
            dst.withCString { d in
                Darwin.rename(s, d) == 0
            }
        }
        return ok ? nil : String(cString: strerror(errno))
    }
}
