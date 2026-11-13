import CryptoKit
import Foundation
import MacCleanerCore
import MacCleanerPlatform

/// The usage skill folders (`<skills folder>/mac-cleaner`) Mac Cleaner installed for AI assistants, and the proof it
/// needs before it changes or removes one.
///
/// A folder counts as Mac Cleaner's only when it has a record here — written right after Mac Cleaner created the
/// folder and its SKILL.md, with both identities (device, inode) and the file's SHA-256 — and still matches it: the
/// same folder holding only that SKILL.md, the same file, the same content. Anything else is the person's and is never
/// overwritten or removed: a folder with no record (also one an older version installed, which kept no record, even
/// if its text matches), an edited SKILL.md, or a folder with other files in it. The record lives in the settings
/// store it is given (UserDefaults in the app, memory in the self-test). "Save skill folder" writes a copy that is
/// never recorded, so it is never removed.
struct InstalledSkills {
    static let key = "installedSkills"
    static let fileName = "SKILL.md"
    let store: SettingsStore

    struct Record: Codable, Equatable, Sendable {
        var folderDevice: UInt64
        var folderInode: UInt64
        var fileDevice: UInt64
        var fileInode: UInt64
        var sha256: String
    }

    /// Proof that `folder` is a skill folder Mac Cleaner installed and nobody changed (as checked when it was made).
    /// Only `state(at:)` makes one; AppOwnedTrash.trashSkill needs one to move the folder.
    struct Verified: Sendable {
        let folder: FileIdentity
        let record: Record
        var url: URL { URL(fileURLWithPath: folder.path, isDirectory: true) }
        fileprivate init(folder: FileIdentity, record: Record) {
            self.folder = folder
            self.record = record
        }
    }

    enum State {
        /// Nothing at that path.
        case absent
        /// Mac Cleaner's, unchanged; `current` when it holds this version's text.
        case owned(Verified, current: Bool)
        /// The person's (or not provably Mac Cleaner's): never changed or removed. Says why.
        case notOwned(String)
    }

