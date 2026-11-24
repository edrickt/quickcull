import Foundation

/// One raw file in a culling session.
public struct SessionFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let id: String
    /// The last `"<size>|<mtime-us>"` the file was keyed under, seeded when it
    /// entered the session and refreshed by every successful live stat.
    ///
    /// The preview cache key embeds the source's size and mtime, and every
    /// read recomputes it. Once the source leaves the volume — card ejected,
    /// file moved or deleted — a live `stat` fails; without this snapshot the
    /// key fell back to the path alone and could never name the preview that
    /// was written while the file existed (QC-01). Keeping the *latest*
    /// observation matters when the mtime changed mid-session: the fallback
    /// still names the key the last write used. Nil when the file has never
    /// been stat-ed (a fixture path that does not exist on disk).
    public var statSignature: String? { signatureBox.current }

    /// Shared by value copies of the same file (the window loaders, the decode
    /// engine and the commit path each hold their own copy), so a stat seen by
    /// one of them is the fallback for all.
    private let signatureBox: SignatureBox

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
        self.signatureBox = SignatureBox(Self.statSignature(of: resolved))
    }

    /// Records a successful live stat so a later read with the source gone
    /// falls back to the key the write used.
    func recordStatSignature(_ signature: String) {
        signatureBox.record(signature)
    }

    /// Size + modification time in microseconds: exactly the two fields
    /// `ImageCacheStore.cacheURL` keys on.
    static func statSignature(of url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(Int(mtime * 1_000_000))"
    }

    /// Locked because `cacheURL` is `nonisolated` and runs on decode workers,
    /// while the window loaders read the fallback on the main actor.
    private final class SignatureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        init(_ value: String?) { self.value = value }

        var current: String? {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func record(_ signature: String) {
            lock.lock(); defer { lock.unlock() }
            value = signature
        }
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
