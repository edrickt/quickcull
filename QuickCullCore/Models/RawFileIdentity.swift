import Foundation

/// Supported raw extensions for v1, per the design spec.
public enum RawFileIdentity {
    public static let supportedExtensions: Set<String> = [
        "cr2", "cr3",      // Canon
        "nef", "nrw",      // Nikon
        "arw", "srf", "sr2", // Sony
        "raf",             // Fujifilm
        "orf",             // Olympus / OM System
        "rw2",             // Panasonic
        "dng",             // Leica, Ricoh, Pentax, generic
        "pef",             // Pentax
        "3fr", "fff",      // Hasselblad
        "iiq",             // Phase One
        "x3f",             // Sigma
        "srw",             // Samsung
        "dcr", "kdc",      // Kodak
        "erf",             // Epson
    ]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Stable, unique identity for a file: the standardized absolute path.
    public static func fileID(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
