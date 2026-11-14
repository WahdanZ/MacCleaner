import CryptoKit
import Foundation

// The plan the person reviews and the approval that authorizes exactly that plan. The approval names the plan by a
// digest over the items' identities (device, inode, kind, size, time), not just their paths, and over what the
// person was warned about (risk, what a command loses). Swapping an item after review, adding an entry to a folder
// whose contents were reviewed, changing a warning, or editing the plan after approval makes the approval not match.

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
    /// Part of the plan digest: it is the warning the person approved.
    public let consequence: String

    public init(executable: String, arguments: [String], consequence: String) {
        self.executable = executable
        self.arguments = arguments
        self.consequence = consequence
    }
}

/// One thing a candidate removes.
public enum CleanupTarget: Sendable, Hashable {
    /// The item itself: a file, a symlink as a link, or a folder with its whole subtree. For a folder the executor
    /// revalidates the folder's identity and re-checks protection over the subtree (a protected item inside blocks
    /// it), but does not snapshot every nested file; use `directoryContents` where entries come and go.
    case file(FileIdentity)
    /// The folder's direct entries as they were when reviewed; the folder itself stays. Only these entries are
    /// removed, each revalidated against its identity. An entry that appeared after review is left alone and
    /// reported as `SkipReason.addedAfterReview`.
    case directoryContents(folder: FileIdentity, entries: [FileIdentity])
    case command(ToolCommand)
    /// A whole item exactly as reviewed, for `overwriteThenDelete` only: the folder holding it (`parent`), the item
    /// (`root`, a file or a folder) and every entry below it (`entries`: files, links and folders, captured without
    /// following links, in `CleanupPlan.treeOrder`). Only these entries are ever touched; an entry that is not here
    /// is never opened, moved or deleted. `CleanupPlan.init` validates the shape (see `Problem.invalidTree`), and the
    /// digest covers every identity, including link counts and flags.
    case tree(parent: FileIdentity, root: FileIdentity, entries: [FileIdentity])
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
    /// Part of the plan digest.
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
        /// A folder-contents target with no reviewed entries.
        case emptyContents(String)
        /// A reviewed entry that isn't a direct child of its folder on the same volume (a mount point inside the
        /// folder is another volume and is never cleaned through it).
        case entryOutsideFolder(String)
        /// A `.tree` target that isn't a well-formed reviewed item: candidate id and what is wrong.
        case invalidTree(candidateID: String, reason: String)
    }

    public let entries: [Entry]
    /// Lower-case hex SHA-256 over, in order: each entry's id, module, risk and disposition, and each target's
    /// identity (folder-contents targets: the folder and every reviewed entry; commands: executable, arguments and
    /// consequence; trees: parent, item and every entry, each with its link count and flags).
    public let digest: String

    public init(_ entries: [Entry]) throws(Problem) {
        guard !entries.isEmpty else { throw .empty }
        var seen = Set<String>()
        for e in entries {
            let c = e.candidate
            guard seen.insert(c.id).inserted else { throw .duplicateCandidate(c.id) }
            guard !c.targets.isEmpty else { throw .noTargets(c.id) }
            guard c.risk != .protected else { throw .protectedCandidate(c.id) }
            var commands = 0, trees = 0
            for t in c.targets {
                switch t {
                case .command: commands += 1
                case .file: break
                case .directoryContents(let folder, let kids):
                    guard !kids.isEmpty else { throw .emptyContents(c.id) }
                    guard kids.allSatisfy({ $0.isDirectChild(of: folder) }) else { throw .entryOutsideFolder(c.id) }
                case .tree(let parent, let root, let kids):
                    trees += 1
                    if let why = Self.treeProblem(parent: parent, root: root, entries: kids) {
                        throw .invalidTree(candidateID: c.id, reason: why)
                    }
                }
            }
            let ok: Bool
            switch e.disposition {
            case .command: ok = commands == c.targets.count
            // A tree is shredded whole and only shredded: exactly one tree target, and no tree anywhere else.
            case .overwriteThenDelete: ok = trees == 1 && c.targets.count == 1
            case .trash, .permanentDelete, .quarantine: ok = commands == 0 && trees == 0
            }
            guard ok else { throw .dispositionMismatch(c.id) }
        }
        self.entries = entries
        self.digest = Self.digest(entries)
    }

    public var candidates: [CleanupCandidate] { entries.map(\.candidate) }

    /// The order a `.tree` target's entries are in: by path, compared byte by byte (UTF-8), so every folder comes
    /// before everything inside it and the order is the same everywhere.
    public static func treeOrder(_ a: FileIdentity, _ b: FileIdentity) -> Bool {
        a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
    }

    /// nil when a `.tree` target is a well-formed reviewed item; otherwise what is wrong. The rules: the parent is a
    /// folder and the item is directly inside it on the same volume; the item is a file or a folder (never a link);
    /// a file item has no entries; every entry is strictly below the item, on its volume, a file, folder or link,
    /// unique, in `treeOrder`, and directly inside the item or a folder entry (so nothing is below a link); and every
    /// file, the item included, has exactly one link (overwriting a hard link would erase the other copy).
    static func treeProblem(parent: FileIdentity, root: FileIdentity, entries: [FileIdentity]) -> String? {
        guard parent.kind == .directory else { return "its parent isn't a folder" }
        guard root.isDirectChild(of: parent) else { return "the item isn't directly inside its parent on the same volume" }
        switch root.kind {
        case .file:
            guard root.linkCount == 1 else { return "the item is a hard-linked file" }
            guard entries.isEmpty else { return "a file item has no entries" }
        case .directory: break
        case .symlink: return "the item is a link"
        case .other: return "the item isn't a file or folder"
        }
        var folders: Set<String> = [root.path]
        var previous: FileIdentity?
        for e in entries {
            if let previous, !treeOrder(previous, e) { return "entries aren't unique and in order (\(e.path))" }
            previous = e
            guard e.device == root.device else { return "\(e.path) is on another volume" }
            let parentPath = (e.path as NSString).deletingLastPathComponent
            let name = (e.path as NSString).lastPathComponent
            guard folders.contains(parentPath), !name.isEmpty, name != ".", name != "..",
                  e.path == parentPath + "/" + name else {
                return "\(e.path) isn't directly inside the item or one of its folders"
            }
            switch e.kind {
            case .directory: folders.insert(e.path)
            case .file: guard e.linkCount == 1 else { return "\(e.path) is a hard-linked file" }
            case .symlink: break
            case .other: return "\(e.path) isn't a file, folder or link"
            }
        }
        return nil
    }
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
            w.int(UInt64(e.candidate.risk.rawValue))
            w.string(e.disposition.rawValue)
            w.int(UInt64(e.candidate.targets.count))
            for t in e.candidate.targets {
                switch t {
                case .file(let f): w.string("file"); w.identity(f)
                case .directoryContents(let folder, let kids):
                    w.string("contents")
                    w.identity(folder)
                    w.int(UInt64(kids.count))
                    kids.forEach { w.identity($0) }
                case .command(let c):
                    w.string("command")
                    w.string(c.executable)
                    w.int(UInt64(c.arguments.count))
                    c.arguments.forEach { w.string($0) }
                    w.string(c.consequence)
                case .tree(let parent, let root, let kids):
                    // Link counts and flags too: the approval states that every file had one link and which flags
                    // were set when it was reviewed. (The other target kinds keep their encoding.)
                    w.string("tree")
                    w.treeIdentity(parent)
                    w.treeIdentity(root)
                    w.int(UInt64(kids.count))
                    kids.forEach { w.treeIdentity($0) }
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
        int(UInt64(bitPattern: f.capturedAtNanos))
    }

    mutating func treeIdentity(_ f: FileIdentity) {
        identity(f)
        int(UInt64(f.linkCount))
        int(UInt64(f.flags))
    }
}

