import AppKit
import CryptoKit
import SwiftUI

/// In-app updates from GitHub Releases.
///
/// Checks at most once a day (Settings › General can turn it off), or when you choose Check for Updates.
/// "Install and Relaunch" downloads the DMG and installs it only after these checks pass:
/// its SHA-256 matches the release's .sha256 file; the app inside has this app's ID and the advertised
/// version; its signature is valid; and once this copy is Developer ID–signed, the new one is signed by
/// the same team. Then a small script waits for this app to quit, swaps the new copy in and opens it.
/// The only request it makes is to api.github.com and the release's own download links; nothing about you is sent.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let repo = "WahdanZ/MacCleaner"
    static let autoKey = "autoCheckUpdates"
    static let lastCheckKey = "lastUpdateCheck"
    static let skipKey = "skippedUpdateVersion"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL
        let checksum: URL?
        let size: Int64
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    var phase: Phase = .idle
    var release: Release?
    var progress: Double = 0

    private var window: NSWindow?
    private var progressObservation: NSKeyValueObservation?

    static var autoCheck: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// The Developer ID team that signed this copy, or nil for an ad-hoc (not notarized) build.
    nonisolated static let currentTeamID: String? = teamID(of: Bundle.main.bundleURL)

    var lastCheck: Date? = UserDefaults.standard.object(forKey: Updater.lastCheckKey) as? Date {
        didSet { UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey) }
    }
    var updateAvailable: Bool { phase == .available && release != nil }

    // MARK: Checking

    /// Called by the automation timer (every 30 minutes): checks when it's on and a day has passed.
    func checkIfDue() {
        guard Self.autoCheck, phase == .idle || phase == .upToDate else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 86_400 { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if phase == .downloading || phase == .installing || phase == .checking {
            if userInitiated { show() }
            return
        }
        phase = .checking
        if userInitiated { show() }
        do {
            let r = try await Self.fetchLatest()
            lastCheck = Date()
            if Self.isNewer(r.version, than: Self.currentVersion) {
                release = r
                phase = .available
                if userInitiated || UserDefaults.standard.string(forKey: Self.skipKey) != r.version { show() }
            } else {
                release = nil
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func skipThisVersion() {
        if let r = release { UserDefaults.standard.set(r.version, forKey: Self.skipKey) }
        close()
    }

    // MARK: Installing

    func install() async {
        guard let r = release else { return }
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard !app.path.contains("/AppTranslocation/"), !app.path.hasPrefix("/Volumes/"),
              FileManager.default.isWritableFile(atPath: folder.path) else {
            phase = .failed("Mac Cleaner can't replace itself in “\(folder.path)”. Download the new version and drag it to Applications.")
            return
        }
        guard let checksumURL = r.checksum else {
            phase = .failed("This release has no checksum file, so the download can't be checked. Download it from GitHub instead.")
            return
        }
        phase = .downloading
        progress = 0
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacCleaner-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = try await download(r.dmg, to: work.appendingPathComponent(r.dmg.lastPathComponent))
            let (sums, resp) = try await URLSession.shared.data(from: checksumURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The checksum file didn't download.") }
            phase = .installing
            let staged = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(dmg: dmg, checksumFile: sums, version: r.version, work: work)
            }.value
            try Self.launchSwap(pid: getpid(), app: app, new: staged, work: work, relaunch: true)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL, to dest: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: UpdateError("The download failed. Try again later."))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch { cont.resume(throwing: error) }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let f = p.fractionCompleted
                Task { @MainActor in self?.progress = f }
            }
            task.resume()
        }
    }

    // MARK: Window

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: UpdateView().environment(self))
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = "Software Update"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

