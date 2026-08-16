import Foundation

/// Which decoder pipeline handles a file format.
public enum DecoderKind {
    case libraw
    case imageIO
}

/// Supported image formats: raws via LibRaw, common formats via ImageIO.
public enum RawFileIdentity {
    public static let librawExtensions: Set<String> = [
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

    public static let imageIOExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif",
    ]

    public static let supportedExtensions: Set<String> =
        librawExtensions.union(imageIOExtensions)

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// The decoder pipeline for a file, or nil for unsupported formats.
    public static func decoderKind(for url: URL) -> DecoderKind? {
        let ext = url.pathExtension.lowercased()
        if librawExtensions.contains(ext) { return .libraw }
        if imageIOExtensions.contains(ext) { return .imageIO }
        return nil
    }

    /// Stable, unique identity for a file: the standardized absolute path.
    public static func fileID(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
