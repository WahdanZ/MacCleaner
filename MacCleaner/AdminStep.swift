import Foundation
import MacCleanerCore

/// Runs the system part of an uninstall through macOS's own administrator prompt
/// (`osascript … with administrator privileges`). Files go to a folder in your Trash.
///
/// The root script moves the items into a new folder that only root can open: `mktemp -d` makes it in
/// /private/var/tmp with a random name and mode 700, so no other process can create it first, put links in it or
/// swap it (that folder is sticky, so nobody else can rename it). The script then hands you only that one folder
/// (`chown` without `-R`) and prints its path. The items inside keep their system owner: a recursive `chown` as root
/// would also change the owner of any file that something had hard-linked into a moved folder. The app then moves the
/// folder to the Trash with the normal API (the Trash itself is privacy-protected even for root).
enum AdminStep {
    enum Result { case ok(staging: URL, report: Report), cancelled, failed(String) }

    /// What the privileged step reported per item (indexes into the items it was given).
    struct Report: Equatable, Sendable {
        /// Moved into staging and verified there as the reviewed item. The only items Mac Cleaner moved: anything not
        /// listed here was not moved by it, whatever its original path looks like now.
        var moved: Set<Int> = []
        /// Not there any more when the privileged step ran (nothing was moved).
        var missing: Set<Int> = []
        /// Its folder wasn't a real folder owned by root any more (nothing was moved).
        var folderChanged: Set<Int> = []
        /// The move itself failed (e.g. a locked item), or it vanished during the move.
        var failed: Set<Int> = []
        /// Outside the folders the password step may touch (nothing was moved).
        var notAllowed: Set<Int> = []
        /// Moved into staging, then found not to be the reviewed item, and moved straight back.
        var changed: Set<Int> = []
        /// Not the reviewed item and couldn't be moved back (its name was taken): left inside staging, so the staging
        /// folder must not go to the Trash.
        var keptInStaging: Set<Int> = []
        /// No reviewed identity to check against: refused, not moved.
        var unidentified: Set<Int> = []
        /// On another volume than the staging folder (a move would copy): refused, not moved.
        var otherVolume: Set<Int> = []

        static func parse(_ output: String?) -> Report {
            var r = Report()
            for line in (output ?? "").split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let i = Int(parts[1]) else { continue }
                switch parts[0] {
                case "MACCLEANER-MOVED": r.moved.insert(i)
                case "MACCLEANER-MISSING": r.missing.insert(i)
                case "MACCLEANER-FOLDER": r.folderChanged.insert(i)
                case "MACCLEANER-FAILED": r.failed.insert(i)
                case "MACCLEANER-NOT-ALLOWED": r.notAllowed.insert(i)
                case "MACCLEANER-CHANGED": r.changed.insert(i)
                case "MACCLEANER-KEPT": r.keptInStaging.insert(i)
                case "MACCLEANER-UNIDENTIFIED": r.unidentified.insert(i)
                case "MACCLEANER-OTHER-VOLUME": r.otherVolume.insert(i)
                default: break
                }
            }
            return r
        }