/// A recorded go-ahead for one exact plan. Only an `ApprovalLedger` can make one (the initializer is internal to
/// Core), and only that ledger accepts it, once. It records who the caller said approved; it is not proof that they
/// did (see `ApprovalLedger`).
public struct CleanupApproval: Sendable, Hashable {
    public enum Approver: Sendable, Hashable {
        /// The person pressed the button in the app's review sheet showing this plan.
        case userInApp
        /// The person typed yes at the CLI prompt on a terminal (no TTY: preview only).
        case userInTerminal
        /// The person confirmed in Mac Cleaner's own window (HumanApproval), never the AI client's `confirm`.
        case userViaMCPPrompt
        /// `--yes` on the command line: nobody confirmed this run interactively. Whoever (or whatever) started the
        /// command chose to skip the prompt. Recorded as an override, never as a person's confirmation.
        case nonInteractiveOverride
        /// An enabled, versioned automation policy whose scope covers every entry of the plan.
        case standingPolicy(id: String, version: Int)
        /// Mac Cleaner moving to the Trash one folder it made itself, as part of an operation the person already
        /// started (`AppOwnedKind`). Nobody is asked again, so the ledger allows exactly one `.trash` of one folder
        /// of that kind's module and nothing else; the app may issue it only with the operation's own proof that the
        /// folder is the one it made (see the app's AppOwnedTrash).
        case appOwned(AppOwnedKind)
    }