    enum Problem: LocalizedError {
        case alreadyThere(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .alreadyThere(let p): return "A \(SkillText.name) folder is already in \(p); it was left unchanged"
            case .failed(let why): return why
            }
        }
    }

    static let legacyReason = "Mac Cleaner has no record of installing it (older versions kept none), so it was left for you to remove if you don't need it"

    /// Where the skill folder goes in `skillsDir`, with symlinks in the folders above it resolved.
    static func folderPath(in skillsDir: String) -> String {
        AppCleanup.physicalPath(URL(fileURLWithPath: skillsDir).appendingPathComponent(SkillText.name))
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static var templateHash: String { sha256(Data(SkillText.markdown.utf8)) }

    // MARK: - Records

    private var records: [String: Record] {
        guard let raw = store.object(forKey: Self.key) as? [String: String] else { return [:] }
        return raw.compactMapValues { try? JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
    }

    private func setRecord(_ r: Record?, for folder: String) {
        var raw = store.object(forKey: Self.key) as? [String: String] ?? [:]
        raw[folder] = r.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        store.set(raw, forKey: Self.key)
    }

    func forget(_ folder: String) { setRecord(nil, for: folder) }

    // MARK: - Checking

    /// What is at `folder` (from `folderPath(in:)`).
    func state(at folder: String) -> State {
        guard (try? LocalFileSystem().identity(at: folder)) != nil else {
            var st = stat()
            return lstat(folder, &st) == 0 ? .notOwned("it couldn't be checked") : .absent
        }
        guard let record = records[folder] else { return .notOwned(Self.legacyReason) }
        switch Self.check(folder, against: record) {
        case .failure(let why): return .notOwned(why.text)
        case .success(let (identity, hash)): return .owned(Verified(folder: identity, record: record), current: hash == Self.templateHash)
        }
    }

    /// nil when `skill` is still unchanged (run again right before it moves); otherwise why it must be kept.
    static func recheck(_ skill: Verified) -> String? {
        if case .failure(let why) = check(skill.folder.path, against: skill.record) { return why.text }
        return nil
    }

    struct Refusal: Error { let text: String }

    /// The folder and its content hash, if `folder` is still the recorded folder (not a link) holding only the recorded
    /// SKILL.md (not a link) with the recorded content.
    private static func check(_ folder: String, against r: Record) -> Result<(FileIdentity, String), Refusal> {
        let fs = LocalFileSystem()
        guard let dir = try? fs.identity(at: folder) else { return .failure(Refusal(text: "it's no longer there")) }
        guard dir.kind == .directory, dir.device == r.folderDevice, dir.inode == r.folderInode else {
            return .failure(Refusal(text: "it isn't the folder Mac Cleaner installed"))
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return .failure(Refusal(text: "it couldn't be checked"))
        }
        guard names == [fileName] else { return .failure(Refusal(text: "it holds files Mac Cleaner didn't put there")) }
        let path = folder + "/" + fileName
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(Refusal(text: "its \(fileName) couldn't be read")) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, case let f = FileIdentity(path: path, stat: st),
              f.kind == .file, f.device == r.fileDevice, f.inode == r.fileInode else {
            return .failure(Refusal(text: "its \(fileName) was replaced"))
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard sha256(data) == r.sha256 else { return .failure(Refusal(text: "its \(fileName) was edited")) }
        return .success((dir, sha256(data)))
    }

    // MARK: - Writing

    /// Installs this version's skill as a new folder in `skillsDir` (made if needed) and records it, only after both the
    /// folder and the file were created. Never writes into an existing folder. Returns the folder and its record.
    @discardableResult
    func install(in skillsDir: String) throws -> (folder: String, record: Record) {
        try FileManager.default.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
        let folder = Self.folderPath(in: skillsDir)
        let data = Data(SkillText.markdown.utf8)
        try Self.create(folder, data)
        let fs = LocalFileSystem()
        guard let dir = try? fs.identity(at: folder), let file = try? fs.identity(at: folder + "/" + Self.fileName) else {
            throw Problem.failed("The skill was written to \(folder) but couldn't be checked; it isn't recorded as Mac Cleaner's")
        }
        let r = Record(folderDevice: dir.device, folderInode: dir.inode, fileDevice: file.device, fileInode: file.inode,
                       sha256: Self.sha256(data))
        setRecord(r, for: folder)
        return (folder, r)
    }

    /// Replaces an unchanged, older Mac Cleaner skill's text with this version's (written beside it, then renamed over
    /// it) and records the new file.
    func update(_ skill: Verified) throws {
        if let why = Self.recheck(skill) { throw Problem.failed("The skill in \(skill.folder.path) was kept: \(why)") }
        let data = Data(SkillText.markdown.utf8)
        let target = skill.folder.path + "/" + Self.fileName, temp = target + ".maccleaner-new"
        try Self.write(data, to: temp)
        guard rename(temp, target) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(temp)
            throw Problem.failed("The skill in \(skill.folder.path) couldn't be updated (\(why))")
        }
        guard let file = try? LocalFileSystem().identity(at: target) else {
            forget(skill.folder.path)
            throw Problem.failed("The skill in \(skill.folder.path) was updated but couldn't be checked; it isn't recorded as Mac Cleaner's")
        }
        var r = skill.record
        r.fileDevice = file.device; r.fileInode = file.inode; r.sha256 = Self.sha256(data)
        setRecord(r, for: skill.folder.path)
    }

    /// Undoes `install` when the rest of Connect failed: removes the folder it just made, only if it is still exactly
    /// what was installed. nil when removed; otherwise why it was left (still recorded, so Disconnect can find it).
    func undoInstall(folder: String, record: Record) -> String? {
        guard case .owned(let v, _) = state(at: folder), v.record == record else { return "it changed after it was installed" }
        guard unlink(folder + "/" + Self.fileName) == 0, rmdir(folder) == 0 else { return String(cString: strerror(errno)) }
        forget(folder)
        return nil
    }

    /// "Save skill folder": writes this version's skill as a new folder in `dir` the person picked. Never overwrites
    /// and is never recorded, so Mac Cleaner never removes it.
    static func saveCopy(in dir: String) throws -> String {
        let folder = folderPath(in: dir)
        try create(folder, Data(SkillText.markdown.utf8))
        return folder
    }

    /// Makes `folder` (which must not exist) and its SKILL.md (exclusively, links never followed). On failure, removes
    /// what it made.
    private static func create(_ folder: String, _ data: Data) throws {
        guard mkdir(folder, 0o755) == 0 else {
            if errno == EEXIST { throw Problem.alreadyThere((folder as NSString).deletingLastPathComponent) }
            throw Problem.failed("The skill folder \(folder) couldn't be made (\(String(cString: strerror(errno))))")
        }
        do { try write(data, to: folder + "/" + fileName) } catch {
            rmdir(folder)
            throw error
        }
    }

    /// Writes `data` to a new file at `path` (O_EXCL, no links followed); removes it again if the write fails.
    private static func write(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Problem.failed("\(path) couldn't be written (\(String(cString: strerror(errno))))") }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        guard ok else {
            unlink(path)
            throw Problem.failed("\(path) couldn't be written")
        }
    }
}
