import Foundation

/// The sentence an import's failure banner shows.
///
/// It lives in the core, not in the banner, because the distinction it encodes
/// is the whole point of `DecodeError.cannotStorePreview`: a photo that failed
/// to decode and a photo that decoded but could not be cached need different
/// actions from the user (retry the file vs. free up disk). Reporting both as
/// "could not be decoded" is the misdiagnosis the error taxonomy exists to
/// prevent.
public enum ImportFailureSummary {
    /// Human-readable, single-line summary. Empty for no failures.
    public static func text(for failures: [DecodeOutcome]) -> String {
        guard !failures.isEmpty else { return "" }
        var unsupported = 0
        var undecoded = 0
        var uncached = 0
        var decodeMessages: Set<String> = []
        for outcome in failures {
            switch outcome.error {
            case .cannotOpen(let message)? where message == Self.unsupportedMessage:
                unsupported += 1
            case .cannotStorePreview:
                uncached += 1
            case nil:
                continue
            default:
                undecoded += 1
                if case let .some(error) = outcome.error { decodeMessages.insert(Self.message(of: error)) }
            }
        }
        var parts: [String] = []
        if unsupported > 0 { parts.append(count(unsupported, "unsupported format")) }
        if undecoded > 0 {
            // One shared reason is worth printing; a mixed set of them is not
            // (the banner is one line).
            let reason = decodeMessages.count == 1 ? decodeMessages.first.map { " (\($0))" } ?? "" : ""
            parts.append(count(undecoded, "could not be decoded") + reason)
        }
        if uncached > 0 { parts.append(count(uncached, "could not be cached (check free disk space)")) }
        guard !parts.isEmpty else { return "" }
        return "\(parts.joined(separator: ", ")): \(names(failures))"
    }

    /// The message `AppState` uses for a file whose extension is not supported,
    /// so the summary can label it as a format problem rather than a decode
    /// failure.
    public static let unsupportedMessage = "Unsupported format"

    private static func count(_ n: Int, _ clause: String) -> String {
        n == 1 ? "1 file \(clause)" : "\(n) files \(clause)"
    }

    private static func names(_ failures: [DecodeOutcome]) -> String {
        let shown = failures.prefix(3).map { $0.file.url.lastPathComponent }
            .joined(separator: ", ")
        return failures.count > 3 ? shown + ", …" : shown
    }

    private static func message(of error: DecodeError) -> String {
        switch error {
        case .cannotOpen(let m), .cannotUnpack(let m), .cannotProcess(let m),
             .cannotStorePreview(let m):
            return m
        case .initFailed: return "decoder could not start"
        case .invalidOutput: return "decoder returned no usable image"
        }
    }
}