    /// What Mac Cleaner made that it may move to the Trash itself. The raw value is the plan module it must use.
    public enum AppOwnedKind: String, Sendable, Hashable, CaseIterable {
        /// The folder the uninstall password step moved system items into.
        case adminStaging = "admin-staging"
        /// The usage skill folder Mac Cleaner installed for an AI assistant.
        case installedSkill = "installed-skill"
    }

    /// Why no approval was issued.
    public enum IssueRefusal: Error, Sendable, Hashable {
        /// Zero, negative or longer than the ledger's maximum lifetime.
        case invalidLifetime
        /// A standing policy may approve only regenerable items deleted permanently, never commands, Trash moves,
        /// overwrites or anything that needs review.
        case outsidePolicyScope(candidateID: String)
        /// An app-owned approval may cover only one entry: a `.trash` of exactly one folder, in its kind's module.
        case outsideAppOwnedScope(String)
    }

    public enum Refusal: Error, Sendable, Hashable {
        /// The plan isn't the one that was approved.
        case planChanged
        case expired
        /// Not issued by this ledger (made elsewhere, or by another ledger).
        case notIssued
        /// Already presented once.
        case alreadyUsed
    }

    public let planDigest: String
    public let approvedBy: Approver
    public let issued: Date
    public let expires: Date
    public let nonce: UUID

    init(plan: CleanupPlan, approvedBy: Approver, issued: Date, lifetime: TimeInterval, nonce: UUID) {
        self.planDigest = plan.digest
        self.approvedBy = approvedBy
        self.issued = issued
        self.expires = issued.addingTimeInterval(lifetime)
        self.nonce = nonce
    }

    /// nil when this approval matches `plan` and is in its validity window `[issued, expires)` at `now`. A lifetime
    /// of zero or less never authorizes anything. The ledger adds the issued and single-use checks.
    func refusal(for plan: CleanupPlan, at now: Date) -> Refusal? {
        guard plan.digest == planDigest else { return .planChanged }
        guard now >= issued, now < expires else { return .expired }
        return nil
    }
}

