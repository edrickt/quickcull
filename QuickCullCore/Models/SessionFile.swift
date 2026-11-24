import Foundation

/// One raw file in a culling session.
public struct SessionFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let id: String
    /// `"<size>|<mtime-us>"` captured when the file entered the session.
    ///
    /// The preview cache key embeds the source's size and mtime, and every
    /// read recomputes it. Once the source leaves the volume — card ejected,
    /// file moved or deleted — a live `stat` fails; without this snapshot the
    /// key fell back to the path alone and could never name the preview that
    /// was written while the file existed (QC-01). Nil when the file cannot be
    /// stat-ed yet (a fixture path that does not exist on disk).
    public let statSignature: String?

    /// The same file with symlinks resolved: what the identity and the cache
    /// key already name, and the only path a destructive operation may touch.
    /// `url` is the spelling the user picked and is for display only, so a
    /// photo imported through a symlink must be trashed/moved at the target,
    /// not at the link (QS-04).
    public let resolvedURL: URL

    public init(url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        self.url = url
        self.resolvedURL = resolved
        self.id = RawFileIdentity.fileID(for: resolved)
        self.statSignature = Self.statSignature(of: resolved)
    }

    /// Size + modification time in microseconds: exactly the two fields
    /// `ImageCacheStore.cacheURL` keys on.
    static func statSignature(of url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(Int(mtime * 1_000_000))"
    }

    /// Equality is the file's identity and the path the user picked: the stat
    /// snapshot is cache bookkeeping and must not make two references to the
    /// same file compare unequal.
    public static func == (lhs: SessionFile, rhs: SessionFile) -> Bool {
        lhs.url == rhs.url && lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(id)
    }
}
