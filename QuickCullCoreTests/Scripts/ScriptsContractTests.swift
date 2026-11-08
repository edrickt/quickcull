import Foundation
import XCTest

/// The scripts under `Scripts/` are documented as invoked from the repo root
/// (`Scripts/README.md`); a few resolve the root themselves with a `cd`. A
/// script whose working directory cannot see a repo-root-relative path it names
/// builds the wrong directory: the repo tidy that moved `start.sh` into
/// `Scripts/` left its `cd` pointing at `Scripts/`, so `xcodebuild` could not
/// find `QuickCull.xcodeproj`.
///
/// The contract models exactly the two `cd` spellings the scripts use and fails
/// loudly on any other form. Silently defaulting to the repo root is how a
/// reintroduced `cd "$(dirname "$0")" || exit 1` would have passed.
final class ScriptsContractTests: XCTestCase {
    /// Repo-root-relative paths that appear in script code and are present in
    /// every checkout (naming `Build/` would make the check depend on a prior
    /// build).
    private static let repoRelativePaths = [
        "QuickCull.xcodeproj",
        "QuickCullCore/QuickCullCore-Bridging-Header.h",
    ]

    private enum ContractError: Error, CustomStringConvertible {
        case unrecognizedWorkingDirectory(script: String, line: String)

        var description: String {
            switch self {
            case .unrecognizedWorkingDirectory(let script, let line):
                return "\(script): unrecognized working-directory form \"\(line)\"; "
                    + "teach ScriptsContractTests the spelling instead of guessing"
            }
        }
    }

    /// `<repo>/QuickCullCoreTests/Scripts/ScriptsContractTests.swift` → `<repo>`.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Scripts
            .deletingLastPathComponent()   // QuickCullCoreTests
            .deletingLastPathComponent()   // repo root
    }

    func testEveryScriptsRepoRelativePathResolvesFromItsOwnWorkingDirectory() throws {
        let scriptsDirectory = repoRoot.appendingPathComponent("Scripts", isDirectory: true)
        let scripts = try FileManager.default.contentsOfDirectory(atPath: scriptsDirectory.path)
            .filter { $0.hasSuffix(".sh") }
        XCTAssertFalse(scripts.isEmpty, "no shell scripts found at \(scriptsDirectory.path)")

        for script in scripts.sorted() {
            let scriptURL = scriptsDirectory.appendingPathComponent(script)
            let text = try String(contentsOf: scriptURL, encoding: .utf8)
            let workingDirectory = try simulatedWorkingDirectory(script: script, text: text)
            for path in Self.repoRelativePaths where Self.codeLines(text).contains(where: { $0.contains(path) }) {
                let resolved = workingDirectory.appendingPathComponent(path)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: resolved.path),
                    "\(script) runs from \(workingDirectory.lastPathComponent) but names \(path), "
                        + "which is not there")
            }
        }
    }

    func testStartScriptIsExecutable() {
        let script = repoRoot.appendingPathComponent("Scripts/start.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path),
                      "Scripts/start.sh is the documented dev loop and must stay executable")
    }

    /// An unrecognized `cd` form must fail the contract, not silently default to
    /// the repo root. This is the shape a reintroduced start.sh bug would take.
    func testUnrecognizedWorkingDirectoryFormFailsLoudly() {
        XCTAssertThrowsError(try simulatedWorkingDirectory(
            script: "start.sh",
            text: "#!/usr/bin/env bash\ncd \"$(dirname \"$0\")\" || exit 1\n")) { error in
            XCTAssertEqual(
                String(describing: error),
                "start.sh: unrecognized working-directory form \"cd \"$(dirname \"$0\")\" || exit 1\"; "
                    + "teach ScriptsContractTests the spelling instead of guessing")
        }
    }

    /// Only code lines are contracts: a path named in a comment is
    /// documentation, and the scripts' comments are full of them.
    func testCommentedPathsAreNotChecked() {
        let text = """
        # Builds QuickCull.xcodeproj from the root.
        # Needs QuickCullCore/QuickCullCore-Bridging-Header.h.
        echo "no repo paths here"
        """
        let code = Self.codeLines(text)
        for path in Self.repoRelativePaths {
            XCTAssertFalse(code.contains(where: { $0.contains(path) }),
                           "commented path \(path) must not be treated as a contract")
        }
    }

    // MARK: Helpers

    /// Lines whose first non-whitespace character is `#` are comments.
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
    }

    /// The working directory after the script's own `cd` lines, starting at the
    /// documented root invocation. A script that computes an absolute root
    /// (`ROOT="$(cd … && pwd)"`) is unaffected by its own working directory and
    /// keeps the root.
    private func simulatedWorkingDirectory(script: String, text: String) throws -> URL {
        var workingDirectory = repoRoot
        for line in Self.codeLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("cd ") else { continue }
            let argument = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            switch argument {
            case "\"$(dirname \"$0\")/..\"":
                workingDirectory = repoRoot
            case "\"$(dirname \"$0\")\"":
                workingDirectory = repoRoot.appendingPathComponent("Scripts", isDirectory: true)
            default:
                throw ContractError.unrecognizedWorkingDirectory(script: script, line: trimmed)
            }
        }
        return workingDirectory
    }
}