// MARK: - The checks (no UI; also used by the self-test)

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Updater {
    nonisolated static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacCleaner-Updater", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError("GitHub didn't answer (status \(status)). Try again later.") }
        guard let r = parseRelease(data) else { throw UpdateError("The latest release has no Mac Cleaner download.") }
        return r
    }

    /// Reads GitHub's "latest release" JSON. Needs a MacCleaner-<version>.dmg asset hosted on github.com.
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              j["draft"] as? Bool != true, j["prerelease"] as? Bool != true,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = j["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func link(_ name: String) -> (URL, Int64)? {
            guard let a = assets.first(where: { $0["name"] as? String == name }),
                  let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  u.scheme == "https", u.host == "github.com" else { return nil }
            return (u, (a["size"] as? NSNumber)?.int64Value ?? 0)
        }
        guard let (dmg, size) = link("MacCleaner-\(version).dmg") else { return nil }
        return Release(version: version, notes: j["body"] as? String ?? "", page: page,
                       dmg: dmg, checksum: link("MacCleaner-\(version).dmg.sha256")?.0, size: size)
    }

    /// "1.10.0" is newer than "1.9.2"; "1.3.0" is newer than "1.3.0-beta"; a leading "v" is ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> ([Int], Bool) {
            let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
            let pieces = t.split(separator: "-", maxSplits: 1)
            let nums = (pieces.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (nums, pieces.count > 1)
        }
        let (x, xPre) = parts(a), (y, yPre) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return !xPre && yPre
    }

    /// First word of a `shasum -a 256` line, if it is a SHA-256 in hex.
    nonisolated static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let h = first.lowercased()
        return h.count == 64 && h.allSatisfy({ $0.isHexDigit }) ? h : nil
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    /// "TeamIdentifier=ABCDE12345" from `codesign -dv`; nil when it says "not set" (ad-hoc signed).
    nonisolated static func parseTeamID(_ codesignOutput: String?) -> String? {
        guard let line = codesignOutput?.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let id = String(line.dropFirst("TeamIdentifier=".count))
        return id.isEmpty || id == "not set" ? nil : id
    }

    nonisolated static func teamID(of app: URL) -> String? {
        parseTeamID(Shell.run("/usr/bin/codesign", ["-dv", app.path], timeout: 30).output)
    }

    /// Checks the checksum, mounts the DMG, checks the app in it and copies it out. Returns the copy.
    nonisolated static func prepare(dmg: URL, checksumFile: Data, version: String, work: URL) throws -> URL {
        guard let expected = parseChecksum(String(decoding: checksumFile, as: UTF8.self)) else {
            throw UpdateError("The checksum file couldn't be read.")
        }
        guard try sha256(of: dmg) == expected else {
            throw UpdateError("The download doesn't match its checksum, so it wasn't installed.")
        }
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        let attach = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                    "-mountpoint", mount.path, dmg.path], timeout: 120)
        guard attach.status == 0 else { throw UpdateError("The disk image couldn't be opened.") }
        defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], timeout: 60) }

        let found = mount.appendingPathComponent("Mac Cleaner.app")
        try checkApp(found, version: version)
        let staged = work.appendingPathComponent("Mac Cleaner.app")
        guard Shell.run("/usr/bin/ditto", [found.path, staged.path], timeout: 300).status == 0 else {
            throw UpdateError("The new version couldn't be copied.")
        }
        try checkApp(staged, version: version)
        return staged
    }

    nonisolated static func checkApp(_ app: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download doesn't contain Mac Cleaner.")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("The download is not version \(version).")
        }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 120).status == 0 else {
            throw UpdateError("The new version's signature isn't valid, so it wasn't installed.")
        }
        if let mine = currentTeamID, teamID(of: app) != mine {
            throw UpdateError("The new version is signed by a different developer, so it wasn't installed.")
        }
    }

    /// Waits for PID to quit, swaps NEW in for APP (putting the old one back if anything fails),
    /// deletes WORK and opens the app. Only deletes a WORK folder named MacCleaner-update-*.
    nonisolated static let swapScript = #"""
    PID="$1"; APP="$2"; NEW="$3"; WORK="$4"; RELAUNCH="$5"
    i=0; while kill -0 "$PID" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
    DIR=$(dirname "$APP"); NAME=$(basename "$APP" .app)
    STAGE="$DIR/.$NAME.update.app"; OLD="$DIR/.$NAME.old.app"
    rm -rf "$STAGE" "$OLD"
    finish() {
      case "$(basename "$WORK")" in MacCleaner-update-*) rm -rf "$WORK" ;; esac
      [ "$RELAUNCH" = 1 ] && open "$APP"
      exit "$1"
    }
    ditto "$NEW" "$STAGE" || { rm -rf "$STAGE"; finish 1; }
    mv "$APP" "$OLD" || { rm -rf "$STAGE"; finish 1; }
    if mv "$STAGE" "$APP"; then rm -rf "$OLD"; else mv "$OLD" "$APP"; finish 1; fi
    finish 0
    """#

    nonisolated static func launchSwap(pid: Int32, app: URL, new: URL, work: URL, relaunch: Bool) throws {
        let script = work.appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(pid), app.path, new.path, work.path, relaunch ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

// MARK: - Software Update window

private struct UpdateView: View {
    @Environment(Updater.self) private var up

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder private var content: some View {
        switch up.phase {
        case .checking:
            Text("Checking for updates…").font(.headline)
            ProgressView().controlSize(.small)
        case .idle, .upToDate:
            Text("Mac Cleaner is up to date").font(.headline)
            Text("You have version \(Updater.currentVersion), the newest one.").foregroundStyle(Palette.dim)
            buttons { Button("OK") { up.close() }.keyboardShortcut(.defaultAction) }
        case .available:
            if let r = up.release { available(r) }
        case .downloading:
            Text("Downloading Mac Cleaner \(up.release?.version ?? "")…").font(.headline)
            ProgressView(value: up.progress)
        case .installing:
            Text("Installing…").font(.headline)
            ProgressView().controlSize(.small)
            Text("Mac Cleaner will quit and open the new version.").foregroundStyle(Palette.dim)
        case .failed(let message):
            Text("The update didn't finish").font(.headline)
            Text(message).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Close") { up.close() }
                Button("Open Download Page") {
                    NSWorkspace.shared.open(up.release?.page ?? Updater.releasesPage)
                    up.close()
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func available(_ r: Updater.Release) -> some View {
        Text("Mac Cleaner \(r.version) is available").font(.headline)
        Text("You have version \(Updater.currentVersion)." + (r.size > 0 ? " The download is \(ByteText.string(r.size))." : ""))
            .foregroundStyle(Palette.dim)
        if !r.notes.isEmpty {
            ScrollView {
                Text(Self.notes(r.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 180)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        Text("Before installing, Mac Cleaner checks the download against the release's checksum. Then it quits and opens the new version.")
            .font(.caption).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        if Updater.currentTeamID == nil {
            Text("This version isn't notarized by Apple yet, so after updating macOS may ask you to allow Full Disk Access again.")
                .font(.caption).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Skip This Version") { up.skipThisVersion() }
            Spacer()
            Button("Remind Me Later") { up.close() }
            Button("Install and Relaunch") { Task { await up.install() } }.keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    private func buttons<B: View>(@ViewBuilder _ b: () -> B) -> some View {
        HStack { Spacer(); b() }.padding(.top, 4)
    }

    /// GitHub release notes as inline Markdown; headings become bold lines.
    static func notes(_ md: String) -> AttributedString {
        let text = md.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return String(line) }
            let title = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "" : "**\(title)**"
        }.joined(separator: "\n")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(md)
    }
}
