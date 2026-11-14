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
        /// Mac Cleaner's, unchanged; `current` when it holds this version's text. An older text is kept as it is.
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

    /// Undoes `install` when the rest of Connect failed: removes the folder it just made, only if it is provably
    /// exactly what was installed at the moment it is removed. Each item is first moved to a new private name (atomic,
    /// never replacing anything) and only what was moved is checked — the recorded folder, holding only the recorded
    /// SKILL.md with the recorded content — then the file is unlinked and the folder removed (rmdir: only if empty).
    /// Anything else is moved back untouched. nil when removed; otherwise why it was left (and where, if it couldn't be
    /// moved back). `afterCheck` runs between the ownership check and the first move (the self-test changes things
    /// there).
    func undoInstall(folder: String, record: Record, afterCheck: () -> Void = {}) -> String? {
        guard case .owned(let v, _) = state(at: folder), v.record == record else { return "it changed after it was installed" }
        afterCheck()
        let parentPath = (folder as NSString).deletingLastPathComponent, leaf = (folder as NSString).lastPathComponent
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { return "its folder couldn't be opened" }
        defer { close(parent) }
        // 1. The folder itself, held under a private name while it is checked and emptied.
        let held: String
        switch Self.take(parent, leaf, matches: { st in
            let f = FileIdentity(path: folder, stat: st)
            return f.kind == .directory && f.device == record.folderDevice && f.inode == record.folderInode
        }) {
        case .failure(let why): return why.text
        case .success(let name): held = name
        }
        func giveBack(_ why: String) -> String {
            if renameatx_np(parent, held, parent, leaf, UInt32(RENAME_EXCL)) == 0 { return why }
            return why + "; it is in \(parentPath)/\(held)"
        }
        let dir = openat(parent, held, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return giveBack("it couldn't be opened") }
        defer { close(dir) }
        // 2. Its SKILL.md, held under a private name inside it: the recorded file with the recorded content.
        let heldFile: String
        switch Self.take(dir, Self.fileName, matches: { st in
            let f = FileIdentity(path: folder + "/" + Self.fileName, stat: st)
            return f.kind == .file && f.device == record.fileDevice && f.inode == record.fileInode
        }) {
        case .failure(let why): return giveBack(why.text)
        case .success(let name): heldFile = name
        }
        let fd = openat(dir, heldFile, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var st = stat()
        let content: Data? = fd >= 0 && fstat(fd, &st) == 0 && UInt64(st.st_ino) == record.fileInode
            ? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile() : nil
        if fd >= 0 { close(fd) }
        guard let content, Self.sha256(content) == record.sha256 else {
            let back = renameatx_np(dir, heldFile, dir, Self.fileName, UInt32(RENAME_EXCL)) == 0
            return giveBack("its \(Self.fileName) was edited" + (back ? "" : "; it is named \(heldFile)"))
        }
        // Nothing else may be in the folder (checked while both are held under names only this run uses).
        guard (try? FileManager.default.contentsOfDirectory(atPath: parentPath + "/" + held)) == [heldFile] else {
            let back = renameatx_np(dir, heldFile, dir, Self.fileName, UInt32(RENAME_EXCL)) == 0
            return giveBack("it holds files Mac Cleaner didn't put there" + (back ? "" : "; its \(Self.fileName) is named \(heldFile)"))
        }
        // 3. Only now: the file proven to be ours is unlinked, then the folder (rmdir: only if empty).
        guard unlinkat(dir, heldFile, 0) == 0 else {
            let back = renameatx_np(dir, heldFile, dir, Self.fileName, UInt32(RENAME_EXCL)) == 0
            return giveBack("its \(Self.fileName) couldn't be removed" + (back ? "" : "; it is named \(heldFile)"))
        }
        guard unlinkat(parent, held, AT_REMOVEDIR) == 0 else { return giveBack("it holds files Mac Cleaner didn't put there") }
        forget(folder)
        return nil
    }

    /// Moves `name` in `dir` to a fresh private name (RENAME_EXCL: never replaces anything) and checks what was moved
    /// with `matches` (links are never followed). The private name when it matches; otherwise it is moved back (or, if
    /// its name was taken meanwhile, left under the private name, which the refusal says).
    private static func take(_ dir: Int32, _ name: String, matches: (stat) -> Bool) -> Result<String, Refusal> {
        let held = ".maccleaner-undo-" + UUID().uuidString
        guard renameatx_np(dir, name, dir, held, UInt32(RENAME_EXCL)) == 0 else {
            return .failure(Refusal(text: errno == ENOENT ? "it's no longer there" : "it couldn't be moved (\(String(cString: strerror(errno))))"))
        }
        var st = stat()
        if fstatat(dir, held, &st, AT_SYMLINK_NOFOLLOW) == 0, matches(st) { return .success(held) }
        let what = name == fileName ? "its \(fileName) was replaced" : "it isn't the folder Mac Cleaner installed"
        if renameatx_np(dir, held, dir, name, UInt32(RENAME_EXCL)) == 0 { return .failure(Refusal(text: what)) }
        return .failure(Refusal(text: what + "; it was left named \(held)"))
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