        /// Why item `i` wasn't moved, or nil when it was. An item with no report line at all is "not confirmed", never
        /// assumed moved.
        func notMovedReason(_ i: Int) -> String? {
            if moved.contains(i) { return nil }
            if changed.contains(i) || keptInStaging.contains(i) { return "it changed after you reviewed it, so it was left alone" }
            if missing.contains(i) { return "it was gone before the password step ran, so Mac Cleaner didn't remove it" }
            if folderChanged.contains(i) { return "its folder changed, so it was left alone" }
            if failed.contains(i) { return "it couldn't be moved" }
            if notAllowed.contains(i) { return "it isn't in a folder the password step may touch" }
            if unidentified.contains(i) { return "it couldn't be identified when it was found, so it was left alone" }
            if otherVolume.contains(i) { return "it's on another volume, so it was left alone" }
            return "Mac Cleaner can't confirm it was removed"
        }
    }

    /// What `stat -f` prints for the reviewed item: device, inode and type, plus size and modification time (whole
    /// seconds) for a regular file. nil for kinds the step doesn't move.
    static func expectedStat(_ f: FileIdentity) -> (format: String, value: String)? {
        let dev = Int32(bitPattern: UInt32(truncatingIfNeeded: f.device))
        switch f.kind {
        case .directory: return ("%d:%i:%HT", "\(dev):\(f.inode):Directory")
        case .symlink: return ("%d:%i:%HT", "\(dev):\(f.inode):Symbolic Link")
        case .file:
            let secs = f.modificationNanos >= 0 ? f.modificationNanos / 1_000_000_000 : (f.modificationNanos - 999_999_999) / 1_000_000_000
            return ("%d:%i:%HT:%z:%m", "\(dev):\(f.inode):Regular File:\(f.size):\(secs)")
        case .other: return nil
        }
    }

    /// Where the root script makes its staging folder; `mktemp` replaces the X's with random characters.
    static let stagingParent = "/private/var/tmp"
    static let stagingPrefix = "MacCleaner-uninstall."
    static let stagingTemplate = stagingParent + "/" + stagingPrefix + "XXXXXXXXXX"

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The shell script the password step runs as root. Pure, so the self-test can check it.
    /// Each item is checked again inside the script, at the privileged move itself: its folder must still be a real
    /// folder (not a link) owned by `parentOwner` (root), and it must be on the staging folder's volume (so the move
    /// is a rename that keeps its identity). It is then moved into the staging folder (root-only until the end) and
    /// the moved object is compared with its reviewed `identity`; if it isn't that item, it is moved straight back
    /// (or, if its name was taken meanwhile, left in staging and reported, so staging never goes to the Trash). An
    /// item without a reviewed identity is refused. Only the self-test passes other values for `allowed`,
    /// `parentOwner` and `chown`, to run the script as you on throwaway files.
    static func script(_ items: [AppLeftover], uid: uid_t,
                       allowed: (URL) -> Bool = AdminGuard.isAllowed,
                       parentOwner: uid_t = 0, chown: String = "/usr/sbin/chown",
                       launchctl: String = "/bin/launchctl", pkgutil: String = "/usr/sbin/pkgutil") -> String {
        let safeName = "^[A-Za-z0-9._-]+$"
        // R is set when any file item wasn't verified and moved; then installer receipts are not forgotten (the uninstall
        // didn't fully happen). A launch job is stopped, and audio restarted for a HAL plug-in, only right after that
        // item's own file was verified and moved, so a stale or replaced item never stops or restarts anything.
        var lines = ["set -u", "R=", "A=",
                     "D=$(/usr/bin/mktemp -d \(q(stagingTemplate))) || exit 1"]
        var receipts: [String] = []
        for (i, l) in items.enumerated() {
            if let pkg = l.receipt {
                if pkg.range(of: safeName, options: .regularExpression) != nil {
                    receipts.append("\(q(pkgutil)) --forget \(pkg) >/dev/null 2>&1 || true")
                }
                continue
            }
            guard allowed(l.url) else { lines.append("echo MACCLEANER-NOT-ALLOWED \(i); R=1"); continue }
            guard let reviewed = l.identity, let expected = expectedStat(reviewed) else {
                lines.append("echo MACCLEANER-UNIDENTIFIED \(i); R=1")
                continue
            }
            var onVerified = ""
            if let label = l.launchLabel, label.range(of: safeName, options: .regularExpression) != nil {
                let domain = l.launchSystem ? "system" : "gui/\(uid)"
                onVerified += " \(q(launchctl)) bootout \(domain)/\(label) 2>/dev/null || true;"
            }
            if l.url.path.hasPrefix("/Library/Audio/Plug-Ins/HAL/") { onVerified += " A=1;" }
            let item = l.url.standardizedFileURL
            let src = q(item.path), dir = q(item.deletingLastPathComponent().path)
            let staged = "\"$D\"" + q("/\(i)-" + item.lastPathComponent)
            let present = { (p: String) in "{ [ -e \(p) ] || [ -L \(p) ]; }" }
            lines.append("if [ -d \(dir) ] && [ ! -L \(dir) ] && [ \"$(/usr/bin/stat -f %u \(dir))\" = \(parentOwner) ]"
                         + " && \(present(src)); then"
                         + " if [ \"$(/usr/bin/stat -f %d \(src))\" != \"$(/usr/bin/stat -f %d \"$D\")\" ]; then echo MACCLEANER-OTHER-VOLUME \(i); R=1;"
                         + " else /bin/mv -n -- \(src) \(staged);"
                         + " if ! \(present(staged)); then echo MACCLEANER-FAILED \(i); R=1;"
                         + " elif [ \"$(/usr/bin/stat -f \(q(expected.format)) \(staged))\" != \(q(expected.value)) ]; then"
                         + " /bin/mv -n -- \(staged) \(src); R=1;"
                         + " if \(present(staged)); then echo MACCLEANER-KEPT \(i); else echo MACCLEANER-CHANGED \(i); fi;"
                         + " else echo MACCLEANER-MOVED \(i);\(onVerified)"
                         + " fi; fi;"
                         + " elif [ -d \(dir) ] && [ ! -L \(dir) ] && [ \"$(/usr/bin/stat -f %u \(dir))\" = \(parentOwner) ]; then echo MACCLEANER-MISSING \(i); R=1;"
                         + " else echo MACCLEANER-FOLDER \(i); R=1; fi")
        }
        if !receipts.isEmpty { lines.append("if [ -z \"$R\" ]; then \(receipts.joined(separator: "; ")); fi") }
        lines.append("if [ -n \"$A\" ]; then /usr/bin/killall coreaudiod 2>/dev/null || true; fi")   // a verified HAL plug-in moved
        // Only the staging folder itself changes owner, never anything inside it.
        lines.append("\(q(chown)) \(uid) \"$D\" || exit 1")
        lines.append("echo \"$D\"")
        return lines.joined(separator: "; ")
    }

    /// The staging folder the script printed, if it is exactly what `mktemp` makes from `stagingTemplate`.
    static func parseStaging(_ output: String?) -> URL? {
        guard let line = output?.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return nil }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: stagingParent + "/" + stagingPrefix) + "[A-Za-z0-9]{10}$"
        guard line.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return URL(fileURLWithPath: line, isDirectory: true)
    }

    /// A real folder (not a link), owned by `uid` and closed to everyone else.
    static func isTrustedStaging(_ url: URL, uid: uid_t) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == uid && (st.st_mode & 0o077) == 0
    }

    /// `do shell script "…"` for osascript, with the script escaped for an AppleScript string.
    /// `admin: false` runs it as you, without a password (the self-test uses that).
    static func appleScript(_ script: String, admin: Bool = true) -> String {
        "do shell script \"" + script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\"" + (admin ? " with administrator privileges" : "")
    }

    static func run(_ items: [AppLeftover], uid: uid_t) -> Result {
        let r = Shell.run("/usr/bin/osascript", ["-e", appleScript(script(items, uid: uid))], timeout: 600)
        if r.status == 0 {
            guard let staging = parseStaging(r.output), isTrustedStaging(staging, uid: uid) else {
                return .failed("The password step finished, but its staging folder could not be checked, so it was not sent to the Trash. Look in \(stagingParent) for a folder named \(stagingPrefix)….")
            }
            return .ok(staging: staging, report: Report.parse(r.output))
        }
        let out = r.output ?? ""
        if out.contains("-128") || out.lowercased().contains("cancel") { return .cancelled }
        return .failed(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
