import CryptoKit
import Foundation

/// `Mac Cleaner --selftest`: checks every safety rule. Creates only throwaway files under
/// ~/.maccleaner-selftest and ~/.cache/maccleaner-selftest-*, removes them afterwards,
/// and restores the Protected list. Exit code 0 = all passed.
enum SelfTest {
    private static var passed = 0
    private static var failed: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        if ok { passed += 1 } else { failed.append(name) }
        print((ok ? "  ✓ " : "  ✗ ") + name)
    }

    static func run() -> Bool {
        let fm = FileManager.default
        let home = SafetyGuard.home
        let h = { (rel: String) in home.appendingPathComponent(rel) }
        let sandbox = h(".maccleaner-selftest")
        let cacheLink = h(".cache/maccleaner-selftest-link")
        let cacheItem = h(".cache/maccleaner-selftest-item")
        let savedProtected = ProtectedPaths.all
        defer {
            ProtectedPaths.set(savedProtected)
            try? fm.removeItem(at: sandbox)
            try? fm.removeItem(at: cacheLink)
            try? fm.removeItem(at: cacheItem)
        }
        try? fm.createDirectory(at: sandbox.appendingPathComponent("keep/inner"), withIntermediateDirectories: true)
        fm.createFile(atPath: sandbox.appendingPathComponent("keep/inner/file.txt").path, contents: Data("x".utf8))
        fm.createFile(atPath: sandbox.appendingPathComponent("loose.txt").path, contents: Data("x".utf8))
        try? fm.createDirectory(at: cacheItem, withIntermediateDirectories: true)
        try? fm.removeItem(at: cacheLink)
        try? fm.createSymbolicLink(at: cacheLink, withDestinationURL: h("Documents"))

        print("Cache sweep (SafetyGuard — permanent delete)")
        check("allows ~/Library/Caches/<app>", SafetyGuard.isAllowed(h("Library/Caches/com.example.app")))
        check("allows ~/.gradle/caches", SafetyGuard.isAllowed(h(".gradle/caches")))
        check("allows web cache in Application Support", SafetyGuard.isAllowed(h("Library/Application Support/Example/Cache")))
        check("allows sandboxed cache contents", SafetyGuard.isAllowed(h("Library/Containers/com.example.app/Data/Library/Caches/x")))
        check("refuses ~/Library/Caches itself", !SafetyGuard.isAllowed(h("Library/Caches")))
        check("refuses ~/.cache itself", !SafetyGuard.isAllowed(h(".cache")))
        check("refuses app data in Application Support", !SafetyGuard.isAllowed(h("Library/Application Support/Example/Data")))
        check("refuses Apple sandbox caches", !SafetyGuard.isAllowed(h("Library/Containers/com.apple.mail/Data/Library/Caches/x")))
        check("refuses container data outside Caches", !SafetyGuard.isAllowed(h("Library/Containers/com.example.app/Data/Documents")))
        check("refuses ~/Documents", !SafetyGuard.isAllowed(h("Documents/x")))
        check("refuses ~/Downloads", !SafetyGuard.isAllowed(h("Downloads/x")))
        check("refuses ~/.pub-cache/bin (melos)", !SafetyGuard.isAllowed(h(".pub-cache/bin/melos")))
        check("refuses iCloud Drive", !SafetyGuard.isAllowed(h("Library/Mobile Documents/com~apple~CloudDocs/x")))
        check("symlink in a cache root pointing to ~/Documents is refused", !SafetyGuard.isAllowed(cacheLink))
        check("allows a real folder in ~/.cache", SafetyGuard.isAllowed(cacheItem))

        print("Move to Trash (TrashGuard)")
        check("refuses home folder", !TrashGuard.canTrash(home))
        check("refuses ~/Library", !TrashGuard.canTrash(h("Library")))
        check("refuses ~/Documents itself", !TrashGuard.canTrash(h("Documents")))
        check("refuses Keychains", !TrashGuard.canTrash(h("Library/Keychains/login.keychain-db")))
        check("refuses Mail", !TrashGuard.canTrash(h("Library/Mail/V10")))
        check("refuses ~/.ssh", !TrashGuard.canTrash(h(".ssh/id_ed25519")))
        check("refuses /System", !TrashGuard.canTrash(URL(fileURLWithPath: "/System/Library/CoreServices")))
        check("refuses /Users", !TrashGuard.canTrash(URL(fileURLWithPath: "/Users")))
        check("allows a file in your home", TrashGuard.canTrash(sandbox.appendingPathComponent("loose.txt")))
        check("allows an app in /Applications", TrashGuard.canTrash(URL(fileURLWithPath: "/Applications/Example.app")))

        print("Password step (AdminGuard)")
        check("allows a launch daemon plist", AdminGuard.isAllowed(URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.helper.plist")))
        check("allows an audio driver", AdminGuard.isAllowed(URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Example.driver")))
        check("refuses the LaunchDaemons folder itself", !AdminGuard.isAllowed(URL(fileURLWithPath: "/Library/LaunchDaemons")))
        check("refuses Apple items", !AdminGuard.isAllowed(URL(fileURLWithPath: "/Library/LaunchDaemons/com.apple.x.plist")))
        check("refuses nested paths", !AdminGuard.isAllowed(URL(fileURLWithPath: "/Library/Application Support/X/Y")))
        check("refuses non-apps in /Applications", !AdminGuard.isAllowed(URL(fileURLWithPath: "/Applications/Utilities")))
        check("refuses /usr", !AdminGuard.isAllowed(URL(fileURLWithPath: "/usr/local/bin/x")))
        check("refuses /System", !AdminGuard.isAllowed(URL(fileURLWithPath: "/System/Library/Extensions/x.kext")))

        print("Protected folders")
        let keep = sandbox.appendingPathComponent("keep")
        ProtectedPaths.set(savedProtected + [keep.path, cacheItem.path])
        check("protected folder can't be trashed", !TrashGuard.canTrash(keep))
        check("file inside a protected folder can't be trashed", !TrashGuard.canTrash(keep.appendingPathComponent("inner/file.txt")))
        check("parent of a protected folder can't be trashed", !TrashGuard.canTrash(sandbox))
        check("unprotected sibling can still be trashed", TrashGuard.canTrash(sandbox.appendingPathComponent("loose.txt")))
        check("protected cache folder is not swept", !SafetyGuard.isAllowed(cacheItem))
        check("protected path blocked in password step", {
            ProtectedPaths.set(ProtectedPaths.all + ["/Library/LaunchDaemons/com.example.keep.plist"])
            return !AdminGuard.isAllowed(URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.keep.plist"))
        }())
        let keepPreview = (try? MCPServer.call("move_to_trash", ["paths": [keep.path]])) as? [String: Any]
        let mcp = (try? MCPServer.call("move_to_trash", ["paths": [keep.path], "confirm": true,
                                                         "preview_id": keepPreview?["preview_id"] as? String ?? ""])) as? [String: Any]
        check("MCP move_to_trash refuses protected even with an approved confirm",
              (mcp?["moved_to_trash"] as? [String])?.isEmpty == true && fm.fileExists(atPath: keep.path))
        check("Shredder refuses protected (same rule)", ShredEngine.reason(keep) != nil)
        check("existing protected items are still protected", savedProtected.allSatisfy { ProtectedPaths.all.contains($0) })

        print("Trash and Put Back")
        ProtectedPaths.set(savedProtected)
        let rt = sandbox.appendingPathComponent("roundtrip.txt")
        fm.createFile(atPath: rt.path, contents: Data("roundtrip".utf8))
        let trashErr = AppEngine.trash(rt, source: "Self-test")
        let entry = TrashLog.shared.present().first { $0.original == rt.path }
        check("trash moves the file and logs it", trashErr == nil && !fm.fileExists(atPath: rt.path) && entry != nil)
        check("logged item is readable in the Trash", entry.map { fm.fileExists(atPath: $0.trashed) } ?? false)
        if let entry {
            check("put back restores the file", TrashOps.restore(entry) == nil
                  && (try? String(contentsOf: rt, encoding: .utf8)) == "roundtrip")
            check("put back removes the log entry", !TrashLog.shared.present().contains { $0.id == entry.id })
        }
        ProtectedPaths.set(savedProtected + [rt.path])
        check("protected file is refused by trash()", AppEngine.trash(rt, source: "Self-test") != nil && fm.fileExists(atPath: rt.path))
        ProtectedPaths.set(savedProtected)

        print("Projects (build files)")
        let proj = sandbox.appendingPathComponent("proj")
        for d in ["node_modules/pkg", "src", "dist", "build"] {
            try? fm.createDirectory(at: proj.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: proj.appendingPathComponent("package.json").path, contents: Data("{}".utf8))
        fm.createFile(atPath: proj.appendingPathComponent("node_modules/pkg/index.js").path, contents: Data(repeating: 1, count: 5000))
        fm.createFile(atPath: proj.appendingPathComponent("src/app.js").path, contents: Data("code".utf8))
        fm.createFile(atPath: proj.appendingPathComponent("dist/out.js").path, contents: Data(repeating: 1, count: 3000))
        fm.createFile(atPath: proj.appendingPathComponent("build/x.js").path, contents: Data(repeating: 1, count: 3000))
        let flutter = sandbox.appendingPathComponent("fapp")
        try? fm.createDirectory(at: flutter.appendingPathComponent("android/.gradle/x"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: flutter.appendingPathComponent(".dart_tool"), withIntermediateDirectories: true)
        fm.createFile(atPath: flutter.appendingPathComponent("pubspec.yaml").path, contents: Data("name: x".utf8))
        fm.createFile(atPath: flutter.appendingPathComponent("android/build.gradle").path, contents: Data("//".utf8))
        fm.createFile(atPath: flutter.appendingPathComponent(".dart_tool/c").path, contents: Data(repeating: 1, count: 4000))
        fm.createFile(atPath: flutter.appendingPathComponent("android/.gradle/x/f").path, contents: Data(repeating: 1, count: 4000))
        let evil = sandbox.appendingPathComponent("evil")
        try? fm.createDirectory(at: evil, withIntermediateDirectories: true)
        fm.createFile(atPath: evil.appendingPathComponent("package.json").path, contents: Data("{}".utf8))
        try? fm.createSymbolicLink(at: evil.appendingPathComponent("node_modules"), withDestinationURL: h("Documents"))

        let found = ProjectEngine.scan(roots: [sandbox]) { _ in }
        let p = found.first { $0.name == "proj" }
        let f = found.first { $0.name == "fapp" }
        check("finds the Node project", p != nil)
        check("node_modules is a cleanable artifact", p?.artifacts.contains { $0.rel == "node_modules" && !$0.review } == true)
        check("dist is marked REVIEW", p?.artifacts.contains { $0.rel == "dist" && $0.review } == true)
        check("build in a Node-only project is marked REVIEW", p?.artifacts.contains { $0.rel == "build" && $0.review } == true)
        check("source folder is never an artifact", p?.artifacts.contains { $0.rel.hasPrefix("src") } == false)
        check("nested android/.gradle is attributed to the Flutter project",
              f?.artifacts.contains { $0.rel == "android/.gradle" } == true && f?.artifacts.contains { $0.rel == ".dart_tool" } == true)
        check("symlinked node_modules (→ Documents) is not offered", found.first { $0.name == "evil" } == nil)
        if let p, let nm = p.artifacts.first(where: { $0.rel == "node_modules" }) {
            let r = ProjectEngine.clean([(nm, p)]) { _ in }
            check("clean deletes node_modules", r.errors.isEmpty && !fm.fileExists(atPath: nm.url.path))
            check("clean keeps source and package.json", fm.fileExists(atPath: proj.appendingPathComponent("src/app.js").path)
                  && fm.fileExists(atPath: proj.appendingPathComponent("package.json").path))
        }
        if let f, let dt = f.artifacts.first(where: { $0.rel == ".dart_tool" }) {
            ProtectedPaths.set(savedProtected + [flutter.path])
            check("protected project is refused", ProjectEngine.reason(dt, in: f) != nil
                  && ProjectEngine.clean([(dt, f)]) { _ in }.errors.count == 1 && fm.fileExists(atPath: dt.url.path))
            check("protected project is skipped by the scan", !ProjectEngine.scan(roots: [sandbox]) { _ in }.contains { $0.name == "fapp" })
            ProtectedPaths.set(savedProtected)
        }
        check("Documents target of the symlink is untouched", fm.fileExists(atPath: h("Documents").path))

        print("Developer SDKs")
        let sdk = h("Library/Android/sdk")
        check("allows an NDK version folder", SafetyGuard.isAllowed(sdk.appendingPathComponent("ndk/99.0.0")))
        check("allows a build-tools version", SafetyGuard.isAllowed(sdk.appendingPathComponent("build-tools/99.0.0")))
        check("refuses the ndk folder itself", !SafetyGuard.isAllowed(sdk.appendingPathComponent("ndk")))
        check("refuses the Android SDK root", !SafetyGuard.isAllowed(sdk))
        check("refuses platform-tools (adb)", !SafetyGuard.isAllowed(sdk.appendingPathComponent("platform-tools")))
        let outside = SDKItem(id: "x", group: .android, kind: "NDK", name: "fake", detail: "", size: 1,
                              reveal: nil, action: .delete([sandbox.appendingPathComponent("loose.txt")]), regen: "")
        check("SDK delete outside SDK folders is refused", SDKEngine.reason(outside) != nil
              && SDKEngine.remove([outside]).errors.count == 1 && fm.fileExists(atPath: sandbox.appendingPathComponent("loose.txt").path))
        let badDocker = SDKItem(id: "d", group: .docker, kind: "Docker", name: "system", detail: "", size: 0,
                                reveal: nil, action: .docker("system"), regen: "")
        check("only the four fixed Docker prune commands run", SDKEngine.reason(badDocker) != nil)
        check("Docker sizes parse (1.5GB, 512MB (40%), 0B)", SDKEngine.parseDockerSize("1.5GB") == 1_500_000_000
              && SDKEngine.parseDockerSize("512MB (40%)") == 512_000_000 && SDKEngine.parseDockerSize("0B") == 0)
        check("DeviceSupport version is read from the folder name", SDKEngine.versionIn("iPhone15,2 17.5 (21F79)") == "17.5")
        let aproj = sandbox.appendingPathComponent("aproj/app")
        try? fm.createDirectory(at: aproj, withIntermediateDirectories: true)
        try? Data("android {\n compileSdk 35\n ndkVersion \"27.0.1\"\n buildToolsVersion \"34.0.0\"\n}".utf8)
            .write(to: aproj.appendingPathComponent("build.gradle"))
        try? Data("android { compileSdk = 36 }".utf8).write(to: sandbox.appendingPathComponent("aproj/build.gradle.kts"))
        let use = SDKEngine.androidUsage(roots: [sandbox])
        check("reads compileSdk from Groovy and Kotlin Gradle files", use.platforms["35"] == 1 && use.platforms["36"] == 1)
        check("reads ndkVersion and buildToolsVersion", use.ndk["27.0.1"] == 1 && use.buildTools["34.0.0"] == 1)

        print("More developer tools")
        check("allows Cargo registry contents", SafetyGuard.isAllowed(h(".cargo/registry/cache/x")))
        check("allows the Go module cache", SafetyGuard.isAllowed(h("go/pkg/mod/github.com/x")))
        check("refuses ~/.cargo/bin (installed tools)", !SafetyGuard.isAllowed(h(".cargo/bin/rg")))
        check("allows one nvm Node version", SafetyGuard.isAllowed(h(".nvm/versions/node/v18.0.0")))
        check("refuses the nvm versions folder itself", !SafetyGuard.isAllowed(h(".nvm/versions/node")))
        check("refuses pyenv shims", !SafetyGuard.isAllowed(h(".pyenv/shims")))
        check("brew: allows uninstall, cask uninstall and cleanup only",
              SDKEngine.brewArgsValid(["uninstall", "wget"]) && SDKEngine.brewArgsValid(["uninstall", "--cask", "some-app"])
              && SDKEngine.brewArgsValid(["cleanup"]) && SDKEngine.brewArgsValid(["uninstall", "user/tap/tool"]))
        check("brew: refuses other commands, flags and shell text",
              !SDKEngine.brewArgsValid(["install", "x"]) && !SDKEngine.brewArgsValid(["uninstall", "--force", "x"])
              && !SDKEngine.brewArgsValid(["uninstall", "x; rm -rf ~"]) && !SDKEngine.brewArgsValid(["cleanup", "--prune=all"])
              && !SDKEngine.brewArgsValid(["uninstall", "--ignore-dependencies"]))
        check("version files are read (.nvmrc, .tool-versions, rust-toolchain.toml)",
              SDKEngine.runtimeVersions(file: ".nvmrc", text: "v18\n").first! == ("node", "18")
              && SDKEngine.runtimeVersions(file: ".tool-versions", text: "nodejs 20.1.0\npython 3.11.6").count == 2
              && SDKEngine.runtimeVersions(file: "rust-toolchain.toml", text: "[toolchain]\nchannel = \"1.75.0\"").first! == ("rust", "1.75.0"))
        check("versions match by prefix (18 → 18.19.0, not 1)",
              SDKEngine.versionMatches("v18.19.0", "18") && !SDKEngine.versionMatches("18.19.0", "1"))
        let py = sandbox.appendingPathComponent("pyproj"), dn = sandbox.appendingPathComponent("dotnet")
        for d in [py.appendingPathComponent("__pycache__"), py.appendingPathComponent(".pytest_cache"),
                  dn.appendingPathComponent("bin"), dn.appendingPathComponent("obj"), proj.appendingPathComponent("bin")] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            fm.createFile(atPath: d.appendingPathComponent("f").path, contents: Data(repeating: 1, count: 4000))
        }
        fm.createFile(atPath: py.appendingPathComponent("pyproject.toml").path, contents: Data("[x]".utf8))
        fm.createFile(atPath: dn.appendingPathComponent("App.csproj").path, contents: Data("<Project/>".utf8))
        let more = ProjectEngine.scan(roots: [sandbox]) { _ in }
        check("finds Python __pycache__ and .pytest_cache",
              Set(more.first { $0.name == "pyproj" }?.artifacts.map(\.rel) ?? []) == ["__pycache__", ".pytest_cache"])
        check(".NET project found by *.csproj, with bin and obj",
              Set(more.first { $0.name == "dotnet" }?.artifacts.map(\.rel) ?? []) == ["bin", "obj"])
        check("bin in a Node project is not touched", more.first { $0.name == "proj" }?.artifacts.contains { $0.rel == "bin" } != true)
        let ro = cacheItem.appendingPathComponent("readonly/inner")
        try? fm.createDirectory(at: ro, withIntermediateDirectories: true)
        fm.createFile(atPath: ro.appendingPathComponent("f").path, contents: Data("x".utf8))
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.deletingLastPathComponent().path)
        let roTarget = CleanTarget(id: "ro", category: .devCache, name: "read-only", path: ro.path, note: "",
                                   action: .removeItem(ro.deletingLastPathComponent()), sizeBytes: 1, exists: true)
        check("read-only cache folders (like Go modules) can be removed", Cleaner.run([roTarget]).isEmpty
              && !fm.fileExists(atPath: ro.deletingLastPathComponent().path))

        print("System Data")
        let att = h("Library/Messages/Attachments")
        check("a single Messages attachment may be trashed", TrashGuard.canTrash(att.appendingPathComponent("ab/01/GUID/photo.heic")))
        check("the Attachments folder itself is refused", !TrashGuard.canTrash(att))
        check("Messages database is refused", !TrashGuard.canTrash(h("Library/Messages/chat.db")))
        let snapOK = SysItem(id: "s", section: .snapshots, name: "", detail: "", size: nil, reveal: nil, action: .snapshot("2026-11-10-101530"))
        let snapBad = SysItem(id: "b", section: .snapshots, name: "", detail: "", size: nil, reveal: nil, action: .snapshot("2026-11-10; rm -rf ~"))
        check("snapshot dates are validated before tmutil runs", SystemDataEngine.reason(snapOK) == nil && SystemDataEngine.reason(snapBad) != nil)
        check("Mail mailboxes are view only", SystemDataEngine.reason(SysItem(id: "m", section: .mail, name: "", detail: "", size: 1,
                                                                             reveal: nil, action: .none)) != nil)

        print("Automation (safe clean picks)")
        func target(_ id: String, _ c: CacheCategory, _ u: URL, rec: Bool = true) -> CleanTarget {
            CleanTarget(id: id, category: c, name: id, path: u.path, note: "", action: .removeItem(u),
                        recommended: rec, sizeBytes: 100, exists: true)
        }
        let autoCache = h("Library/Caches/com.example.maccleaner-selftest")   // path only, never created
        let picked = AutoClean.select([
            target("ok", .appCaches, autoCache),
            target("notrec", .appCaches, autoCache, rec: false),
            target("trash", .trash, h(".Trash/x")),
            target("dl", .appCaches, h("Downloads/x")),
            target("docs", .appCaches, h("Documents/x")),
        ], running: []).map(\.id)
        check("takes recommended caches", picked.contains("ok"))
        check("skips not-recommended, Trash, Downloads and Documents", picked == ["ok"])
        ProtectedPaths.set(savedProtected + [autoCache.path])
        check("skips protected caches", AutoClean.select([target("ok", .appCaches, autoCache)], running: []).isEmpty)
        ProtectedPaths.set(savedProtected)

        print("Automation (schedule)")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {   // November 2026: the 16th is a Monday
            utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let weekly = AutoSchedule(frequency: .weekly, weekday: 2, hour: 10, minute: 0)   // Mondays 10:00
        let daily = AutoSchedule(frequency: .daily, weekday: 2, hour: 10, minute: 0)
        check("weekly: latest slot is the previous Monday 10:00", weekly.lastSlot(atOrBefore: at(18, 9), calendar: utc) == at(16, 10))
        check("weekly: a slot exactly now counts", weekly.lastSlot(atOrBefore: at(16, 10), calendar: utc) == at(16, 10))
        check("weekly: next slot is the coming Monday", weekly.nextSlot(after: at(18, 9), calendar: utc) == at(23, 10))
        check("daily: next slot later today", daily.nextSlot(after: at(18, 9), calendar: utc) == at(18, 10))
        check("turning it on never runs straight away",
              !weekly.isDue(now: at(18, 9), lastRun: nil, armedAt: at(18, 9), calendar: utc))
        check("runs once the slot passes after turning on",
              weekly.isDue(now: at(23, 10, 1), lastRun: nil, armedAt: at(18, 9), calendar: utc))
        check("asleep at the slot: catches up on wake days later",
              weekly.isDue(now: at(25, 8), lastRun: at(16, 10, 2), armedAt: at(1, 0), calendar: utc))
        check("never twice for one slot",
              !weekly.isDue(now: at(23, 18), lastRun: at(23, 10, 2), armedAt: at(1, 0), calendar: utc))
        check("changing the schedule after the slot waits for the next one",
              !daily.isDue(now: at(18, 11), lastRun: at(10, 10), armedAt: at(18, 10, 30), calendar: utc))
        check("daily: due again the next day", daily.isDue(now: at(19, 10, 5), lastRun: at(18, 10, 1), armedAt: at(1, 0), calendar: utc))

        print("Settings migration (old app ID)")
        let oldName = "maccleaner.selftest.old", newName = "maccleaner.selftest.new"
        UserDefaults.standard.setPersistentDomain([ProtectedPaths.key: ["/a/keep", "/b/keep"], "appearance": "dark",
                                                   "NSWindow Frame x": "1"], forName: oldName)
        UserDefaults.standard.removePersistentDomain(forName: newName)
        if let target = UserDefaults(suiteName: newName) {
            target.set(["/c/mine"], forKey: ProtectedPaths.key)
            target.set("light", forKey: "appearance")
            SettingsMigration.migrate(fromDomain: oldName, to: target)
            check("protected paths are merged, none dropped",
                  Set(target.stringArray(forKey: ProtectedPaths.key) ?? []) == ["/a/keep", "/b/keep", "/c/mine"])
            check("settings already set under the new ID win", target.string(forKey: "appearance") == "light")
            check("system window keys are not copied", target.object(forKey: "NSWindow Frame x") == nil)
            target.removeObject(forKey: ProtectedPaths.key)
            check("runs only once", SettingsMigration.migrate(fromDomain: oldName, to: target) == 0
                  && target.stringArray(forKey: ProtectedPaths.key) == nil)
        } else {
            check("test settings domain available", false)
        }
        UserDefaults.standard.removePersistentDomain(forName: oldName)
        UserDefaults.standard.removePersistentDomain(forName: newName)

        print("Insights")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day = { (n: Int) in cal.date(byAdding: .day, value: n, to: today)! }
        let gb: Int64 = 1_000_000_000
        typealias FS = FreeSpaceLog.Sample
        var log = FreeSpaceLog.merged([], FS(day: today, free: 10 * gb, total: 100 * gb), now: Date())
        log = FreeSpaceLog.merged(log, FS(day: today, free: 12 * gb, total: 100 * gb), now: Date())
        check("one free-space reading per day, newest wins", log.count == 1 && log[0].free == 12 * gb)
        log = FreeSpaceLog.merged([FS(day: day(-120), free: gb, total: 100 * gb)], FS(day: today, free: gb, total: 100 * gb), now: Date())
        check("readings older than 90 days are dropped", log.count == 1 && log[0].day == today)
        let shrinking = (0..<5).map { FS(day: day($0 - 4), free: (50 - Int64($0)) * gb, total: 100 * gb) }
        let eta = FreeSpaceLog.daysUntil(20 * gb, samples: shrinking)
        check("forecast: 1 GB a day from 46 GB reaches 20 GB in 26 days", eta.map { abs($0 - 26) < 0.01 } ?? false)
        let growing = (0..<5).map { FS(day: day($0 - 4), free: (40 + Int64($0)) * gb, total: 100 * gb) }
        check("no forecast while free space grows", FreeSpaceLog.daysUntil(20 * gb, samples: growing) == nil)
        check("no forecast from two readings", FreeSpaceLog.daysUntil(20 * gb, samples: Array(shrinking.suffix(2))) == nil)
        let below = shrinking.map { FS(day: $0.day, free: $0.free - 40 * gb, total: $0.total) }
        check("forecast is 0 when already below the alert", FreeSpaceLog.daysUntil(20 * gb, samples: below) == 0)
        let recs = [CleanupRecord(date: Date(), title: "a", bytes: 3 * gb, symbol: "x", outcome: .deleted),
                    CleanupRecord(date: Date(), title: "b", bytes: gb, symbol: "x", outcome: .trashed),
                    CleanupRecord(date: cal.date(byAdding: .weekOfYear, value: -3, to: Date())!, title: "c", bytes: 2 * gb, symbol: "x"),
                    CleanupRecord(date: cal.date(byAdding: .weekOfYear, value: -20, to: Date())!, title: "d", bytes: 9 * gb, symbol: "x", outcome: .deleted)]
        let weeks = InsightMath.weeks(recs, count: 8)
        check("8 weeks, oldest first, empty weeks kept", weeks.count == 8 && weeks.first!.start < weeks.last!.start)
        check("this week splits deleted and trashed", weeks.last!.deleted == 3 * gb && weeks.last!.trashed == gb)
        check("older records count as deleted; weeks outside the range are left out",
              weeks.reduce(0) { $0 + $1.deleted } == 5 * gb)
        check("menu bar forecast wording",
              InsightMath.shortForecast(days: 26, limit: 20 * gb, sampleCount: 5) == "Reaches 20 GB in about 4 weeks"
              && InsightMath.shortForecast(days: nil, limit: 20 * gb, sampleCount: 1) == "Forecast: ready after a few days"
              && InsightMath.shortForecast(days: nil, limit: 20 * gb, sampleCount: 9) == "Free space is steady"
              && InsightMath.shortForecast(days: 0, limit: 20 * gb, sampleCount: 9) == "Below your 20 GB alert")
        check("forecast wording", InsightMath.durationText(days: 26) == "about 4 weeks"
              && InsightMath.durationText(days: 1) == "about 1 day" && InsightMath.durationText(days: 0.4) == "less than a day")

        print("Fast scanning (DirSize, Storage Map, duplicates)")
        let fx = sandbox.appendingPathComponent("sizes")
        try? fm.createDirectory(at: fx.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: fx.appendingPathComponent("Thing.app/Contents"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: fx.appendingPathComponent("many"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: fx.appendingPathComponent("empty"), withIntermediateDirectories: true)
        fm.createFile(atPath: fx.appendingPathComponent("a/b/c/deep.bin").path, contents: Data(count: 300_000))
        fm.createFile(atPath: fx.appendingPathComponent("a/.hidden").path, contents: Data(count: 5_000))
        fm.createFile(atPath: fx.appendingPathComponent("Thing.app/Contents/inside").path, contents: Data(count: 70_000))
        fm.createFile(atPath: fx.appendingPathComponent("big.bin").path, contents: Data(count: 1_500_000))
        fm.createFile(atPath: fx.appendingPathComponent("a/._deep.bin").path, contents: Data(count: 8_192))  // AppleDouble: FileManager skips it
        try? fm.createDirectory(at: fx.appendingPathComponent("._folder"), withIntermediateDirectories: true)
        fm.createFile(atPath: fx.appendingPathComponent("._folder/inside").path, contents: Data(count: 20_000))  // but not this
        for i in 0..<5000 {   // more entries than one getattrlistbulk batch
            fm.createFile(atPath: fx.appendingPathComponent("many/f\(i)").path, contents: Data(count: 10))
        }
        let nfc = "F\u{00FC}hrung \u{00E9}t\u{00E9}"   // precomposed ü and é, as most apps save them
        let nfcFile = open(fx.path + "/a/" + nfc, O_CREAT | O_WRONLY | O_TRUNC, 0o644)   // raw bytes, no conversion
        if nfcFile >= 0 { _ = [UInt8](repeating: 1, count: 1_200_000).withUnsafeBytes { write(nfcFile, $0.baseAddress, $0.count) }; close(nfcFile) }
        // Also open it once by its decomposed spelling, as some apps do. The scan must still give the stored spelling.
        let nfdFile = open(fx.path + "/a/" + nfc.decomposedStringWithCanonicalMapping, O_RDONLY)
        if nfdFile >= 0 { close(nfdFile) }
        try? fm.createSymbolicLink(at: fx.appendingPathComponent("link-to-dir"), withDestinationURL: h("Library"))
        try? fm.createSymbolicLink(at: fx.appendingPathComponent("link-to-file"), withDestinationURL: fx.appendingPathComponent("big.bin"))
        let fast = Scanner.allocatedSize(fx), slow = Scanner.allocatedSizeSlow(fx)
        check("DirSize matches the FileManager walk byte for byte", fast == slow && fast >= 3_075_000)
        check("DirSize does not follow a symlink to ~/Library", fast < 3_075_000 + 5_000 * 4096 + 1_000_000)
        check("DirSize of a missing folder is 0", Scanner.allocatedSize(fx.appendingPathComponent("nope")) == 0)
        check("DirSize of a file is its own size", Scanner.allocatedSize(fx.appendingPathComponent("big.bin"))
              == Scanner.allocatedSizeSlow(fx.appendingPathComponent("big.bin")))
        let map = DiskScanner.scan(root: fx, counter: DiskScanner.Counter { _ in })
        check("Storage Map counts every file once and skips symlinks", map.fileCount == 5006)
        let listed = map.children.first { $0.name == "a" }?.children.first { $0.size >= 1_000_000 }
        let reference = (try? fm.contentsOfDirectory(at: fx.appendingPathComponent("a"), includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent == nfc }   // what the FileManager walk reported for the same file
        let nameOK = listed.map { Array($0.name.utf8) == Array(nfc.utf8) } ?? false
        let pathOK = listed.map { Array($0.url.path.utf8) == Array((reference?.path ?? "").utf8) } ?? false
        check("Storage Map keeps a non-ASCII name exactly as stored", nameOK && pathOK)
        if !(nameOK && pathOK) {
            let form = { (t: String?) -> String in
                guard let t else { return "missing" }
                return t == t.precomposedStringWithCanonicalMapping && Array(t.utf8) == Array(t.precomposedStringWithCanonicalMapping.utf8) ? "NFC" : "NFD"
            }
            print("    name \(form(listed?.name)), path \(form(listed?.url.path)), FileManager path \(form(reference?.path))")
        }
        check("Storage Map lists a 1.5 MB file with its date",
              map.children.contains { $0.name == "big.bin" && !$0.isDirectory && $0.modified != nil && $0.size >= 1_500_000 })
        check("Storage Map total matches its children",
              map.size == map.children.reduce(0) { $0 + $1.size } && map.size <= slow)

        // Size cache: a repeat within a minute is served from memory; any deletion by the app clears it.
        let cx = fx.appendingPathComponent("a/b")
        let before = Scanner.allocatedSize(cx)
        fm.createFile(atPath: cx.appendingPathComponent("added.bin").path, contents: Data(count: 400_000))
        check("size cache: a repeat measurement within a minute is reused", Scanner.allocatedSize(cx) == before)
        let gone = cacheItem.appendingPathComponent("size-cache-check")
        try? fm.createDirectory(at: gone, withIntermediateDirectories: true)
        let goneTarget = CleanTarget(id: "sc", category: .devCache, name: "size cache", path: gone.path, note: "",
                                     action: .removeItem(gone), sizeBytes: 1, exists: true)
        check("size cache: cleared when the app deletes something",
              Cleaner.run([goneTarget]).isEmpty && Scanner.allocatedSize(cx) >= before + 400_000)

        let racedGeneration = SizeCache.generation
        SizeCache.clear()      // the app deletes something while a walk is still running
        SizeCache.put(cx.path + "/race", 1, generation: racedGeneration)
        check("size cache: a walk that overlaps a deletion is not stored", SizeCache.get(cx.path + "/race") == nil)

        // Several walks at once on the shared threads, one of them cancelled: the others still get exact sizes.
        let cancelled = DiskScanner.Counter { _ in }
        cancelled.cancel()
        let expected = Scanner.allocatedSizeSlow(fx)     // fx grew in the size cache checks above
        var concurrent = [Int64](repeating: -1, count: 6)
        concurrent.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: 6) { i in
                if i == 0 { _ = DiskScanner.scan(root: fx, counter: cancelled); buf[i] = expected; return }
                buf[i] = DirSize.measure(atPath: fx.path).bytes
            }
        }
        check("walks running at the same time (one cancelled) each get the exact size", concurrent.allSatisfy { $0 == expected })

        let dx = sandbox.appendingPathComponent("dups")
        try? fm.createDirectory(at: dx.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let same = Data((0..<400_000).map { UInt8($0 % 251) })
        var lookalike = same; lookalike[200_000] ^= 0xff     // same size, same first/last 64 KB, different middle
        for p in ["one", "two", "sub/three"] { fm.createFile(atPath: dx.appendingPathComponent(p).path, contents: same) }
        fm.createFile(atPath: dx.appendingPathComponent("other").path, contents: lookalike)
        try? fm.linkItem(at: dx.appendingPathComponent("one"), to: dx.appendingPathComponent("hardlink"))
        let groups = DupEngine.run(roots: [dx], minSize: 1, cancel: DupEngine.Cancel()) { _ in }
        check("duplicates: one group of three, hard link and look-alike left out",
              groups.count == 1 && groups[0].files.count == 3 && !groups[0].files.contains { $0.lastPathComponent == "other" })

        print("Updates")
        check("version order: 1.10.0 > 1.9.2, 1.2.1 > 1.2, v1.3.0 > 1.3.0-beta",
              Updater.isNewer("1.10.0", than: "1.9.2") && Updater.isNewer("1.2.1", than: "1.2")
              && Updater.isNewer("v1.3.0", than: "1.3.0-beta"))
        check("no update to the same, an older or a pre-release version",
              !Updater.isNewer("1.2.0", than: "1.2") && !Updater.isNewer("1.1.9", than: "1.2.0")
              && !Updater.isNewer("1.2.0-beta", than: "1.2.0"))
        func releaseJSON(prerelease: Bool = false, dmgHost: String = "github.com") -> Data {
            let base = "https://\(dmgHost)/WahdanZ/MacCleaner/releases/download/v1.3.0/"
            return Data("""
            {"tag_name":"v1.3.0","draft":false,"prerelease":\(prerelease),"body":"## What's new\\n- faster",
             "html_url":"https://github.com/WahdanZ/MacCleaner/releases/tag/v1.3.0",
             "assets":[{"name":"MacCleaner-1.3.0.dmg","size":5700000,"browser_download_url":"\(base)MacCleaner-1.3.0.dmg"},
                       {"name":"MacCleaner-1.3.0.dmg.sha256","size":90,"browser_download_url":"\(base)MacCleaner-1.3.0.dmg.sha256"},
                       {"name":"MacCleaner-1.3.0.dmg.sig","size":90,"browser_download_url":"\(base)MacCleaner-1.3.0.dmg.sig"}]}
            """.utf8)
        }
        let rel = Updater.parseRelease(releaseJSON())
        check("reads the release: version, DMG, checksum and size",
              rel?.version == "1.3.0" && rel?.dmg.lastPathComponent == "MacCleaner-1.3.0.dmg"
              && rel?.checksum?.lastPathComponent == "MacCleaner-1.3.0.dmg.sha256" && rel?.size == 5_700_000
              && rel?.signature?.lastPathComponent == "MacCleaner-1.3.0.dmg.sig")
        check("ignores downloads that aren't on github.com", Updater.parseRelease(releaseJSON(dmgHost: "example.com")) == nil)
        check("ignores drafts and pre-releases", Updater.parseRelease(releaseJSON(prerelease: true)) == nil)
        let hash = String(repeating: "ab", count: 32)
        check("reads a shasum line; rejects anything else",
              Updater.parseChecksum("\(hash)  MacCleaner-1.3.0.dmg\n") == hash
              && Updater.parseChecksum("not a hash") == nil && Updater.parseChecksum("") == nil)
        check("Developer ID team from codesign; none for ad-hoc",
              Updater.parseTeamID("Identifier=x\nTeamIdentifier=ABCDE12345\n") == "ABCDE12345"
              && Updater.parseTeamID("TeamIdentifier=not set\n") == nil && Updater.parseTeamID(nil) == nil)
        let sumFile = sandbox.appendingPathComponent("sum.bin")
        fm.createFile(atPath: sumFile.path, contents: Data("abc".utf8))
        check("SHA-256 of a file", (try? Updater.sha256(of: sumFile))
              == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // The swap script, on throwaway apps: the new copy replaces the old one and nothing is left behind.
        let apps = sandbox.appendingPathComponent("apps"), work = sandbox.appendingPathComponent("MacCleaner-update-test")
        let oldApp = apps.appendingPathComponent("Test.app"), newApp = work.appendingPathComponent("Test.app")
        try? fm.createDirectory(at: oldApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: newApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        fm.createFile(atPath: oldApp.appendingPathComponent("Contents/old").path, contents: Data())
        fm.createFile(atPath: newApp.appendingPathComponent("Contents/new").path, contents: Data())
        let script = sandbox.appendingPathComponent("swap.sh")
        try? Updater.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let swap = Shell.run("/bin/sh", [script.path, "2147483647", oldApp.path, newApp.path, work.path, "0"], timeout: 60)
        let left = (try? fm.contentsOfDirectory(atPath: apps.path)) ?? []
        check("update swap: new app in place, old copy and download folder removed",
              swap.status == 0 && fm.fileExists(atPath: oldApp.appendingPathComponent("Contents/new").path)
              && !fm.fileExists(atPath: oldApp.appendingPathComponent("Contents/old").path)
              && left == ["Test.app"] && !fm.fileExists(atPath: work.path))

        print("Audit fixes: paths with other letter case or through links (Trash)")
        check("Trash refuses ~/documents, ~/library and ~/DOCUMENTS",
              !TrashGuard.canTrash(h("documents")) && !TrashGuard.canTrash(h("library")) && !TrashGuard.canTrash(h("DOCUMENTS")))
        check("Trash refuses ~/library/keychains/x and ~/.SSH/x",
              !TrashGuard.canTrash(h("library/keychains/x")) && !TrashGuard.canTrash(h(".SSH/id_x")))
        let keysLink = sandbox.appendingPathComponent("keys-link")
        try? fm.createSymbolicLink(at: keysLink, withDestinationURL: h("Library/Keychains"))
        check("Trash refuses a file reached through a linked folder", !TrashGuard.canTrash(keysLink.appendingPathComponent("x")))
        check("Trash still allows the link itself (only the link moves)", TrashGuard.canTrash(keysLink))
        ProtectedPaths.set([sandbox.appendingPathComponent("keep").path])
        check("protected folder matched in any letter case",
              !TrashGuard.canTrash(sandbox.appendingPathComponent("KEEP/inner/file.txt")))
        ProtectedPaths.set(savedProtected)

        print("Audit fixes: weekly clean scope")
        func cmdTarget(_ action: CleanAction) -> CleanTarget {
            CleanTarget(id: "cmd", category: .xcode, name: "cmd", path: "", note: "", action: action,
                        recommended: true, sizeBytes: 100, exists: true)
        }
        check("weekly clean never runs simulator commands",
              AutoClean.select([cmdTarget(.deleteUnavailableSimulators), cmdTarget(.deleteSimRuntime("x"))]).isEmpty)
        check("weekly clean refuses a target with no paths", AutoClean.select([cmdTarget(.removeItems([]))]).isEmpty)

        print("Audit fixes: AI assistant approvals (MCP)")
        let mA = sandbox.appendingPathComponent("mcp-a.txt"), mB = sandbox.appendingPathComponent("mcp-b.txt")
        fm.createFile(atPath: mA.path, contents: Data("a".utf8))
        fm.createFile(atPath: mB.path, contents: Data("b".utf8))
        let bothThere = { fm.fileExists(atPath: mA.path) && fm.fileExists(atPath: mB.path) }
        check("confirm without a preview_id is refused, nothing moved",
              (try? MCPServer.call("move_to_trash", ["paths": [mA.path], "confirm": true])) == nil && bothThere())
        let pv = (try? MCPServer.call("move_to_trash", ["paths": [mA.path]])) as? [String: Any]
        let pid = pv?["preview_id"] as? String ?? ""
        check("a preview returns a preview_id", !pid.isEmpty)
        check("confirming a different list than the preview is refused",
              (try? MCPServer.call("move_to_trash", ["paths": [mA.path, mB.path], "confirm": true, "preview_id": pid])) == nil && bothThere())
        check("a preview_id works once",
              (try? MCPServer.call("move_to_trash", ["paths": [mA.path], "confirm": true, "preview_id": pid])) == nil && bothThere())
        let okID = MCPServer.issuePreview("clean_caches", "plan")
        check("matching tool and plan is approved", (try? MCPServer.approve("clean_caches", "plan", ["preview_id": okID])) != nil)
        let otherTool = MCPServer.issuePreview("clean_caches", "plan")
        check("a preview_id from another tool is refused",
              (try? MCPServer.approve("empty_trash", "plan", ["preview_id": otherTool])) == nil)
        let old = MCPServer.issuePreview("clean_caches", "plan", now: Date().addingTimeInterval(-MCPServer.previewLifetime - 1))
        check("an expired preview_id is refused", (try? MCPServer.approve("clean_caches", "plan", ["preview_id": old])) == nil)

        print("MCP: the person approves in Mac Cleaner's own window, for the exact files (SAFE-03)")
        let hA = sandbox.appendingPathComponent("mcp-human.txt")
        fm.createFile(atPath: hA.path, contents: Data("h".utf8))
        approvals.asked = []; approvals.answer = false
        let hPreview = (try? MCPServer.call("move_to_trash", ["paths": [hA.path]])) as? [String: Any]
        let hID = hPreview?["preview_id"] as? String ?? ""
        let declined = (try? MCPServer.call("move_to_trash", ["paths": [hA.path], "confirm": true, "preview_id": hID])) == nil
        check("an AI confirm the person declines in Mac Cleaner's window changes nothing",
              declined && fm.fileExists(atPath: hA.path) && approvals.asked.count == 1)
        check("the window lists exactly the previewed item, with Mac Cleaner's own wording",
              approvals.asked.first?.verb == "Move to Trash"
              && approvals.asked.first?.lines.contains { $0.contains("mcp-human.txt") } == true)
        check("a declined preview can't be confirmed again",
              (try? MCPServer.call("move_to_trash", ["paths": [hA.path], "confirm": true, "preview_id": hID])) == nil
              && fm.fileExists(atPath: hA.path))
        // A path that doesn't exist: the call goes through (and is skipped) without touching the real Trash.
        let ghost = sandbox.appendingPathComponent("mcp-ghost.txt").path
        approvals.asked = []; approvals.answer = true
        let gID = ((try? MCPServer.call("move_to_trash", ["paths": [ghost]])) as? [String: Any])?["preview_id"] as? String ?? ""
        check("an AI confirm the person approves goes ahead",
              (try? MCPServer.call("move_to_trash", ["paths": [ghost], "confirm": true, "preview_id": gID])) != nil
              && approvals.asked.count == 1)
        approvals.asked = []; approvals.answer = false
        let tID = ((try? MCPServer.call("move_to_trash", ["paths": [ghost]])) as? [String: Any])?["preview_id"] as? String ?? ""
        check("a CLI confirm (the person said yes at the terminal) needs no second window",
              (try? MCPServer.call("move_to_trash", ["paths": [ghost], "confirm": true, "preview_id": tID], approval: .terminal)) != nil
              && approvals.asked.isEmpty)
        // Same path, different file: replaced (new inode) or edited (size/time) between preview and confirm.
        approvals.asked = []; approvals.answer = true
        let hR = sandbox.appendingPathComponent("mcp-replaced.txt")
        fm.createFile(atPath: hR.path, contents: Data("v1".utf8))
        let rID = ((try? MCPServer.call("move_to_trash", ["paths": [hR.path]])) as? [String: Any])?["preview_id"] as? String ?? ""
        try? fm.removeItem(at: hR)
        fm.createFile(atPath: hR.path, contents: Data("v2".utf8))
        check("a file replaced at the same path after the preview is refused before anyone is asked",
              (try? MCPServer.call("move_to_trash", ["paths": [hR.path], "confirm": true, "preview_id": rID])) == nil
              && (try? String(contentsOf: hR, encoding: .utf8)) == "v2" && approvals.asked.isEmpty)
        let eID = ((try? MCPServer.call("move_to_trash", ["paths": [hR.path]])) as? [String: Any])?["preview_id"] as? String ?? ""
        if let fh = try? FileHandle(forWritingTo: hR) { fh.seekToEndOfFile(); fh.write(Data("more".utf8)); try? fh.close() }
        check("a file edited after the preview is refused",
              (try? MCPServer.call("move_to_trash", ["paths": [hR.path], "confirm": true, "preview_id": eID])) == nil
              && fm.fileExists(atPath: hR.path) && approvals.asked.isEmpty)
        let idDir = sandbox.appendingPathComponent("mcp-dir")
        try? fm.createDirectory(at: idDir, withIntermediateDirectories: true)
        let dirBefore = MCPServer.identity(idDir.path)
        fm.createFile(atPath: idDir.appendingPathComponent("new.txt").path, contents: Data("x".utf8))
        check("a folder keeps its identity when files inside change (its contents are re-checked when run)",
              MCPServer.identity(idDir.path) == dirBefore && dirBefore != MCPServer.identity(hR.path)
              && MCPServer.identity(sandbox.appendingPathComponent("nope").path).hasSuffix("|missing"))
        // The real window is never shown off the main thread (or without a screen): it answers no.
        var offMain = true
        let done = DispatchSemaphore(value: 0)
        Thread {
            offMain = HumanApproval.askWithDialog(ApprovalRequest(tool: "move_to_trash", verb: "Move to Trash", lines: []))
            done.signal()
        }.start()
        done.wait()
        check("the confirmation window answers no when it can't be shown (not on the main thread)", !offMain)

        print("MCP empty_trash deletes exactly the reviewed items (SAFE-03)")
        let fakeTrash = sandbox.appendingPathComponent("fake-trash")
        try? fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let tA = fakeTrash.appendingPathComponent("a.txt"), tB = fakeTrash.appendingPathComponent("b.txt")
        let tLink = fakeTrash.appendingPathComponent("link"), tOut = sandbox.appendingPathComponent("trash-outside.txt")
        let tElsewhere = sandbox.appendingPathComponent("not-in-trash.txt")
        for f in [tA, tB, tOut, tElsewhere] { fm.createFile(atPath: f.path, contents: Data("x".utf8)) }
        try? fm.createSymbolicLink(at: tLink, withDestinationURL: tOut)
        let reviewed = [tA, tB, tLink, tElsewhere].map { TrashOps.snapshot($0.path) }
        try? fm.removeItem(at: tB); fm.createFile(atPath: tB.path, contents: Data("new".utf8))     // replaced after review
        let tLate = fakeTrash.appendingPathComponent("late.txt")
        fm.createFile(atPath: tLate.path, contents: Data("late".utf8))                             // added after review
        let del = TrashOps.deleteApproved(reviewed, trashFolders: [fakeTrash.path])
        check("only reviewed, unchanged items directly in a Trash folder are deleted",
              del.deleted.sorted() == [tA.path, tLink.path].sorted() && !fm.fileExists(atPath: tA.path))
        check("a replaced item, an item added later and a path outside the Trash all stay",
              (try? String(contentsOf: tB, encoding: .utf8)) == "new" && fm.fileExists(atPath: tLate.path)
              && fm.fileExists(atPath: tElsewhere.path) && del.kept.count == 2)
        check("a link in the Trash is deleted as a link; its target stays", fm.fileExists(atPath: tOut.path))
        // A folder in the Trash: approved with exactly its contents.
        func trashFolder(_ name: String) -> URL {
            let d = fakeTrash.appendingPathComponent(name)
            try? fm.createDirectory(at: d.appendingPathComponent("sub"), withIntermediateDirectories: true)
            fm.createFile(atPath: d.appendingPathComponent("a.txt").path, contents: Data("a".utf8))
            fm.createFile(atPath: d.appendingPathComponent("sub/b.txt").path, contents: Data("b".utf8))
            return d
        }
        let fNew = trashFolder("folder-added")
        let fNewSnap = TrashOps.snapshot(fNew.path)
        fm.createFile(atPath: fNew.appendingPathComponent("sub/new.txt").path, contents: Data("new".utf8))
        let rNew = TrashOps.deleteApproved([fNewSnap], trashFolders: [fakeTrash.path])
        check("a Trash folder with a file added inside after the review is kept whole",
              rNew.deleted.isEmpty && rNew.kept.count == 1 && fm.fileExists(atPath: fNew.appendingPathComponent("a.txt").path)
              && fm.fileExists(atPath: fNew.appendingPathComponent("sub/new.txt").path))
        check("…and its preview digest differs, so an MCP confirm would be refused", TrashOps.snapshot(fNew.path).digest != fNewSnap.digest)
        // Files added inside while it is being deleted: only reviewed entries go; the new files and their folders stay.
        let fRace = trashFolder("folder-race")
        let rRace = TrashOps.deleteApproved([TrashOps.snapshot(fRace.path)], trashFolders: [fakeTrash.path]) { p in
            fm.createFile(atPath: URL(fileURLWithPath: p).appendingPathComponent("sub/late.txt").path, contents: Data("late".utf8))
        }
        check("files added inside during the delete stay, with their folders; the result says 'partly deleted'",
              rRace.deleted.isEmpty && rRace.partial.count == 1
              && fm.fileExists(atPath: fRace.appendingPathComponent("sub/late.txt").path)
              && !fm.fileExists(atPath: fRace.appendingPathComponent("sub/b.txt").path))
        let fWhole = trashFolder("folder-whole")
        try? fm.createSymbolicLink(at: fWhole.appendingPathComponent("sub/link"), withDestinationURL: tOut)
        let rWhole = TrashOps.deleteApproved([TrashOps.snapshot(fWhole.path)], trashFolders: [fakeTrash.path])
        check("an unchanged Trash folder is deleted completely; a link inside is removed, its target stays",
              rWhole.deleted == [fWhole.path] && !fm.fileExists(atPath: fWhole.path) && fm.fileExists(atPath: tOut.path))
        let fLocked = trashFolder("folder-unreadable")
        chmod(fLocked.appendingPathComponent("sub").path, 0)
        let lockedSnap = TrashOps.snapshot(fLocked.path)
        let rLocked = TrashOps.deleteApproved([lockedSnap], trashFolders: [fakeTrash.path])
        chmod(fLocked.appendingPathComponent("sub").path, 0o755)
        check("a Trash folder with an unreadable part is never deleted", lockedSnap.entries == nil && rLocked.deleted.isEmpty
              && fm.fileExists(atPath: fLocked.appendingPathComponent("sub/b.txt").path))
        let lockedTrash = sandbox.appendingPathComponent("locked-trash")
        try? fm.createDirectory(at: lockedTrash, withIntermediateDirectories: true)
        chmod(lockedTrash.path, 0)
        let listing = TrashOps.listAll(in: [fakeTrash, lockedTrash])
        chmod(lockedTrash.path, 0o755)
        check("a Trash folder that can't be read is reported, never treated as empty",
              listing.unreadable == [lockedTrash.path] && listing.items.contains(tLate.path))
        // Volumes: one with a Trash, one without, one whose Trash can't be checked.
        let volA = sandbox.appendingPathComponent("vol-a"), volB = sandbox.appendingPathComponent("vol-b"),
            volC = sandbox.appendingPathComponent("vol-c")
        try? fm.createDirectory(at: volA.appendingPathComponent(".Trashes/\(getuid())"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: volB, withIntermediateDirectories: true)
        try? fm.createDirectory(at: volC.appendingPathComponent(".Trashes/\(getuid())"), withIntermediateDirectories: true)
        chmod(volC.appendingPathComponent(".Trashes").path, 0)
        let cover = TrashOps.locationsReport(volumes: [volA, volB, volC])
        chmod(volC.appendingPathComponent(".Trashes").path, 0o755)
        check("Trash discovery: a volume's Trash is found; no Trash is fine; one that can't be checked is reported",
              cover.folders.map(\.path) == [TrashOps.trashURL.path, volA.appendingPathComponent(".Trashes/\(getuid())").path]
              && cover.problems.count == 1 && cover.problems[0].hasPrefix(volC.path))
        check("Trash folders include the home Trash", TrashOps.locations().first == TrashOps.trashURL)
        if ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil {
            // Only in a throwaway home: fill its Trash with 600 items and check the person's window lists all of them.
            let homeTrash = TrashOps.trashURL
            try? fm.createDirectory(at: homeTrash, withIntermediateDirectories: true)
            let many = (0..<600).map { homeTrash.appendingPathComponent(String(format: "selftest-%03d.txt", $0)) }
            for f in many { fm.createFile(atPath: f.path, contents: Data("t".utf8)) }
            approvals.asked = []; approvals.answer = false
            let tp = (try? MCPServer.call("empty_trash", [:])) as? [String: Any]
            _ = try? MCPServer.call("empty_trash", ["confirm": true, "preview_id": tp?["preview_id"] as? String ?? ""])
            let shownLines = approvals.asked.first?.lines ?? []
            check("a large Trash: the JSON lists 500 and says how many more; the window lists every item",
                  (tp?["listed"] as? [String])?.count == 500 && (tp?["listed_more"] as? Int).map { $0 >= 100 } == true
                  && many.allSatisfy { f in shownLines.contains { $0.contains(f.lastPathComponent) } })
            check("declined: nothing was deleted from the Trash", many.allSatisfy { fm.fileExists(atPath: $0.path) })
            many.forEach { try? fm.removeItem(at: $0) }
        } else {
            print("  – skipped (needs a throwaway home): large Trash listing in the approval window")
        }
        approvals.asked = []; approvals.answer = true

        print("Audit fixes: Shredder")
        func shredDir(_ name: String, file: String = "f.txt", text: String = "secret") -> (URL, URL) {
            let d = sandbox.appendingPathComponent(name), f = d.appendingPathComponent(file)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            fm.createFile(atPath: f.path, contents: Data(text.utf8))
            return (d, f)
        }
        let (dA, fA) = shredDir("shred-links", text: "keep")
        let other = sandbox.appendingPathComponent("shred-other-link.txt")
        try? fm.linkItem(at: fA, to: other)
        let rA = ShredEngine.shred(dA)
        check("refuses a folder holding a hard link; the other copy is untouched",
              rA.refused != nil && fm.fileExists(atPath: dA.path)
              && (try? String(contentsOf: other, encoding: .utf8)) == "keep")
        let (dB, fB) = shredDir("shred-protected")
        ProtectedPaths.set([fB.path])
        check("re-checks protection right before shredding", ShredEngine.shred(dB).refused != nil && fm.fileExists(atPath: fB.path))
        ProtectedPaths.set(savedProtected)
        let (dC, fC) = shredDir("shred-locked")
        try? fm.setAttributes([.immutable: true], ofItemAtPath: fC.path)
        check("refuses a locked file instead of calling it shredded", ShredEngine.shred(dC).refused != nil && fm.fileExists(atPath: fC.path))
        try? fm.setAttributes([.immutable: false], ofItemAtPath: fC.path)
        let (dD, _) = shredDir("shred-normal")
        let rD = ShredEngine.shred(dD)
        check("overwrites and deletes a normal folder", rD.removed && rD.overwritten == 1 && rD.notOverwritten.isEmpty
              && !fm.fileExists(atPath: dD.path))
        check("refuses items outside the home folder",
              ShredEngine.reason(URL(fileURLWithPath: "/private/tmp/x")) != nil
              && ShredEngine.reason(URL(fileURLWithPath: "/Applications/Example.app")) != nil)

        print("Audit fixes: update signatures")
        let signer = Curve25519.Signing.PrivateKey()
        let pub = signer.publicKey.rawRepresentation.base64EncodedString()
        let blob = Data("disk image bytes".utf8)
        let goodSig = Data(((try? signer.signature(for: blob)) ?? Data()).base64EncodedString().utf8)
        let strangerSig = Data(((try? Curve25519.Signing.PrivateKey().signature(for: blob)) ?? Data()).base64EncodedString().utf8)
        check("a signature by the release key is accepted", Updater.verifySignature(of: blob, signature: goodSig, publicKey: pub))
        check("a changed download, another key or junk is refused",
              !Updater.verifySignature(of: blob + Data([0]), signature: goodSig, publicKey: pub)
              && !Updater.verifySignature(of: blob, signature: strangerSig, publicKey: pub)
              && !Updater.verifySignature(of: blob, signature: Data("junk".utf8), publicKey: pub)
              && !Updater.verifySignature(of: blob, signature: goodSig, publicKey: ""))
        let fakeDMG = sandbox.appendingPathComponent("fake.dmg")
        fm.createFile(atPath: fakeDMG.path, contents: blob)
        let sums = Data(((try? Updater.sha256(of: fakeDMG)) ?? "").utf8)
        check("install refuses a download with the right checksum but no valid signature",
              (try? Updater.prepare(dmg: fakeDMG, checksumFile: sums, signatureFile: strangerSig, version: "9.9",
                                    work: sandbox, publicKey: pub)) == nil)
        if let r = rel {
            let unsigned = Updater.Release(version: r.version, notes: "", page: r.page, dmg: r.dmg, checksum: r.checksum,
                                           signature: nil, size: r.size)
            check("an unsigned release isn't offered; a signed one is",
                  !Updater.offerable(unsigned, current: "1.0", publicKey: pub) && Updater.offerable(r, current: "1.0", publicKey: pub)
                  && !Updater.offerable(r, current: "1.0", publicKey: ""))
        } else { check("an unsigned release isn't offered; a signed one is", false) }

        print("Apps › Clear Cache (review = execution)")
        // Three throwaway caches: one outside the allow-list (blocked), one allowed, and one allowed when the
        // review is built but protected before Clear runs. Only the allowed one may be deleted.
        let ccBlocked = sandbox.appendingPathComponent("appcache-blocked")
        let ccAllowed = h(".cache/maccleaner-selftest-appcache")
        let ccLater = h(".cache/maccleaner-selftest-appcache-later")
        defer { try? fm.removeItem(at: ccAllowed); try? fm.removeItem(at: ccLater) }
        for u in [ccBlocked, ccAllowed, ccLater] {
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            fm.createFile(atPath: u.appendingPathComponent("blob").path, contents: Data("x".utf8))
        }
        func cacheEntry(_ u: URL) -> AppLeftover { AppLeftover(id: u.path, url: u, label: "Caches", size: 1, include: true, note: nil) }
        func testApp(_ caches: [URL]) -> AppInfo {
            AppInfo(id: sandbox.appendingPathComponent("SelfTest.app").path, url: sandbox.appendingPathComponent("SelfTest.app"),
                    name: "SelfTest", bundleID: "com.example.maccleaner-selftest", version: "1", isApple: false,
                    appSize: 0, lastUsed: nil, leftovers: [], caches: caches.map(cacheEntry))
        }
        let ccApp = testApp([ccBlocked, ccAllowed, ccLater])
        let ccReview = MainActor.assumeIsolated { ReviewBuild.appCache(ccApp) { _ in } }
        let ccBlockedIDs = Set(ccReview.items.filter { $0.blocked != nil }.map(\.id))
        check("review blocks a cache outside the allow-list, allows the others", ccBlockedIDs == [ccBlocked.path])
        // A sandbox cache folder (path only, never created): the review shows what the engine does.
        let container = h("Library/Containers/com.example.maccleaner-selftest/Data/Library/Caches")
        let containerRow = MainActor.assumeIsolated { ReviewBuild.appCache(testApp([container])) { _ in } }.items.first
        check("review shows a sandboxed app cache as allowed, contents only, as the engine runs it",
              containerRow?.blocked == nil && containerRow?.note == AppEngine.contentsOnlyNote
              && AppEngine.cacheDecision(container) == AppEngine.CacheDecision(contentsOnly: true, blocked: nil))
        check("a protected sandboxed app cache is blocked in the review and by the engine",
              { () -> Bool in
                  ProtectedPaths.set(savedProtected + [container.path])
                  defer { ProtectedPaths.set(savedProtected) }
                  let row = MainActor.assumeIsolated { ReviewBuild.appCache(testApp([container])) { _ in } }.items.first
                  return row?.blocked != nil && AppEngine.cacheDecision(container).blocked != nil
              }())
        ProtectedPaths.set(savedProtected + [ccLater.path])   // protected after the review was shown
        let ccErrors = AppEngine.clearCaches(ccApp.caches)
        ProtectedPaths.set(savedProtected)
        check("Clear leaves the item the review marked blocked untouched",
              fm.fileExists(atPath: ccBlocked.appendingPathComponent("blob").path))
        check("Clear deletes the item the review allowed", !fm.fileExists(atPath: ccAllowed.path))
        check("Clear re-checks right before deleting: protected after the review → skipped",
              fm.fileExists(atPath: ccLater.appendingPathComponent("blob").path))
        check("skipped items are reported, one line each",
              ccErrors.count == 2 && ccErrors.contains { $0.hasPrefix(ccBlocked.lastPathComponent + ":") && $0.hasSuffix("skipped") }
              && ccErrors.contains { $0.hasPrefix(ccLater.lastPathComponent + ":") && $0.hasSuffix("skipped") })

        print("Password step staging (admin uninstall)")
        // The root script stages items in a fresh random folder only root can open, never in a folder another process
        // can create first, and gives you only that folder: a recursive chown as root would hand you any root-owned
        // file hard-linked into it. Everything below runs as you on throwaway files; no password, no system files.
        let uid = getuid()
        func adminItem(_ u: URL, label: String? = nil, receipt: String? = nil) -> AppLeftover {
            var l = AppLeftover(id: u.path, url: u, label: "x", size: 0, include: true, note: nil, needsAdmin: true)
            l.launchLabel = label
            l.receipt = receipt
            return l
        }
        let rootScript = AdminStep.script([
            adminItem(URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.helper.plist"), label: "com.example.helper"),
            adminItem(URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.bad.plist"), label: "x; rm -rf /"),
            adminItem(URL(fileURLWithPath: "/private/var/db/receipts/x.bom"), receipt: "com.example.pkg$(id)"),
            adminItem(URL(fileURLWithPath: "/usr/local/bin/x")),
        ], uid: uid)
        check("staging folder is made by mktemp -d in /private/var/tmp",
              rootScript.contains("/usr/bin/mktemp -d '/private/var/tmp/MacCleaner-uninstall.XXXXXXXXXX'"))
        check("no staging folder in your home, no recursive chown",
              !rootScript.contains(home.path) && !rootScript.contains("chown -R") && !rootScript.contains("mkdir"))
        check("only the staging folder changes owner", rootScript.contains("'/usr/sbin/chown' \(uid) \"$D\" || exit 1"))
        check("each item's folder is checked again (real folder, owned by root) right before the move",
              rootScript.contains("[ ! -L '/Library/LaunchDaemons' ] && [ \"$(/usr/bin/stat -f %u '/Library/LaunchDaemons')\" = 0 ]"))
        check("unsafe launch labels and receipt ids are left out",
              rootScript.contains("/bin/launchctl bootout gui/\(uid)/com.example.helper ") && !rootScript.contains("rm -rf")
              && !rootScript.contains("$(id)"))
        check("paths outside the allowed folders are left out", !rootScript.contains("/usr/local/bin/x"))
        let fakeStaging = "/private/var/tmp/MacCleaner-uninstall.Ab3dE6gH9k"
        check("reads the staging path the script printed", AdminStep.parseStaging("noise\r\(fakeStaging)\n")?.path == fakeStaging)
        check("refuses any other printed path", [
            home.path + "/.MacCleaner-uninstalled-1700000000", "/private/var/tmp/MacCleaner-uninstall.short",
            fakeStaging + "/..", fakeStaging + "x", "/tmp/MacCleaner-uninstall.Ab3dE6gH9k", "",
        ].allSatisfy { AdminStep.parseStaging($0) == nil })

        // The attack, with throwaway files: "victim.txt" stands in for a root-owned file. A process running as you
        // pre-creates the old predictable staging folders for the coming minute, each holding a hard link to it, and
        // hard-links it into a folder that is about to be moved.
        let adm = sandbox.appendingPathComponent("admin")
        let sysDir = adm.appendingPathComponent("System")             // stands in for e.g. /Library/LaunchDaemons
        try? fm.createDirectory(at: sysDir.appendingPathComponent("Helper Folder"), withIntermediateDirectories: true)
        let victim = adm.appendingPathComponent("victim.txt")
        fm.createFile(atPath: victim.path, contents: Data("root secret".utf8))
        try? fm.linkItem(at: victim, to: sysDir.appendingPathComponent("Helper Folder/victim-link"))
        let quotedItem = sysDir.appendingPathComponent("it's here.plist")
        fm.createFile(atPath: quotedItem.path, contents: Data("x".utf8))
        let linkTarget = sandbox.appendingPathComponent("loose.txt")
        let linkItem = sysDir.appendingPathComponent("link.plist")
        try? fm.createSymbolicLink(at: linkItem, withDestinationURL: linkTarget)
        var decoys: [URL] = []
        let now = Int(Date().timeIntervalSince1970)
        for t in (now - 5)...(now + 60) {
            let d = home.appendingPathComponent(".MacCleaner-uninstalled-\(t)")
            guard !fm.fileExists(atPath: d.path), (try? fm.createDirectory(at: d, withIntermediateDirectories: false)) != nil else { continue }
            decoys.append(d)
            try? fm.linkItem(at: victim, to: d.appendingPathComponent("x"))
        }
        defer { decoys.forEach { try? fm.removeItem(at: $0) } }
        // A stand-in for chown that only records what it was asked to change.
        let chownLog = adm.appendingPathComponent("chown.log")
        let fakeChown = adm.appendingPathComponent("fake-chown")
        try? "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(AdminStep.q(chownLog.path))\n".write(to: fakeChown, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeChown.path)

        func runAsYou(_ urls: [URL], parentOwner: uid_t) -> (status: Int32, staging: URL?) {
            let s = AdminStep.script(urls.map { adminItem($0) }, uid: uid, allowed: { _ in true },
                                     parentOwner: parentOwner, chown: fakeChown.path)
            let r = Shell.run("/usr/bin/osascript", ["-e", AdminStep.appleScript(s, admin: false)])
            return (r.status, AdminStep.parseStaging(r.output))
        }
        let moved = [sysDir.appendingPathComponent("Helper Folder"), quotedItem, linkItem]
        let run = runAsYou(moved, parentOwner: uid)
        defer { if let s = run.staging { try? fm.removeItem(at: s) } }
        let stagedNames = run.staging.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) }?.sorted() ?? []
        check("script (via osascript) moves every item into a new staging folder",
              run.status == 0 && stagedNames == ["0-Helper Folder", "1-it's here.plist", "2-link.plist"]
              && moved.allSatisfy { !fm.fileExists(atPath: $0.path) && (try? fm.destinationOfSymbolicLink(atPath: $0.path)) == nil })
        check("pre-created old staging folders are not used and stay as they were",
              !decoys.isEmpty && run.staging.map { s in !decoys.contains { $0.path == s.path } } == true
              && decoys.allSatisfy { (try? fm.contentsOfDirectory(atPath: $0.path)) == ["x"] })
        let chownCalls = ((try? String(contentsOf: chownLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        check("hard links never change owner: chown runs once, on the staging folder only",
              run.staging.map { chownCalls == ["\(uid) \($0.path)"] } == true)
        check("the hard-linked file keeps its content", (try? String(contentsOf: victim, encoding: .utf8)) == "root secret")
        check("a link is moved as a link, its target stays",
              fm.fileExists(atPath: linkTarget.path)
              && run.staging.map { (try? fm.destinationOfSymbolicLink(atPath: $0.appendingPathComponent("2-link.plist").path)) != nil } == true)
        check("staging folder is a 700 folder you own", run.staging.map { AdminStep.isTrustedStaging($0, uid: uid) } == true)
        let stagingLink = adm.appendingPathComponent("staging-link")
        if let s = run.staging { try? fm.createSymbolicLink(at: stagingLink, withDestinationURL: s) }
        check("a link to the staging folder or an open folder is not trusted as staging",
              run.staging != nil && !AdminStep.isTrustedStaging(stagingLink, uid: uid) && !AdminStep.isTrustedStaging(adm, uid: uid))

        // Checked again right before the move: an item whose folder became a link, or whose folder isn't owned by
        // root, stays where it is.
        let realDir = adm.appendingPathComponent("Real")
        try? fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        fm.createFile(atPath: realDir.appendingPathComponent("a.plist").path, contents: Data("x".utf8))
        let swapped = adm.appendingPathComponent("Swapped")
        try? fm.createSymbolicLink(at: swapped, withDestinationURL: realDir)
        let swappedRun = runAsYou([swapped.appendingPathComponent("a.plist")], parentOwner: uid)
        defer { if let s = swappedRun.staging { try? fm.removeItem(at: s) } }
        check("an item whose folder is now a link is not moved",
              swappedRun.status == 0 && fm.fileExists(atPath: realDir.appendingPathComponent("a.plist").path)
              && swappedRun.staging.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) } == [])
        let notRootRun = runAsYou([realDir.appendingPathComponent("a.plist")], parentOwner: 0)
        defer { if let s = notRootRun.staging { try? fm.removeItem(at: s) } }
        check("an item in a folder not owned by root is not moved",
              notRootRun.status == 0 && fm.fileExists(atPath: realDir.appendingPathComponent("a.plist").path)
              && notRootRun.staging.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) } == [])

        print("Audit P2 fixes (review = execution, duplicates)")
        // P2-1: what runs is what the review listed, even if a rescan changes the selection while it is open.
        let p2Root = cacheItem.appendingPathComponent("p2")
        let p2A = p2Root.appendingPathComponent("a"), p2B = p2Root.appendingPathComponent("b"), p2C = p2Root.appendingPathComponent("c")
        for d in [p2A, p2B, p2C] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            fm.createFile(atPath: d.appendingPathComponent("f").path, contents: Data(count: 4096))
        }
        func p2Target(_ id: String, _ action: CleanAction) -> CleanTarget {
            var t = CleanTarget(id: id, category: .devCache, name: id, path: id, note: "", action: action, sizeBytes: 4096, exists: true)
            t.selected = true
            return t
        }
        let reviewedRuns: [String] = MainActor.assumeIsolated {
            let m = CleanerModel()
            m.targets = [p2Target("p2.a", .removeItem(p2A))]
            var ran: [String] = []
            let req = ReviewBuild.junk(m) { ran = $0.map(\.id) }
            m.targets.append(p2Target("p2.c", .removeItem(p2C)))        // a rescan while the sheet is open
            req.perform(Set(req.allowed.map(\.id)))
            return ran
        }
        check("review runs only what it listed, not items a rescan added", reviewedRuns == ["p2.a"])

        // P2-2: an item made of several folders is blocked as a whole, and the cleaner keeps it whole.
        ProtectedPaths.set(savedProtected + [p2B.path])
        let multi = p2Target("p2.multi", .removeItems([p2A, p2B]))
        let multiRow = MainActor.assumeIsolated { ReviewBuild.cacheItems([multi]).first }
        let multiErrors = Cleaner.run([multi])
        ProtectedPaths.set(savedProtected)
        check("a multi-folder item with one protected folder is blocked in the review", multiRow?.blocked != nil)
        check("…and the cleaner removes none of its folders",
              !multiErrors.isEmpty && fm.fileExists(atPath: p2A.path) && fm.fileExists(atPath: p2B.path))

        // P2-5: a duplicate goes to the Trash only while an identical copy still exists.
        let dupA = sandbox.appendingPathComponent("p2-dup-a"), dupB = sandbox.appendingPathComponent("p2-dup-b")
        let dupData = Data((0..<300_000).map { UInt8($0 % 253) })
        fm.createFile(atPath: dupA.path, contents: dupData)
        fm.createFile(atPath: dupB.path, contents: dupData)
        let sameBefore = DupEngine.identical(dupB, dupA, size: Int64(dupData.count))
        var edited = dupData; edited[150_000] ^= 1
        fm.createFile(atPath: dupA.path, contents: edited)            // the kept copy is edited after the scan
        let sameAfterEdit = DupEngine.identical(dupB, dupA, size: Int64(dupData.count))
        try? fm.removeItem(at: dupA)
        let sameAfterDelete = DupEngine.identical(dupB, dupA, size: Int64(dupData.count))
        try? fm.linkItem(at: dupB, to: dupA)
        let hardLink = DupEngine.identical(dupB, dupA, size: Int64(dupData.count))
        check("duplicates: identical copies are recognised right before trashing", sameBefore)
        check("duplicates: an edited, deleted or hard-linked kept copy stops the trash", !sameAfterEdit && !sameAfterDelete && !hardLink)

        print("Audit P2 fixes (weekly clean scope)")
        func autoTarget(_ id: String, _ action: CleanAction) -> CleanTarget {
            CleanTarget(id: id, category: .devCache, name: id, path: id, note: "", action: action, sizeBytes: 4096, exists: true)
        }
        let hf = autoTarget("cache.huggingface", .removeItem(h(".cache/huggingface")))
        let pip = autoTarget("cache.pip", .removeItem(h(".cache/pip")))
        check("weekly clean: ~/.cache model caches stay, simple tool caches go",
              AutoClean.select([hf, pip], running: []).map(\.id) == ["cache.pip"])
        let runningCache = autoTarget("appcache.com.example.running", .removeItem(h("Library/Caches/com.example.running")))
        let runningBox = autoTarget("container.com.example.running",
                                    .removeContents(h("Library/Containers/com.example.running/Data/Library/Caches")))
        check("weekly clean: caches of a running app are skipped",
              AutoClean.select([runningCache, runningBox], running: ["com.example.running"]).isEmpty
              && AutoClean.select([runningCache], running: []).count == 1)
        let logsDir = sandbox.appendingPathComponent("Logs")
        let crash = logsDir.appendingPathComponent("DiagnosticReports"), appLog = logsDir.appendingPathComponent("SomeApp")
        for d in [crash, appLog] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            fm.createFile(atPath: d.appendingPathComponent("x.log").path, contents: Data(count: 4096))
        }
        let logs = AutoClean.narrowed(autoTarget("logs.user", .removeItems([crash, appLog])), running: [])
        check("weekly clean: crash reports are kept, other logs go",
              { if case .removeItems(let us)? = logs?.action { return us == [appLog] }; return false }())

        print("Audit P2 fixes (shared logs)")
        // P2-3: the window and the CLI/MCP process each keep a log object; neither may erase the other's entries.
        let sharedLog = sandbox.appendingPathComponent("trash-log-test.json")
        let inTrashA = sandbox.appendingPathComponent("in-trash-a"), inTrashB = sandbox.appendingPathComponent("in-trash-b")
        fm.createFile(atPath: inTrashA.path, contents: Data("a".utf8))
        fm.createFile(atPath: inTrashB.path, contents: Data("b".utf8))
        let windowLog = TrashLog(file: sharedLog), mcpLog = TrashLog(file: sharedLog)   // both opened before either writes
        mcpLog.record(original: "/x/a", trashed: inTrashA.path, size: 1, source: "MCP", restorable: true)
        windowLog.record(original: "/x/b", trashed: inTrashB.path, size: 1, source: "Window", restorable: true)
        check("Put Back log keeps entries from both the window and the MCP/CLI process",
              Set(windowLog.present().map(\.source)) == ["MCP", "Window"])
        let sharedHistory = sandbox.appendingPathComponent("history-test.json")
        HistoryStore.insert(CleanupRecord(date: Date(), title: "mcp", bytes: 1, symbol: "x"), into: sharedHistory)
        HistoryStore.insert(CleanupRecord(date: Date(), title: "window", bytes: 1, symbol: "x"), into: sharedHistory)
        check("history keeps records from both processes",
              Set((SharedFile.read(sharedHistory) as [CleanupRecord]).map(\.title)) == ["mcp", "window"])

        print("Audit P2 fixes (tools can't hang)")
        let quick = Shell.run("/bin/echo", ["hi"], timeout: 10)
        check("a quick tool still returns its output", quick.status == 0 && quick.output == "hi\n")
        var started = Date()
        let orphan = Shell.run("/bin/sh", ["-c", "sleep 20 & sleep 20"], timeout: 1)
        check("a tool whose helper keeps the output open returns after its time limit",
              Date().timeIntervalSince(started) < 6 && (orphan.output ?? "").contains("timed out"))
        started = Date()
        let stubborn = Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 20"], timeout: 1)
        check("a tool that ignores SIGTERM is killed", Date().timeIntervalSince(started) < 8 && (stubborn.output ?? "").contains("timed out"))

        print("\n\(passed) passed, \(failed.count) failed")
        if !failed.isEmpty { print("FAILED:\n" + failed.map { "  - " + $0 }.joined(separator: "\n")) }
        return failed.isEmpty
    }
}
