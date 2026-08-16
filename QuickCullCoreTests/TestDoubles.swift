import CoreGraphics
import Foundation
import XCTest
@testable import QuickCullCore

/// Deterministic fake decoder: success for most files, failure for a
/// designated one; records every call (thread-safe).
final class StubDecoder: RawDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    let failIDs: Set<String>

    init(failIDs: Set<String> = []) {
        self.failIDs = failIDs
    }

    func decodeRaw(at url: URL) throws -> RawBitmap {
        lock.lock(); defer { lock.unlock() }
        let id = RawFileIdentity.fileID(for: url)
        calls.append(id)
        if failIDs.contains(id) {
            throw DecodeError.cannotUnpack("stub failure")
        }
        let width = 8, height = 4
        var bytes = [UInt8](repeating: 100, count: width * height * 3)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return RawBitmap(image: image, width: width, height: height, flip: 0)
    }

    func callCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }
}

/// Deterministic fake trasher: fails for a designated set of file ids,
/// records everything it trashed.
final class StubTrasher: Trashing {
    var failIDs: Set<String> = []
    private(set) var trashed: [String] = []

    func trash(url: URL) throws {
        let id = RawFileIdentity.fileID(for: url)
        if failIDs.contains(id) {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "volume without trash"])
        }
        trashed.append(id)
    }
}