/// Issues approvals and accepts each one exactly once.
///
/// **What it does NOT do: verify that a person (or an enabled policy) approved anything.** `approvedBy` is a label the
/// caller supplies. The ledger is a record of an approval claim, not proof of human authorization. Making sure that
/// `CleanupExecutor.approve` is called only right after a real confirmation (review sheet, terminal prompt on a TTY,
/// Mac Cleaner's own window for MCP) or for an enabled, in-scope automation policy is an integration requirement
/// that is NOT met yet: M01-04b must meet it before the executor removes anything for the app, CLI or MCP.
///
/// What it does guarantee:
///
/// * **Creation only inside MacCleanerKit.** `CleanupApproval` has no public initializer and this type is
///   `package`-only, so code outside MacCleanerKit (the app, CLI and MCP code) can't make an approval except through
///   `CleanupExecutor.approve`. A standing policy can only approve what policies may cover, and an app-owned approval
///   only one Trash move of one folder of its kind (see `IssueRefusal`).
/// * **Plan binding.** An approval names the plan's digest; any other plan is refused.
/// * **Expiry.** Lifetimes are positive and at most `maxLifetime`; an approval is valid in `[issued, expires)`.
/// * **Single use.** `redeem` consumes the approval whatever the result (fail closed: a refused approval can't be
///   retried, the caller approves again). The ledger is `~Copyable`, so its state can't be duplicated to replay one.
/// * **Per process.** The ledger lives in memory in one process and approvals are never serialized. The app, each
///   `--cli` run and each `--mcp` server are separate processes with separate ledgers: an approval made in one can't
///   be redeemed in another (`notIssued`), and none survives a restart. So the CLI's terminal prompt and the MCP
///   server's own confirmation window must each approve inside the process that executes.
package struct ApprovalLedger: ~Copyable, Sendable {
    package typealias Approver = CleanupApproval.Approver

    package typealias IssueRefusal = CleanupApproval.IssueRefusal

    package static let maxLifetime: TimeInterval = 3600

    private var outstanding: [UUID: CleanupApproval] = [:]
    /// Consumed nonces, kept until their approval would have expired so a replay says `alreadyUsed`.
    private var consumed: [UUID: Date] = [:]

    package init() {}

    package mutating func issue(for plan: CleanupPlan, approvedBy: Approver, at now: Date,
                                lifetime: TimeInterval) throws(IssueRefusal) -> CleanupApproval {
        guard lifetime > 0, lifetime <= Self.maxLifetime else { throw .invalidLifetime }
        if case .standingPolicy = approvedBy {
            for e in plan.entries {
                let c = e.candidate
                let files = c.targets.allSatisfy { if case .command = $0 { return false }; return true }
                guard c.risk == .safeRegenerable, e.disposition == .permanentDelete, files else {
                    throw .outsidePolicyScope(candidateID: c.id)
                }
            }
        }
        if case .appOwned(let kind) = approvedBy {
            guard plan.entries.count == 1 else { throw .outsideAppOwnedScope("it must name exactly one item") }
            let e = plan.entries[0], c = e.candidate
            guard e.disposition == .trash else { throw .outsideAppOwnedScope("\(c.id) isn't a Trash move") }
            guard c.module == kind.rawValue else { throw .outsideAppOwnedScope("\(c.id) belongs to \(c.module), not \(kind.rawValue)") }
            guard c.targets.count == 1, case .file(let f) = c.targets[0], f.kind == .directory else {
                throw .outsideAppOwnedScope("\(c.id) must name exactly one folder")
            }
        }
        prune(at: now)
        let a = CleanupApproval(plan: plan, approvedBy: approvedBy, issued: now, lifetime: lifetime, nonce: UUID())
        outstanding[a.nonce] = a
        return a
    }

    /// nil when `approval` authorizes `plan` now; it is then used up. Any result consumes an issued approval.
    package mutating func redeem(_ approval: CleanupApproval, for plan: CleanupPlan, at now: Date) -> CleanupApproval.Refusal? {
        defer { prune(at: now) }
        if consumed[approval.nonce] != nil { return .alreadyUsed }
        guard let issued = outstanding[approval.nonce], issued == approval else { return .notIssued }
        outstanding[approval.nonce] = nil
        consumed[approval.nonce] = issued.expires
        return issued.refusal(for: plan, at: now)
    }

    /// Approvals issued and not yet presented.
    package var outstandingCount: Int { outstanding.count }

    /// Forgets expired approvals and the used nonces whose approval has expired.
    package mutating func prune(at now: Date) {
        outstanding = outstanding.filter { $0.value.expires > now }
        consumed = consumed.filter { $0.value > now }
    }
}
