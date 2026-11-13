import CryptoKit
import Foundation

// The plan the person reviews and the approval that authorizes exactly that plan. The approval names the plan by a
// digest over the items' identities (device, inode, kind, size, time), not just their paths, so swapping an item
// after review, or editing the plan after approval, makes the approval not match.

/// How risky an item is to remove. Separate from what is done with it (`Disposition`).
public enum CleanupRisk: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Rebuilt automatically (caches, build output).
    case safeRegenerable
    /// Fine to remove, but the person should look first (old archives, simulator runtimes).
    case reviewRequired
    /// May hold something the person made or can't get back.
    case potentialUserData
    /// Needs an administrator.
    case privileged
    /// Never removed. A plan refuses it.
    case protected

    public static func < (a: CleanupRisk, b: CleanupRisk) -> Bool { a.rawValue < b.rawValue }
}

/// What is done to an item.
public enum Disposition: String, Sendable, Hashable, CaseIterable {
    case trash
    case permanentDelete
    case overwriteThenDelete
    case quarantine
    /// Run a tool that removes it (simctl, docker, tmutil).
    case command
}

/// A tool run that removes something Mac Cleaner can't remove as files.
public struct ToolCommand: Sendable, Hashable {
    /// Absolute path of the executable.
    public let executable: String
    public let arguments: [String]
    /// What the person loses, in plain words ("The iOS 17.2 simulator runtime; Xcode downloads it again").
    public let consequence: String

    public init(executable: String, arguments: [String], consequence: String) {
        self.executable = executable
        self.arguments = arguments
        self.consequence = consequence
    }
}

/// One thing a candidate removes.
public enum CleanupTarget: Sendable, Hashable {
    /// The item itself (a file, a folder with everything in it, or a symlink as a link).
    case file(FileIdentity)
    /// Everything inside the folder; the folder stays.
    case directoryContents(FileIdentity)
    case command(ToolCommand)
}

/// One row the person reviews: "Xcode DerivedData, 4.2 GB". May remove several targets.
public struct CleanupCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    /// The module that found it ("caches", "projects", "sdks", …).
    public let module: String
    public let title: String
    public let targets: [CleanupTarget]
    /// Logical size measured at scan time.
    public let estimatedBytes: Int64
    /// Space on disk measured at scan time, when known.
    public let allocatedBytes: Int64?
    public let risk: CleanupRisk
    public let recommended: Bool
    /// Why it's safe or what to check, and how it comes back.
    public let explanation: String

    public init(id: String, module: String, title: String, targets: [CleanupTarget], estimatedBytes: Int64,
                allocatedBytes: Int64? = nil, risk: CleanupRisk, recommended: Bool, explanation: String) {
        self.id = id
        self.module = module
        self.title = title
        self.targets = targets
        self.estimatedBytes = estimatedBytes
        self.allocatedBytes = allocatedBytes
        self.risk = risk
        self.recommended = recommended
        self.explanation = explanation
    }
}

/// The ordered list of candidates and what to do with each, as reviewed. Built only through `init`, which refuses
/// a plan that could not be carried out as shown.
public struct CleanupPlan: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let candidate: CleanupCandidate
        public let disposition: Disposition

        public init(_ candidate: CleanupCandidate, _ disposition: Disposition) {
            self.candidate = candidate
            self.disposition = disposition
        }
    }

    public enum Problem: Error, Sendable, Hashable {
        case empty
        case duplicateCandidate(String)
        case noTargets(String)
        case protectedCandidate(String)
        /// A command target without the `.command` disposition, or the other way round.
        case dispositionMismatch(String)
    }

    public let entries: [Entry]
    /// Lower-case hex SHA-256 over the entries' ids, dispositions and target identities, in order.
    public let digest: String

    public init(_ entries: [Entry]) throws(Problem) {
        guard !entries.isEmpty else { throw .empty }
        var seen = Set<String>()
        for e in entries {
            let c = e.candidate
            guard seen.insert(c.id).inserted else { throw .duplicateCandidate(c.id) }
            guard !c.targets.isEmpty else { throw .noTargets(c.id) }
            guard c.risk != .protected else { throw .protectedCandidate(c.id) }
            let commands = c.targets.filter { if case .command = $0 { return true }; return false }.count
            let ok = e.disposition == .command ? commands == c.targets.count : commands == 0
            guard ok else { throw .dispositionMismatch(c.id) }
        }
        self.entries = entries
        self.digest = Self.digest(entries)
    }

    public var candidates: [CleanupCandidate] { entries.map(\.candidate) }
    public var estimatedBytes: Int64 { entries.reduce(0) { $0 + $1.candidate.estimatedBytes } }

    /// Titles, sizes and explanations are display text and are left out: rewording a row doesn't change what is
    /// removed. Every variable-length field is length-prefixed, so ["a b"] and ["a", "b"] differ.
    static func digest(_ entries: [Entry]) -> String {
        var w = DigestWriter()
        w.string("MacCleaner.CleanupPlan.v1")
        w.int(UInt64(entries.count))
        for e in entries {
            w.string(e.candidate.id)
            w.string(e.candidate.module)
            w.string(e.disposition.rawValue)
            w.int(UInt64(e.candidate.targets.count))
            for t in e.candidate.targets {
                switch t {
                case .file(let f): w.string("file"); w.identity(f)
                case .directoryContents(let f): w.string("contents"); w.identity(f)
                case .command(let c):
                    w.string("command")
                    w.string(c.executable)
                    w.int(UInt64(c.arguments.count))
                    c.arguments.forEach { w.string($0) }
                }
            }
        }
        return SHA256.hash(data: w.bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DigestWriter {
    var bytes: [UInt8] = []

    mutating func int(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }

    mutating func string(_ s: String) {
        let u = Array(s.utf8)
        int(UInt64(u.count))
        bytes.append(contentsOf: u)
    }

    mutating func identity(_ f: FileIdentity) {
        string(f.path)
        int(f.device)
        int(f.inode)
        string(f.kind.rawValue)
        int(UInt64(bitPattern: f.size))
        int(UInt64(bitPattern: f.modificationNanos))
    }
}

/// The person's go-ahead for one exact plan. Made only where a person actually approves: the app's review sheet,
/// the terminal prompt, Mac Cleaner's own MCP confirmation window, or an enabled automation policy. An AI client's
/// `confirm: true` is a request, never one of these. The executor also checks the nonce is used only once.
public struct CleanupApproval: Sendable, Hashable {
    public enum Approver: Sendable, Hashable {
        case userInApp
        case userInTerminal
        case userViaMCPPrompt
        case standingPolicy(id: String, version: Int)
    }

    public enum Refusal: Error, Sendable, Hashable {
        /// The plan isn't the one that was approved.
        case planChanged
        case expired
    }

    public let planDigest: String
    public let approvedBy: Approver
    public let issued: Date
    public let expires: Date
    public let nonce: UUID

    public init(plan: CleanupPlan, approvedBy: Approver, issued: Date, lifetime: TimeInterval, nonce: UUID = UUID()) {
        self.planDigest = plan.digest
        self.approvedBy = approvedBy
        self.issued = issued
        self.expires = issued.addingTimeInterval(lifetime)
        self.nonce = nonce
    }

    /// nil when this approval authorizes `plan` at `now`. Valid from `issued` up to, not including, `expires`; a
    /// lifetime of zero or less never authorizes anything.
    public func refusal(for plan: CleanupPlan, at now: Date) -> Refusal? {
        guard plan.digest == planDigest else { return .planChanged }
        guard now >= issued, now < expires else { return .expired }
        return nil
    }
}
