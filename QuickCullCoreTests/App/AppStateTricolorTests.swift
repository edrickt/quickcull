import XCTest
@testable import QuickCullCore

@MainActor
final class AppStateTricolorTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!
    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "tri-app")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }
    private func makeState(mover: Moving = FileManagerMover()) -> AppState {
        AppState(decoder: StubDecoder(), cache: cache, trasher: StubTrasher(), mover: mover)
    }
    private func waitForScrubbing(_ s: AppState) async {
        for _ in 0..<200 { if s.phase == .scrubbing { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("never scrubbing")
    }

    func testPerColorFlagCountsAndHandle() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red)) // a red
        s.handle(.next); s.handle(.toggleFlag(.yellow)) // b yellow
        XCTAssertEqual(s.session?.flaggedCount(.red), 1)
        XCTAssertEqual(s.session?.flaggedCount(.yellow), 1)
        XCTAssertEqual(s.session?.flaggedCount(), 2)
        s.setFilter(.red); XCTAssertEqual(s.session?.files.count, 1)
    }

    func testRequestCommitPerColorRemovesOnlyThatColor() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let c = try TestFixtures.makeRawFile(named: "c.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a,b,c]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red)) // a
        s.handle(.next); s.handle(.toggleFlag(.yellow)) // b
        s.handle(.next); s.handle(.toggleFlag(.green)) // c
        s.requestCommit(color: .red)
        XCTAssertEqual(s.pendingCommitCount, 1)
        XCTAssertEqual(s.pendingCommitColor, .red)
        await s.confirmCommit()
        XCTAssertEqual(s.session?.flaggedCount(.red), 0)
        XCTAssertEqual(s.session?.flaggedCount(.yellow), 1)
        XCTAssertEqual(s.session?.flaggedCount(), 2)
        // all flagged
        s.requestCommit(color: nil)
        XCTAssertEqual(s.pendingCommitCount, 2)
        await s.confirmCommit()
        XCTAssertEqual(s.session?.flaggedCount() ?? 0, 0)
    }

    func testRequestMovePerColor() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let dest = try TestFixtures.makeTempDir(name: "tri-dest")
        defer { try? FileManager.default.removeItem(at: dest) }
        let s = makeState()
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red)) // a
        s.handle(.next); s.handle(.toggleFlag(.yellow)) // b
        s.requestMove(to: dest, color: .red)
        XCTAssertEqual(s.pendingMoveCount, 1)
        XCTAssertEqual(s.pendingMoveColor, .red)
        await s.confirmMove()
        XCTAssertEqual(s.session?.flaggedCount(.red), 0)
        XCTAssertEqual(s.session?.flaggedCount(.yellow), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.cr2").path))
    }
}
