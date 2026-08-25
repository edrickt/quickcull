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
    let histogram: RawHistogram?

    init(failIDs: Set<String> = [], histogram: RawHistogram? = nil) {
        self.failIDs = failIDs
        self.histogram = histogram
    }

    func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap {
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
        return RawBitmap(image: image, width: width, height: height, flip: 0,
                         histogram: histogram)
    }

    func callCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }
}

/// Deterministic slow decoder: same as StubDecoder, but sleeps `delay`
/// nanoseconds per call before returning, so cancellation windows can be
/// exercised deterministically; records every call (thread-safe).
final class SlowStubDecoder: RawDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    let failIDs: Set<String>
    private let delay: UInt64

    init(failIDs: Set<String> = [], delay: UInt64 = 0) {
        self.failIDs = failIDs
        self.delay = delay
    }

    func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap {
        lock.lock(); defer { lock.unlock() }
        let id = RawFileIdentity.fileID(for: url)
        calls.append(id)
        if delay > 0 {
            // decodeRaw is synchronous (protocol requirement), so park on a
            // semaphore while a child task performs the sleep.
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await Task.sleep(nanoseconds: delay)
                semaphore.signal()
            }
            semaphore.wait()
        }
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
/// records everything it trashed. Can gate on a semaphore so a commit can be
/// held in flight (thread-safe).
final class StubTrasher: Trashing, @unchecked Sendable {
    var failIDs: Set<String> = []
    /// When set, `trash(url:)` waits on this semaphore before recording the
    /// call — lets tests hold a commit in flight.
    var gate: DispatchSemaphore?
    private let lock = NSLock()
    private var _trashed: [String] = []

    var trashed: [String] {
        lock.lock(); defer { lock.unlock() }
        return _trashed
    }

    func trash(url: URL) throws {
        gate?.wait()
        let id = RawFileIdentity.fileID(for: url)
        if failIDs.contains(id) {
            throw NSError(domain: "stub", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "volume without trash"])
        }
        lock.lock(); defer { lock.unlock() }
        _trashed.append(id)
    }
}
