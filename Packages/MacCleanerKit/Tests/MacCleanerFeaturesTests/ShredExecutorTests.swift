import Darwin
import Foundation
import Testing
import MacCleanerCore
@testable import MacCleanerPlatform
@testable import MacCleanerFeatures

// Overwrite-then-delete through the executor on real files (M01-04c): a snapshot becomes a plan, is approved, and
// exactly that tree is shredded. (The Platform's own checks are in MacCleanerPlatformTests/ShredTests.swift.)

@Suite("Shred: through the executor, on real files")
struct ShredExecutorRealDiskTests {
    let fm = FileManager.default
    let fs = LocalFileSystem(trashMover: { _ in throw PlatformError(message: "no Trash in these tests") })

    func sandbox() throws -> String {
        let base = fm.temporaryDirectory.appendingPathComponent("maccleaner-shred-exec-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return realPath(base.path)
    }
    func write(_ path: String, _ text: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    func plan(_ path: String) throws -> CleanupPlan {
        guard case .success(let s) = fs.shredSnapshot(at: path) else { throw PlatformError(message: "refused") }
        return try CleanupPlan([.init(CleanupCandidate(id: "item", module: "shredder", title: "item", targets: [s.target],
                                                       estimatedBytes: s.logicalBytes, allocatedBytes: s.allocatedBytes,
                                                       risk: .reviewRequired, recommended: false, explanation: ""), .overwriteThenDelete)])
    }

    @Test func anApprovedSnapshotIsShreddedAndReported() async throws {
        let root = try sandbox(); defer { try? fm.removeItem(atPath: root) }
        try write(root + "/item/a", "a"); try write(root + "/item/sub/b", "b")
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let p = try plan(root + "/item")
        let report = try await exec.execute(p, approval: try await exec.approve(p, by: .userInApp))
        let o = try #require(report.outcomes.first)
        let left = try fm.contentsOfDirectory(atPath: root)
        #expect(o.removedFiles == 2 && !fm.fileExists(atPath: root + "/item") && left.isEmpty)
        if case .removed(let bytes) = o.result { #expect(bytes > 0 && bytes == report.freedBytes) } else { Issue.record("\(o.result)") }
    }

    @Test func anItemReplacedAfterReviewIsSkippedUntouched() async throws {
        let root = try sandbox(); defer { try? fm.removeItem(atPath: root) }
        try write(root + "/item/a", "reviewed")
        let p = try plan(root + "/item")
        try fm.removeItem(atPath: root + "/item"); try write(root + "/item/a", "a new folder")
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let report = try await exec.execute(p, approval: try await exec.approve(p, by: .userInApp))
        #expect(report.outcomes.first?.result == .skipped(.changed(.replaced)))
        #expect((try? String(contentsOfFile: root + "/item/a", encoding: .utf8)) == "a new folder")
    }

    @Test func protectedAtExecutionTheItemIsSkipped() async throws {
        let root = try sandbox(); defer { try? fm.removeItem(atPath: root) }
        try write(root + "/item/a", "keep")
        let p = try plan(root + "/item")
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected(paths: [root + "/item"]))
        let report = try await exec.execute(p, approval: try await exec.approve(p, by: .userInApp))
        #expect(report.outcomes.first?.result == .skipped(.protected("Protected in Settings")) && fm.fileExists(atPath: root + "/item/a"))
    }
}
