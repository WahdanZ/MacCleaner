import CryptoKit
import Foundation
import MacCleanerCore
import MacCleanerPlatform

/// `Mac Cleaner --selftest`: checks every safety rule. Exit code 0 = all passed.
///
/// Run it with `scripts/selftest.sh`, which gives it a fresh, empty home folder (`CFFIXED_USER_HOME`).
/// It refuses to run against your real home folder unless MACCLEANER_SELFTEST_ALLOW_REAL_HOME=1 is set.
/// Even then it only creates folders with a unique name per run (~/.maccleaner-selftest-<run>,
/// ~/.cache/maccleaner-selftest-<run>-*), never reuses one that already exists, and keeps the Protected
/// list in a throwaway settings domain instead of yours.
enum SelfTest {
    private static var passed = 0
    private static var failed: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        if ok { passed += 1 } else { failed.append(name) }
        print((ok ? "  ✓ " : "  ✗ ") + name)
    }

    /// The account's real home folder (from the user database; CFFIXED_USER_HOME doesn't change it).
    static var accountHome: URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir)).resolvingSymlinksInPath().standardizedFileURL
    }

    static func run() -> Bool {
        let fm = FileManager.default
        let home = SafetyGuard.home
        if home.path == accountHome?.path && ProcessInfo.processInfo.environment["MACCLEANER_SELFTEST_ALLOW_REAL_HOME"] != "1" {
            print("""
            Refusing to run the self-test in your real home folder (\(home.path)).
            Run scripts/selftest.sh, which uses a throwaway home folder, or set
            MACCLEANER_SELFTEST_ALLOW_REAL_HOME=1 to run here anyway.
            """)
            return false
        }
        let h = { (rel: String) in home.appendingPathComponent(rel) }
        let runUUID = UUID().uuidString.lowercased()
        let runID = runUUID.prefix(8)
        let sandbox = h(".maccleaner-selftest-\(runID)")
        let cacheLink = h(".cache/maccleaner-selftest-\(runID)-link")
        let cacheItem = h(".cache/maccleaner-selftest-\(runID)-item")
        // Only ever work in folders this run created: if a name is taken, stop before touching anything.
        let madeCacheFolder = !fm.fileExists(atPath: h(".cache").path)
            && (try? fm.createDirectory(at: h(".cache"), withIntermediateDirectories: false)) != nil
        guard (try? fm.createDirectory(at: sandbox, withIntermediateDirectories: false)) != nil,
              !fm.fileExists(atPath: cacheLink.path), !fm.fileExists(atPath: cacheItem.path) else {
            print("Self-test setup failed: \(sandbox.path) couldn't be created as a new folder. Nothing was changed.")
            return false
        }
        // Every Trash move of this run goes to a folder in the throwaway home, never the real Trash (FileManager's
        // trashItem ignores CFFIXED_USER_HOME). Installed before anything can move.
        isolateTrash(in: h(".maccleaner-selftest-trash-\(runID)"))
        // The Protected list lives in memory for this run: nothing is written to the user's settings.
        let realStore = ProtectedPaths.store
        let realProtectedBefore = realStore.object(forKey: ProtectedPaths.key) as? [String]
        ProtectedPaths.store = MemorySettings()
        let savedProtected = ProtectedPaths.all
        defer {
            ProtectedPaths.store = realStore
            try? fm.removeItem(at: sandbox)
            try? fm.removeItem(at: cacheLink)
            try? fm.removeItem(at: cacheItem)
            if madeCacheFolder { try? fm.removeItem(at: h(".cache")) }   // only if this run made it (and left it empty)
        }
        print("Isolation")
        ProtectedPaths.set([h("selftest-sentinel-\(runID)").path])
        check("the Protected list used by the tests is not the user's",
              ProtectedPaths.all.count == 1 && (realStore.object(forKey: ProtectedPaths.key) as? [String]) == realProtectedBefore)
        ProtectedPaths.set(savedProtected)
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
        let shredRule = { (u: URL) in AppProtection().refusal(path: u.path, disposition: .overwriteThenDelete) }
        check("Shredder refuses protected (same rule)", shredRule(keep) != nil)
        check("the Shredder rule refuses a protected folder's contents", shredRule(keep.appendingPathComponent("inner/file.txt")) != nil)
        check("the Shredder rule allows an unprotected item in the home folder", shredRule(sandbox.appendingPathComponent("loose.txt")) == nil)
        check("the Shredder rule refuses items outside the home folder (/private/tmp, /Applications)",
              shredRule(URL(fileURLWithPath: "/private/tmp/x")) != nil
              && shredRule(URL(fileURLWithPath: "/Applications/Example.app")) != nil
              && shredRule(URL(fileURLWithPath: "/Applications/Safari.app")) != nil)
        check("the Shredder's home-folder check compares letter case exactly (a case-distinct folder is not home)",
              AppProtection.isInsideHome("/Users/someone/a", home: "/Users/someone")
              && !AppProtection.isInsideHome("/Users/SomeOne/a", home: "/Users/someone")
              && !AppProtection.isInsideHome("/users/someone", home: "/Users/someone")
              && !AppProtection.isInsideHome("/Users/someone2/a", home: "/Users/someone"))
        check("existing protected items are still protected", savedProtected.allSatisfy { ProtectedPaths.all.contains($0) })
        check("a protected folder hides what is inside it in any letter case (RISK-012)",
              ProtectedPaths.isInsideProtected(URL(fileURLWithPath: keep.path.uppercased() + "/inner"))
              && ProtectedPaths.isInsideProtected(keep.appendingPathComponent("inner")))

        // Trash moves, the Trash log and Put Back go through the cleanup executor only (there is no other Trash path):
        // see "Approved Trash" below (moved, logged, put back; protected after review is refused).
        ProtectedPaths.set(savedProtected)
        approvedTrash(sandbox: sandbox, runID: String(runID), savedProtected: savedProtected)

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
        do {
            let old: [String: Any] = [ProtectedPaths.key: ["/a/keep", "/b/keep"], "appearance": "dark", "NSWindow Frame x": "1"]
            let target = MemorySettings()
            target.set(["/c/mine"], forKey: ProtectedPaths.key)
            target.set("light", forKey: "appearance")
            SettingsMigration.migrate(old: { old }, to: target)
            check("protected paths are merged, none dropped",
                  Set(target.stringArray(forKey: ProtectedPaths.key) ?? []) == ["/a/keep", "/b/keep", "/c/mine"])
            check("settings already set under the new ID win", target.string(forKey: "appearance") == "light")
            check("system window keys are not copied", target.object(forKey: "NSWindow Frame x") == nil)
            target.removeObject(forKey: ProtectedPaths.key)
            check("runs only once", SettingsMigration.migrate(old: { old }, to: target) == 0
                  && target.stringArray(forKey: ProtectedPaths.key) == nil)
        }

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
        // The file name must keep its stored bytes; the folder part may be spelled /tmp or /private/tmp
        // (same folder), so the two paths are compared by the file they reach.
        let pathOK = listed.map { l -> Bool in
            guard let r = reference, Array(l.url.lastPathComponent.utf8) == Array(r.lastPathComponent.utf8) else { return false }
            var a = stat(), b = stat()
            return lstat(l.url.path, &a) == 0 && lstat(r.path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
        } ?? false
        check("Storage Map keeps a non-ASCII name exactly as stored", nameOK && pathOK)
        if !(nameOK && pathOK) {
            let form = { (t: String?) -> String in
                guard let t else { return "missing" }
                return t == t.precomposedStringWithCanonicalMapping && Array(t.utf8) == Array(t.precomposedStringWithCanonicalMapping.utf8) ? "NFC" : "NFD"
            }
            print("    name \(form(listed?.name)), path \(form(listed?.url.path)), FileManager path \(form(reference?.path))")
            print("    map path: \(listed?.url.path ?? "missing")\n    FileManager path: \(reference?.path ?? "missing")")
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
              AutoClean.select([cmdTarget(.deleteUnavailableSimulators([])), cmdTarget(.deleteSimRuntime("x"))]).isEmpty)
        check("weekly clean refuses a target with no paths", AutoClean.select([cmdTarget(.removeItems([]))]).isEmpty)

        print("Simulators are never deleted without review (SAFE-04)")
        let simTarget = Scanner.plan().first { $0.id == "xcode.sims" }
        check("unavailable simulators are not recommended (not pre-selected, not in Select All Safe)",
              simTarget != nil && simTarget?.recommended == false)
        let simJSON: [String: [[String: Any]]] = [
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                ["udid": "11111111-1111-1111-1111-111111111111", "name": "iPhone 15", "isAvailable": false],
                ["udid": "not-a-uuid", "name": "Broken"],
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-10-0": [
                ["udid": "22222222-2222-2222-2222-222222222222", "name": "Apple Watch Series 9", "isAvailable": false],
            ],
        ]
        let parsedSims = Scanner.parseSimulators(simJSON)
        check("simulators are listed by name and OS; bad ids are ignored",
              parsedSims.map(\.name) == ["iPhone 15", "Apple Watch Series 9"] && parsedSims.map(\.os) == ["iOS 17.2", "watchOS 10.0"])
        var reviewedSims = CleanTarget(id: "xcode.sims", category: .xcode, name: "Unavailable simulators", path: "", note: "",
                                       action: .deleteUnavailableSimulators(parsedSims), recommended: false, sizeBytes: 1, exists: true)
        reviewedSims.note = Scanner.simulatorNote(parsedSims)
        let simRow = MainActor.assumeIsolated { ReviewBuild.cacheItems([reviewedSims]).first }
        check("the review names each simulator and says its apps and data are deleted",
              simRow?.risk == .review && simRow?.note?.contains("iPhone 15 (iOS 17.2)") == true
              && simRow?.note?.contains("apps, files and settings") == true)
        let laterUnavailable = SimDevice(udid: "33333333-3333-3333-3333-333333333333", name: "iPad", os: "iOS 16.4")
        check("only reviewed simulators that are still unavailable are deleted (new ones are not added)",
              Scanner.stillUnavailable(parsedSims, now: [parsedSims[1], laterUnavailable]) == [parsedSims[1]])
        check("a reviewed simulator that became available again is kept",
              Scanner.stillUnavailable(parsedSims, now: []).isEmpty)
        let runtimeItems = SDKEngine.xcode().filter { $0.id.hasPrefix("simrt.") }
        check("simulator runtimes are always review items (\(runtimeItems.count) found on this Mac)",
              runtimeItems.allSatisfy { $0.review && !$0.isUnused })

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

        // The Shredder's own safety checks now live in the package tests (Packages/MacCleanerKit/Tests, ShredTests.swift and
        // ShredExecutorTests.swift) and in "Shredder review" / "Shredder screen" below; see "04c-2: what happened to each
        // Shredder self-test" in docs/architecture/M01-04C_DESIGN.md.

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
        let ccAllowed = h(".cache/maccleaner-selftest-\(runID)-appcache")
        let ccLater = h(".cache/maccleaner-selftest-\(runID)-appcache-later")
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
        /// An item for the password step with its reviewed identity: captured now for a real file, a fixed one for the
        /// script-text checks on paths that don't exist here.
        func adminItem(_ u: URL, label: String? = nil, receipt: String? = nil) -> AppLeftover {
            var l = AppLeftover(id: u.path, url: u, label: "x", size: 0, include: true, note: nil, needsAdmin: true)
            l.launchLabel = label
            l.receipt = receipt
            l.identity = AppCleanup.snapshot(u)
                ?? FileIdentity(path: u.path, device: 1, inode: 2, kind: .file, size: 3, modificationNanos: 4_000_000_000)
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
              rootScript.contains("'/bin/launchctl' bootout gui/\(uid)/com.example.helper ") && !rootScript.contains("rm -rf")
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

        print("Duplicates: read failures never count as a match (SAFE-05)")
        let rfA = sandbox.appendingPathComponent("dup-read-a"), rfB = sandbox.appendingPathComponent("dup-read-b")
        let rfC = sandbox.appendingPathComponent("dup-read-c")
        var rfData = Data((0..<2_500_000).map { UInt8(($0 * 31 + 7) % 251) })      // > 2 chunks of 1 MB
        rfData[0] = 7
        fm.createFile(atPath: rfA.path, contents: rfData)
        fm.createFile(atPath: rfB.path, contents: rfData)                         // a real copy
        var rfOther = rfData; rfOther[2_400_000] ^= 1                            // same size, one byte differs
        fm.createFile(atPath: rfC.path, contents: rfOther)
        let size = Int64(rfData.count)
        struct ReadFailed: Error {}
        /// Real reads cut into odd, non-empty pieces (1 byte to ~70 KB), varying call by call — the kind of
        /// short reads a network or FUSE file system can return. Different pieces for the two files.
        final class Fragmenter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            let sizes = [1, 7, 4093, 65_536, 13, 70_001, 512, 3]
            func read(_ h: FileHandle, _ want: Int) throws -> Data {
                lock.lock(); n += 1; let piece = sizes[n % sizes.count]; lock.unlock()
                return try h.read(upToCount: min(want, piece)) ?? Data()
            }
        }
        let frag = Fragmenter()
        let fragmented: DupEngine.ReadChunk = { h, n in try frag.read(h, n) }
        /// Gives a few real pieces, then fails (an I/O error part-way through).
        final class FailLater: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func read(_ h: FileHandle, _ want: Int) throws -> Data {
                lock.lock(); n += 1; let k = n; lock.unlock()
                if k > 3 { throw ReadFailed() }
                return try h.read(upToCount: min(want, 1000)) ?? Data()
            }
        }
        let failing: DupEngine.ReadChunk = { _, _ in throw ReadFailed() }
        let cancelNever = DupEngine.Cancel()
        let sysA = DupEngine.fullHash(rfA, size: size, cancel: cancelNever)
        check("valid partial reads: copies are still recognised as identical",
              DupEngine.identical(rfA, rfB, size: size, read: fragmented))
        check("valid partial reads: files differing in one byte are still told apart",
              !DupEngine.identical(rfA, rfC, size: size, read: fragmented))
        check("valid partial reads: hashes equal the ones from whole reads",
              sysA != nil && DupEngine.fullHash(rfA, size: size, cancel: cancelNever, read: fragmented) == sysA
              && DupEngine.partialHash(rfA, size: size, read: fragmented) == DupEngine.partialHash(rfA, size: size)
              && DupEngine.partialHash(rfA, size: 100_000, read: fragmented) == DupEngine.partialHash(rfA, size: 100_000))
        check("identical() is false when both files fail to read (used to be true)",
              !DupEngine.identical(rfA, rfB, size: size, read: failing))
        let later1 = FailLater(), later2 = FailLater(), later3 = FailLater()
        check("a read error after some good reads never gives a match or a hash",
              !DupEngine.identical(rfA, rfB, size: size, read: { h, n in try later1.read(h, n) })
              && DupEngine.fullHash(rfA, size: size, cancel: cancelNever, read: { h, n in try later2.read(h, n) }) == nil
              && DupEngine.partialHash(rfA, size: size, read: { h, n in try later3.read(h, n) }) == nil)
        check("hashes are nil on a read error, so unreadable files are never grouped",
              DupEngine.partialHash(rfA, size: size, read: failing) == nil
              && DupEngine.fullHash(rfA, size: size, cancel: cancelNever, read: failing) == nil
              && DupEngine.partialHash(rfA, size: 1000, read: failing) == nil)
        // Truncated: the file is cut short while it is being compared or hashed.
        let rfT = sandbox.appendingPathComponent("dup-read-t")
        fm.createFile(atPath: rfT.path, contents: rfData)
        var truncated = false
        let truncating: DupEngine.ReadChunk = { h, n in
            if !truncated { truncated = true; truncate(rfT.path, 1_000_000) }
            return try h.read(upToCount: n) ?? Data()
        }
        let truncDiffers = !DupEngine.identical(rfA, rfT, size: size, read: truncating)
        fm.createFile(atPath: rfT.path, contents: rfData); truncated = false
        let truncHash = DupEngine.fullHash(rfT, size: size, cancel: cancelNever, read: truncating)
        fm.createFile(atPath: rfT.path, contents: rfData); truncated = false
        let truncPartial = DupEngine.partialHash(rfT, size: size, read: truncating)
        check("a file truncated during the compare or hash is rejected", truncDiffers && truncHash == nil && truncPartial == nil)
        check("hashes are nil when the file is shorter than its listed size",
              DupEngine.fullHash(rfA, size: size + 1, cancel: cancelNever) == nil
              && DupEngine.partialHash(sandbox.appendingPathComponent("dup-read-a"), size: 100_000_000) == nil)
        check("a file that grew past its scanned size is not called identical",
              { () -> Bool in
                  let g = sandbox.appendingPathComponent("dup-read-g")
                  fm.createFile(atPath: g.path, contents: rfData)
                  let grow: DupEngine.ReadChunk = { h, n in
                      if let fh = try? FileHandle(forWritingTo: g) { fh.seekToEndOfFile(); fh.write(Data([1])); try? fh.close() }
                      return try h.read(upToCount: n) ?? Data()
                  }
                  return !DupEngine.identical(rfA, g, size: size, read: grow)
              }())
        check("identical readable copies still match with ordinary reads",
              DupEngine.identical(rfA, rfB, size: size) && !DupEngine.identical(rfA, rfC, size: size)
              && DupEngine.fullHash(rfB, size: size, cancel: cancelNever) == sysA
              && DupEngine.partialHash(rfA, size: size) == DupEngine.partialHash(rfB, size: size))

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

        print("Isolation (end)")
        check("the user's own Protected list is unchanged after all tests",
              (realStore.object(forKey: ProtectedPaths.key) as? [String]) == realProtectedBefore)
        print("Trash isolation")
        let logFile = home.appendingPathComponent("Library/Application Support/Mac Cleaner/trash-log.json")
        let everRecorded = (SharedFile.read(logFile) as [TrashedItem]).map(\.trashed)
        check("every Trash move of the self-test went to its own folder, none to the real Trash",
              isolatedMoves.count > 0 && isolatedMoves.all.allSatisfy { $0.hasPrefix(isolatedTrash.path + "/") }
              && everRecorded.allSatisfy { $0.hasPrefix(isolatedTrash.path + "/") || $0.hasPrefix(AppCleanup.physicalPath(isolatedTrash) + "/") })
        print("\n\(passed) passed, \(failed.count) failed")
        if !failed.isEmpty { print("FAILED:\n" + failed.map { "  - " + $0 }.joined(separator: "\n")) }
        return failed.isEmpty
    }
}

// MARK: - Approved Trash (M01-04b)

/// Holds a value produced on the main actor while the self-test spins the run loop.
private final class Slot<T>: @unchecked Sendable {   // written once on the main actor, read after on the main thread
    var value: T?
}

extension SelfTest {
    /// Runs main-actor async work and spins the main run loop until it is done. The self-test runs on the main
    /// thread before the app starts, so this is how it awaits the executor and the review confirmation.
    static func wait<T>(_ seconds: TimeInterval = 30, _ work: @escaping @MainActor () async -> T) -> T? {
        let box = Slot<T>()
        Task { @MainActor in box.value = await work() }
        let end = Date().addingTimeInterval(seconds)
        while box.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return box.value
    }

    /// Opens a review for `urls`, confirms it through the review sheet's own confirmation, and returns what the
    /// sheet handed to the screen.
    @MainActor
    static func confirmTrashReview(_ urls: [URL]) -> TrashApproval?? {
        let got = Slot<TrashApproval?>()
        let request = ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest",
                                             urls.map { ($0, 1, nil) }) { _, approval in got.value = .some(approval) }
        ReviewConfirmation.confirm(request)
        let end = Date().addingTimeInterval(30)
        while got.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return got.value
    }

    static func approvedTrash(sandbox: URL, runID: String, savedProtected: [String]) {
        print("Approved Trash: review sheet → approval → executor (M01-04b)")
        let fm = FileManager.default
        let dir = sandbox.appendingPathComponent("approved-trash")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String = "reviewed") -> URL {
            let u = dir.appendingPathComponent("\(name)-\(runID).txt")
            try? Data(text.utf8).write(to: u)
            return u
        }
        func run(_ a: TrashApproval??, _ source: String = "Self-test") -> TrashRun? {
            guard case .some(.some(let approval)) = a else { return nil }
            return wait { await AppCleanup.moveToTrash(approval, source: source) }
        }
        func approved(_ a: TrashApproval??) -> ApprovedTrash? {
            if case .some(.some(.approved(let x))) = a { return x }
            return nil
        }
        func putBack(_ u: URL) -> Bool {
            guard let e = TrashLog.shared.present().first(where: { $0.original == AppCleanup.physicalPath(u) }) else { return false }
            return TrashOps.restore(e) == nil
        }
        let outstanding = { wait { await AppCleanup.executor.outstandingApprovals } ?? -1 }

        // Declined: the sheet was cancelled, so confirm never ran. Nothing is approved or moved.
        let declined = file("declined")
        let before = outstanding()
        _ = MainActor.assumeIsolated {
            ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest", [(declined, 1, nil)]) { _, _ in }
        }
        check("a cancelled review issues no approval and moves nothing",
              outstanding() == before && fm.fileExists(atPath: declined.path))

        // Confirmed, moved, logged, and put back.
        let ok = file("ok", "roundtrip")
        let okReview = MainActor.assumeIsolated { confirmTrashReview([ok]) }
        let okRun = run(okReview)
        check("a confirmed review moves exactly the reviewed item to the Trash",
              okRun?.moved[ok.path] != nil && okRun?.problems.isEmpty == true && !fm.fileExists(atPath: ok.path))
        check("the approval was used up by the move", outstanding() == before)
        check("the approved move is in the Trash log and Put Back restores it",
              putBack(ok) && (try? String(contentsOf: ok, encoding: .utf8)) == "roundtrip")

        // Replayed: the same approval presented again does nothing.
        let replay = run(okReview)
        check("a replayed approval is refused and moves nothing",
              replay?.moved.isEmpty == true && replay?.problems.first?.message.contains("already used") == true
              && fm.fileExists(atPath: ok.path))

        // Stale identity: the file was written to after the sheet opened.
        let stale = file("stale")
        let staleReview = MainActor.assumeIsolated { () -> TrashApproval?? in
            let got = Slot<TrashApproval?>()
            let request = ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest", [(stale, 1, nil)]) {
                got.value = .some($1)
            }
            try? Data("written after review".utf8).write(to: stale)   // between the sheet opening and the click
            ReviewConfirmation.confirm(request)
            let end = Date().addingTimeInterval(30)
            while got.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return got.value
        }
        let staleRun = run(staleReview)
        check("a file changed after review is left alone and reported",
              staleRun?.moved.isEmpty == true && staleRun?.problems.first?.message.contains("changed after you reviewed") == true
              && (try? String(contentsOf: stale, encoding: .utf8)) == "written after review")

        // Replaced: same name, different file.
        let replaced = file("replaced")
        let replacedReview = MainActor.assumeIsolated { () -> TrashApproval?? in
            let got = Slot<TrashApproval?>()
            let request = ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest", [(replaced, 1, nil)]) {
                got.value = .some($1)
            }
            try? fm.removeItem(at: replaced)
            try? Data("a different file".utf8).write(to: replaced)
            ReviewConfirmation.confirm(request)
            let end = Date().addingTimeInterval(30)
            while got.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return got.value
        }
        let replacedRun = run(replacedReview)
        check("a file replaced after review is left alone and reported",
              replacedRun?.moved.isEmpty == true && replacedRun?.problems.count == 1
              && (try? String(contentsOf: replaced, encoding: .utf8)) == "a different file")

        // Protected after review.
        let guarded = file("guarded")
        let guardedReview = MainActor.assumeIsolated { () -> TrashApproval?? in
            let got = Slot<TrashApproval?>()
            let request = ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest", [(guarded, 1, nil)]) {
                got.value = .some($1)
            }
            ProtectedPaths.set(savedProtected + [guarded.path])
            ReviewConfirmation.confirm(request)
            let end = Date().addingTimeInterval(30)
            while got.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return got.value
        }
        let guardedRun = run(guardedReview)
        ProtectedPaths.set(savedProtected)
        check("an item protected after review is left alone and reported",
              guardedRun?.moved.isEmpty == true && guardedRun?.problems.count == 1 && fm.fileExists(atPath: guarded.path))

        // Partial failure: one of two can't be moved.
        let free = file("free"), locked = file("locked")
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        let partial = run(MainActor.assumeIsolated { confirmTrashReview([free, locked]) })
        chflags(locked.path, 0)
        check("a partial failure moves what it can and reports the rest",
              partial?.moved[free.path] != nil && partial?.moved[locked.path] == nil
              && partial?.problems.map(\.id) == [locked.path] && fm.fileExists(atPath: locked.path))
        check("the partly moved item can be put back", putBack(free) && fm.fileExists(atPath: free.path))

        // The approved list is what the sheet showed: nothing added later, nothing missing at open.
        let shown = file("shown")
        let shownReview = MainActor.assumeIsolated { confirmTrashReview([shown]) }
        let later = file("added-later")
        check("the approval covers exactly the items the sheet showed",
              approved(shownReview)?.plan.candidates.map(\.id) == [shown.path])
        let noted = MainActor.assumeIsolated {
            ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest", [(shown, 1, "keeps a copy")]) { _, _ in }
        }
        check("the plan keeps each reviewed item's note as its explanation",
              noted.trashPlan?.candidates.first?.explanation == "keeps a copy")
        let shownRun = run(shownReview)
        check("an item added after the review isn't moved", shownRun?.moved.keys.sorted() == [shown.path]
              && fm.fileExists(atPath: later.path))
        _ = putBack(shown)
        trashLogDurability(dir: dir, runID: runID, file: file, run: run, putBack: putBack)
        sharedFileLocking(dir: dir)
        mcpAndCLITrash(dir: dir, runID: runID)
        engineTrash(dir: dir, runID: runID)
        shredReview(dir: dir, runID: runID, savedProtected: savedProtected)
        shredScreen(dir: dir, runID: runID, savedProtected: savedProtected)
        uninstallAndAlerts(dir: dir, runID: runID, savedProtected: savedProtected)
        MainActor.assumeIsolated { installedSkills(dir: dir, runID: runID) }

        let allowedOne = file("allowed"), blockedOne = file("blocked")
        ProtectedPaths.set(savedProtected + [blockedOne.path])
        let mixed = MainActor.assumeIsolated { () -> ([URL], TrashApproval?)? in
            let got = Slot<([URL], TrashApproval?)>()
            let request = ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest",
                                                 [(allowedOne, 1, nil), (blockedOne, 1, nil)]) { got.value = ($0, $1) }
            ReviewConfirmation.confirm(request)
            let end = Date().addingTimeInterval(30)
            while got.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return got.value
        }
        ProtectedPaths.set(savedProtected)
        let mixedPlan: [String]? = { if case .approved(let a)? = mixed?.1 { return a.plan.candidates.map(\.id) }; return nil }()
        check("a blocked item is neither approved nor handed to the screen",
              mixed?.0 == [allowedOne] && mixedPlan == [allowedOne.path])
        let gone = dir.appendingPathComponent("never-there-\(runID).txt")
        let goneRequest = MainActor.assumeIsolated {
            ReviewBuild.trashFiles(title: "Self-test", explanation: "", module: "selftest", [(gone, 1, nil)]) { _, _ in }
        }
        check("an item missing when the sheet opens is blocked and not in the plan",
              goneRequest.items.first?.blocked != nil && goneRequest.trashPlan == nil)
    }

    // MARK: Trash log per move (crash safety)

    static func trashLogDurability(dir: URL, runID: String, file: (String, String) -> URL,
                                   run: (TrashApproval??, String) -> TrashRun?, putBack: (URL) -> Bool) {
        let fm = FileManager.default
        func entries(_ u: URL) -> Int { TrashLog.shared.present().filter { $0.original == AppCleanup.physicalPath(u) }.count }

        // Several moves, each recorded once.
        let m1 = file("multi-1", "one"), m2 = file("multi-2", "two")
        let both = run(MainActor.assumeIsolated { confirmTrashReview([m1, m2]) }, "Self-test")
        check("several moves are each recorded once in the Trash log",
              both?.moved.count == 2 && entries(m1) == 1 && entries(m2) == 1)
        check("each of them can be put back", putBack(m1) && putBack(m2)
              && (try? String(contentsOf: m2, encoding: .utf8)) == "two")

        // Interrupted after the first move: the first is recorded, the second untouched.
        let i1 = file("interrupt-1", "first"), i2 = file("interrupt-2", "second")
        AppCleanup.afterRecording = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let interrupted = run(MainActor.assumeIsolated { confirmTrashReview([i1, i2]) }, "Self-test")
        AppCleanup.afterRecording = nil
        check("an interruption after the first move keeps its record and leaves the second alone",
              interrupted?.moved.keys.sorted() == [i1.path] && entries(i1) == 1 && fm.fileExists(atPath: i2.path)
              && interrupted?.report?.wasCancelled == true)
        check("the interrupted batch's moved item can be put back",
              putBack(i1) && (try? String(contentsOf: i1, encoding: .utf8)) == "first")

        #if MACCLEANER_TEST_HOOKS
        // Every destructive child process is gated on its own report of where its Trash moves go.
        if subprocessTrashIsIsolated() {
            // Killed (SIGKILL) right after the first move was recorded, in a separate process.
            let k1 = file("killed-1", "first"), k2 = file("killed-2", "second")
            let child = Process()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["--selftest-child", "trash-then-die", k1.path, k2.path]
            child.environment = ProcessInfo.processInfo.environment.merging(
                ["MACCLEANER_SELFTEST_CHILD": "1", "MACCLEANER_TEST_TRASH_DIR": isolatedTrash.path]) { _, new in new }
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            var started = true
            do { try child.run(); child.waitUntilExit() } catch { started = false }
            check("a process killed mid-batch dies after its first move (simulated crash)",
                  started && child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
            check("the killed process's first move is in the Trash log, the second item untouched",
                  !fm.fileExists(atPath: k1.path) && entries(k1) == 1 && fm.fileExists(atPath: k2.path))
            let killedTrashed = TrashLog.shared.present().first { $0.original == AppCleanup.physicalPath(k1) }?.trashed
            check("the killed process moved it into the self-test's isolated Trash, not the real Trash",
                  inIsolatedTrash(killedTrashed))
            check("Put Back restores the first move after the crash",
                  putBack(k1) && (try? String(contentsOf: k1, encoding: .utf8)) == "first")
        }
        #else
        print("  - SIGKILL crash test: runs in the test-hooks build only (scripts/build-test-hooks.sh, then the self-test)")
        #endif

        // A record that can't be written stops the run and is reported, never shown as a recoverable success.
        let f1 = file("unrecorded-1", "reviewed"), f2 = file("unrecorded-2", "reviewed")
        let saved = AppCleanup.recordMove
        AppCleanup.recordMove = { _, _, _, _, _ in false }
        let failed = run(MainActor.assumeIsolated { confirmTrashReview([f1, f2]) }, "Self-test")
        AppCleanup.recordMove = saved
        let f1Message = failed?.problems.first { $0.id == f1.path }?.message ?? ""
        check("a move whose record can't be written is reported as not restorable from Mac Cleaner",
              failed?.moved[f1.path] != nil && f1Message.contains("couldn't be recorded for Put Back") && entries(f1) == 0)
        check("after a failed record, the rest are left alone and say why",
              fm.fileExists(atPath: f2.path)
              && failed?.problems.first { $0.id == f2.path }?.message == AppCleanup.unrecordedStop)
        // Put the unrecorded file back by hand (the report says where it went).
        if case .trashed(_, let where_)? = failed?.report?.outcomes.first(where: { $0.candidateID == f1.path })?.result {
            try? fm.moveItem(atPath: where_, toPath: f1.path)
        }
        check("the unrecorded file was where the report said", fm.fileExists(atPath: f1.path))
    }

    // MARK: Shared files: checked writes need the lock

    static func sharedFileLocking(dir: URL) {
        let fm = FileManager.default
        struct Row: Codable { let n: Int }
        func count(_ f: URL) -> Int { (SharedFile.read(f) as [Row]).count }

        // The lock file can't be opened (a folder is in its place).
        let noLock = dir.appendingPathComponent("no-lock.json")
        try? fm.createDirectory(atPath: noLock.path + ".lock", withIntermediateDirectories: true)
        let refused = SharedFile.commit(noLock) { (rows: inout [Row]) in rows.append(Row(n: 1)); return true }
        check("a checked write fails, writing nothing, when the lock file can't be opened",
              !refused && !fm.fileExists(atPath: noLock.path))
        check("a Trash log record fails the same way (so the run stops and says so)",
              !TrashLog(file: noLock).record(original: "/x", trashed: "/y", size: 1, source: "Self-test", restorable: true)
              && !fm.fileExists(atPath: noLock.path))
        SharedFile.update(noLock) { (rows: inout [Row]) in rows.append(Row(n: 1)); return true }
        check("existing unchecked writers keep their old behavior (written without the lock)", count(noLock) == 1)

        // The lock can't be taken (flock fails).
        let noFlock = dir.appendingPathComponent("no-flock.json")
        let realLock = SharedFile.lockCall
        SharedFile.lockCall = { _, _ in errno = ENOLCK; return -1 }
        let refused2 = SharedFile.commit(noFlock) { (rows: inout [Row]) in rows.append(Row(n: 1)); return true }
        SharedFile.lockCall = realLock
        check("a checked write fails, writing nothing, when the lock can't be taken", !refused2 && !fm.fileExists(atPath: noFlock.path))

        // Many writers at once (separate open lock files conflict, like separate processes): nothing is lost.
        let busy = dir.appendingPathComponent("busy.json")
        let failures = Box(0)
        DispatchQueue.concurrentPerform(iterations: 12) { w in
            for i in 0..<25 {
                if w % 3 == 0 {
                    SharedFile.update(busy) { (rows: inout [Row]) in rows.append(Row(n: w * 100 + i)); return true }
                } else if !SharedFile.commit(busy, { (rows: inout [Row]) in rows.append(Row(n: w * 100 + i)); return true }) {
                    failures.mutate { $0 += 1 }
                }
            }
        }
        check("concurrent checked and unchecked writers lose no entry", count(busy) == 300 && failures.value == 0)
    }

    // MARK: MCP and CLI Trash through the executor (M01-04b-2)

    static func mcpAndCLITrash(dir: URL, runID: String) {
        print("MCP and CLI Trash: preview snapshot → verified confirm → executor (M01-04b-2)")
        let fm = FileManager.default
        func file(_ name: String, _ text: String = "x") -> URL {
            let u = dir.appendingPathComponent("\(name)-\(runID).txt")
            try? Data(text.utf8).write(to: u)
            return u
        }
        func log(_ u: URL) -> [TrashedItem] { TrashLog.shared.present().filter { $0.original == AppCleanup.physicalPath(u) } }
        func putBack(_ u: URL) -> Bool { log(u).first.map { TrashOps.restore($0) == nil } ?? false }
        func previewID(_ paths: [URL]) -> String {
            ((try? MCPServer.call("move_to_trash", ["paths": paths.map(\.path)])) as? [String: Any])?["preview_id"] as? String ?? ""
        }
        func confirm(_ paths: [URL], _ id: String, _ approval: ToolApproval? = nil) -> [String: Any]? {
            (try? MCPServer.call("move_to_trash", ["paths": paths.map(\.path), "confirm": true, "preview_id": id],
                                 approval: approval)) as? [String: Any]
        }
        let outstanding = { wait { await AppCleanup.executor.outstandingApprovals } ?? -1 }
        defer { installTestApprover() }

        check("who confirmed is mapped exactly: window → MCP prompt, typed yes → terminal, --yes → override",
              ToolConfirmation.approver(for: nil) == .userViaMCPPrompt
              && ToolConfirmation.approver(for: .terminal) == .userInTerminal
              && ToolConfirmation.approver(for: .yesFlag) == .nonInteractiveOverride)

        // Approved in Mac Cleaner's window: moved through the executor, logged as the AI assistant, put back.
        let a = file("mcp-ok", "ok")
        approvals.asked = []; approvals.answer = true
        let ok = confirm([a], previewID([a]))
        check("an MCP confirm the person approves moves the file and answers as before",
              (ok?["moved_to_trash"] as? [String]) == [Scanner.tilde(a)] && (ok?["errors"] as? [String])?.isEmpty == true
              && !fm.fileExists(atPath: a.path) && approvals.asked.count == 1)
        check("the MCP move went into the self-test's isolated Trash", inIsolatedTrash(log(a).first?.trashed))
        check("it is logged once, as the AI assistant, and Put Back restores it",
              log(a).count == 1 && log(a).first?.source == "AI assistant" && putBack(a)
              && (try? String(contentsOf: a, encoding: .utf8)) == "ok")

        // Declined in the window: no executor approval, nothing moved.
        let d = file("mcp-declined")
        let before = outstanding()
        approvals.answer = false
        check("a declined MCP confirm issues no approval and moves nothing",
              confirm([d], previewID([d])) == nil && fm.fileExists(atPath: d.path) && outstanding() == before)

        // Replayed: the preview (and so its approval) can be used once.
        approvals.answer = true
        let r = file("mcp-replay")
        let rID = previewID([r])
        _ = confirm([r], rID)
        _ = putBack(r)
        check("a replayed MCP confirm is refused and moves nothing", confirm([r], rID) == nil && fm.fileExists(atPath: r.path))

        // Changed or replaced while the person was looking at the window (after the digest check).
        let s = file("mcp-stale")
        HumanApproval.ask = { _ in try? Data("written while asking".utf8).write(to: s); return true }
        let stale = confirm([s], previewID([s]))
        check("a file changed during the confirmation is left alone and reported",
              (stale?["moved_to_trash"] as? [String])?.isEmpty == true
              && (stale?["errors"] as? [String])?.first?.contains("changed after you reviewed") == true
              && (try? String(contentsOf: s, encoding: .utf8)) == "written while asking")
        let p = file("mcp-replaced", "v1")
        HumanApproval.ask = { _ in try? fm.removeItem(at: p); try? Data("v2".utf8).write(to: p); return true }
        let replaced = confirm([p], previewID([p]))
        installTestApprover(); approvals.answer = true
        check("a file replaced during the confirmation is left alone and reported",
              (replaced?["moved_to_trash"] as? [String])?.isEmpty == true && (replaced?["errors"] as? [String])?.count == 1
              && (try? String(contentsOf: p, encoding: .utf8)) == "v2")

        // Partial failure: one moves, one can't.
        let free = file("mcp-free"), locked = file("mcp-locked")
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        let partial = confirm([free, locked], previewID([free, locked]))
        chflags(locked.path, 0)
        check("an MCP partial failure moves what it can and reports the rest",
              (partial?["moved_to_trash"] as? [String]) == [Scanner.tilde(free)] && (partial?["errors"] as? [String])?.count == 1
              && fm.fileExists(atPath: locked.path) && log(locked).isEmpty)
        check("the moved one can be put back", putBack(free))

        // Terminal: typed yes vs --yes are recorded differently.
        let t = file("cli-typed"), y = file("cli-yes-flag")
        approvals.asked = []
        _ = confirm([t], previewID([t]), .terminal)
        _ = confirm([y], previewID([y]), .yesFlag)
        check("a typed yes is logged as the command line", log(t).first?.source == "Command line")
        check("--yes is logged as a non-interactive override, not as a person",
              log(y).first?.source == "Command line (--yes, not confirmed by a person)")
        check("terminal confirms open no confirmation window", approvals.asked.isEmpty)
        _ = putBack(t); _ = putBack(y)

        // The real command line, in a separate process (same throwaway home).
        func cli(_ args: [String]) -> (code: Int32, out: String) {
            let p = Process()
            p.executableURL = Bundle.main.executableURL
            p.arguments = ["--cli"] + args
            #if MACCLEANER_TEST_HOOKS
            p.environment = ProcessInfo.processInfo.environment.merging(["MACCLEANER_TEST_TRASH_DIR": isolatedTrash.path]) { _, new in new }
            #endif
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (-1, "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        // Moved, but the Put Back record couldn't be written: the answer must say both, and the rest stay untouched.
        func recovery(_ message: String) -> String? {
            guard let open = message.range(of: "moved to the Trash ("), let close = message.range(of: "), but") else { return nil }
            return String(message[open.upperBound..<close.lowerBound])
        }
        let u1 = file("mcp-unrecorded-1", "one"), u2 = file("mcp-unrecorded-2", "two")
        let saved = AppCleanup.recordMove
        AppCleanup.recordMove = { _, _, _, _, _ in false }
        let unrecorded = confirm([u1, u2], previewID([u1, u2]))
        AppCleanup.recordMove = saved
        let uErrors = unrecorded?["errors"] as? [String] ?? []
        let u1Error = uErrors.first { $0.hasPrefix(Scanner.tilde(u1) + ":") } ?? ""
        check("MCP reports a move whose Put Back record failed as moved AND as an error",
              (unrecorded?["moved_to_trash"] as? [String]) == [Scanner.tilde(u1)]
              && u1Error.contains("couldn't be recorded for Put Back") && !fm.fileExists(atPath: u1.path) && log(u1).isEmpty)
        check("MCP leaves the rest untouched after a failed record and says why",
              fm.fileExists(atPath: u2.path) && uErrors.contains("\(Scanner.tilde(u2)): \(AppCleanup.unrecordedStop)"))
        if let where_ = recovery(u1Error) { try? fm.moveItem(atPath: where_, toPath: u1.path) }
        check("the unrecorded MCP move was where the answer said", fm.fileExists(atPath: u1.path))

        let c = file("cli-real", "cli")
        let noYes = cli(["trash-files", c.path])
        check("the CLI without --yes and without a keyboard changes nothing and exits 2",
              noYes.code == 2 && fm.fileExists(atPath: c.path))
        #if MACCLEANER_TEST_HOOKS
        if subprocessTrashIsIsolated() {
            // A separate process moves files: only the test-hooks build can point its Trash at the isolated folder
            // (MACCLEANER_TEST_TRASH_DIR); the Release app always uses the real Trash, so it skips these.
            let withYes = cli(["trash-files", c.path, "--yes", "--json"])
            check("the CLI with --yes moves the file, exits 0, and answers as before",
                  withYes.code == 0 && !fm.fileExists(atPath: c.path) && withYes.out.contains("moved_to_trash"))
            check("the CLI process moved it into the self-test's isolated Trash (its Trash log says so)",
                  inIsolatedTrash(log(c).first?.trashed))
            check("the CLI's --yes move is logged as an override and Put Back restores it",
                  log(c).first?.source == "Command line (--yes, not confirmed by a person)" && putBack(c)
                  && (try? String(contentsOf: c, encoding: .utf8)) == "cli")

            // The same through the real CLI (a separate process): make its Trash log unwritable (a folder where the
            // log's lock file goes), so its record fails closed, then read its JSON answer.
            let logDir = SafetyGuard.home.appendingPathComponent("Library/Application Support/Mac Cleaner")
            let lockBlocker = logDir.appendingPathComponent("trash-log.json.lock")
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            let hadLock = fm.fileExists(atPath: lockBlocker.path)
            if hadLock { try? fm.removeItem(at: lockBlocker) }
            try? fm.createDirectory(at: lockBlocker, withIntermediateDirectories: false)
            let k1 = file("cli-unrecorded-1", "one"), k2 = file("cli-unrecorded-2", "two")
            let blocked = cli(["trash-files", k1.path, k2.path, "--yes", "--json"])
            try? fm.removeItem(at: lockBlocker)
            // With --json the CLI prints the preview, then the result: read the last JSON document.
            let last = blocked.out.range(of: "\n{", options: .backwards).map { String(blocked.out[$0.lowerBound...]) } ?? blocked.out
            let answer = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
            let kErrors = answer?["errors"] as? [String] ?? []
            let k1Error = kErrors.first { $0.hasPrefix(Scanner.tilde(k1) + ":") } ?? ""
            check("the CLI's JSON answer reports the move AND the missing Put Back record",
                  (answer?["moved_to_trash"] as? [String]) == [Scanner.tilde(k1)] && k1Error.contains("couldn't be recorded for Put Back")
                  && !fm.fileExists(atPath: k1.path))
            check("the CLI leaves the rest untouched after a failed record and says why",
                  fm.fileExists(atPath: k2.path) && kErrors.contains("\(Scanner.tilde(k2)): \(AppCleanup.unrecordedStop)"))
            check("the unrecorded CLI move went into the isolated Trash (its answer says where)", inIsolatedTrash(recovery(k1Error)))
            if let where_ = recovery(k1Error) { try? fm.moveItem(atPath: where_, toPath: k1.path) }
            check("the unrecorded CLI move was where the answer said", fm.fileExists(atPath: k1.path))
        }
        #else
        print("  - CLI moves in a separate process: run in the test-hooks build only (its Trash is isolated there)")
        #endif
    }

    // MARK: The Shredder review: snapshots, protection over every entry, overlap, outcome mapping (M01-04c-2)

    static func shredReview(dir: URL, runID: String, savedProtected: [String]) {
        print("Shredder review: one snapshot per item, protection over every entry, outcome mapping (M01-04c-2)")
        let fm = FileManager.default
        let base = dir.appendingPathComponent("shred-review-\(runID)")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { ProtectedPaths.set(savedProtected) }
        func file(_ u: URL, _ text: String = "x") -> URL {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: u)
            return u
        }

        // rootState: gone / same / other (a different file put at the same path)
        let f = file(base.appendingPathComponent("state.txt"), "one")
        let planned = (try? LocalFileSystem().identity(at: AppCleanup.physicalPath(f))) ?? nil
        guard let planned else { check("rootState: could read the planned file", false); return }
        check("rootState: the same file is .same", ShredReview.rootState(planned) == .same)
        try? Data("changed and longer".utf8).write(to: f)   // damaged in place: still the same file
        check("rootState: a file changed in place is still .same", ShredReview.rootState(planned) == .same)
        try? fm.removeItem(at: f)
        check("rootState: a removed file is .gone", ShredReview.rootState(planned) == .gone)
        _ = file(f, "other")
        check("rootState: a different file at the same path is .other", ShredReview.rootState(planned) == .other)
        check("rootState: a path below a plain file is .gone (ENOTDIR)",
              ShredReview.rootState(FileIdentity(path: AppCleanup.physicalPath(f) + "/x", device: 1, inode: 1, kind: .file, size: 0, modificationNanos: 0)) == .gone)

        // classify, with real outcome types
        func id(_ path: String, _ kind: FileIdentity.Kind = .file) -> FileIdentity {
            FileIdentity(path: path, device: 1, inode: UInt64(path.hashValue & 0xffff), kind: kind, size: 1, modificationNanos: 0)
        }
        let parent = id(base.path, .directory), root = id(base.path + "/item", .directory)
        let tree = CleanupTarget.tree(parent: parent, root: root, entries: [id(base.path + "/item/a"), id(base.path + "/item/b")])
        func outcome(_ r: ItemOutcome.Result, files: Int? = nil, warnings: [String] = []) -> ItemOutcome {
            ItemOutcome(candidateID: "c", target: tree, result: r, warnings: warnings, removedFiles: files)
        }
        func c(_ r: ItemOutcome.Result, _ s: ShredReview.RootState, files: Int? = nil, warnings: [String] = []) -> ShredReview.ShredItemResult {
            ShredReview.classify(outcome: outcome(r, files: files, warnings: warnings), planned: tree, rootState: s)
        }
        let note = ShredReview.otherItemNote
        let removedGone = c(.removed(bytes: 7), .gone, files: 2, warnings: ["w"])
        check("classify: removed and gone is shredded, row removed, bytes and warnings carried",
              removedGone.countedBytes == 7 && removedGone.disposition == .remove && removedGone.removedAnything && removedGone.warnings == ["w"])
        for s in [ShredReview.RootState.same, .other, .unknown] {
            let r = c(.removed(bytes: 7), s)
            check("classify: removed but something is at the path (\(s)) counts it and blocks the row",
                  r.countedBytes == 7 && r.disposition == .block(ShredReview.note(for: s)) && r.removedAnything)
        }
        let staging = KeptEntry(path: base.path + "/.maccleaner-shred-x", reason: .stagingLeftBehind)
        let stagingOnly = c(.partiallyDone(freedBytes: 5, kept: [staging], damaged: []), .gone, files: 2)
        check("classify: only the work folder left, root gone: shredded, says where the folder is",
              stagingOnly.disposition == .remove && stagingOnly.countedBytes == 5 && stagingOnly.message.contains(staging.path)
              && stagingOnly.message.contains("work folder"))
        let stagingFewFiles = c(.partiallyDone(freedBytes: 5, kept: [staging], damaged: []), .gone, files: 1)
        check("classify: a work folder left but not every file removed is partial, not 'shredded'",
              stagingFewFiles.message.contains("partly") && stagingFewFiles.disposition == .remove)
        let stagingNilFiles = c(.partiallyDone(freedBytes: 5, kept: [staging], damaged: []), .gone)
        check("classify: unknown file count is never trusted as complete", stagingNilFiles.message.contains("partly"))
        let stagingSame = c(.partiallyDone(freedBytes: 5, kept: [staging], damaged: []), .same, files: 2)
        check("classify: work folder left but the root is still there is partial and keeps the row",
              stagingSame.disposition == .keep && stagingSame.message.contains("partly"))
        let keptA = KeptEntry(path: base.path + "/item/a", reason: .failed("locked"))
        let partialSame = c(.partiallyDone(freedBytes: 3, kept: [keptA], damaged: [base.path + "/item/b"]), .same, files: 0)
        check("classify: partial with the root still there keeps the row and lists kept and damaged entries",
              partialSame.disposition == .keep && partialSame.countedBytes == 3 && partialSame.removedAnything
              && partialSame.message.contains(keptA.path) && partialSame.message.contains("item/b"))
        check("classify: partial with the root gone removes the row",
              c(.partiallyDone(freedBytes: 3, kept: [keptA], damaged: []), .gone, files: 1).disposition == .remove)
        check("classify: an unknown root state has its own note",
              ShredReview.note(for: .unknown) == "Couldn't check what is at this path now; it was not touched"
              && ShredReview.note(for: .other) == note && ShredReview.unknownItemNote != note)
        for s in [ShredReview.RootState.other, .unknown] {
            let r = c(.partiallyDone(freedBytes: 3, kept: [keptA], damaged: []), s, files: 1)
            check("classify: partial with a different or unknown item at the root (\(s)) blocks the row",
                  r.disposition == .block(ShredReview.note(for: s)) && r.message.contains(ShredReview.note(for: s)))
        }
        let emptyPartial = c(.partiallyDone(freedBytes: 0, kept: [], damaged: []), .same)
        check("classify: a partial outcome with nothing listed doesn't crash and counts nothing",
              emptyPartial.countedBytes == 0 && !emptyPartial.removedAnything && emptyPartial.disposition == .keep)
        check("classify: skipped (missing) removes the row, counts nothing",
              c(.skipped(.missing), .gone).disposition == .remove && c(.skipped(.missing), .gone).countedBytes == 0
              && c(.skipped(.missing), .gone).message.contains("no longer there"))
        let missingOther = c(.skipped(.missing), .other), missingUnknown = c(.skipped(.missing), .unknown)
        let missingSame = c(.skipped(.missing), .same)
        check("classify: skipped (missing) with a different item now at the path blocks the row, never removes it",
              missingOther.disposition == .block(ShredReview.otherItemNote) && missingOther.countedBytes == 0
              && !missingOther.removedAnything && missingOther.message.contains("different item"))
        check("classify: skipped (missing) when the path can't be checked blocks the row, never removes it",
              missingUnknown.disposition == .block(ShredReview.unknownItemNote) && missingUnknown.countedBytes == 0
              && missingUnknown.message.contains("Couldn't check"))
        check("classify: skipped (missing) with the reviewed item back at the path keeps the row",
              missingSame.disposition == .keep && missingSame.countedBytes == 0 && !missingSame.removedAnything)
        let changed = c(.skipped(.changed(.replaced)), .same)
        check("classify: skipped (changed) keeps the row and counts nothing", changed.disposition == .keep && changed.countedBytes == 0 && !changed.removedAnything)
        let unexpected = c(.trashed(bytes: 9, recoveryPath: "/x"), .gone)
        check("classify: a Trash result for a shred is unexpected: counts nothing, keeps the row, says where to look",
              unexpected.countedBytes == 0 && unexpected.disposition == .keep && !unexpected.removedAnything
              && unexpected.message == "Unexpected result; check \(root.path)")
        let failed = c(.failed("can't be read"), .same)
        check("classify: failed keeps the row, counts nothing, says nothing was changed",
              failed.disposition == .keep && failed.countedBytes == 0 && failed.message.contains("Nothing was changed"))
        let already = c(.failed("it stopped. Nothing was changed."), .same)
        check("classify: doesn't repeat 'Nothing was changed'",
              already.message.components(separatedBy: "othing was changed").count == 2)
        check("classify: permission denied keeps the row, counts nothing",
              c(.permissionDenied("no access"), .same).disposition == .keep && c(.permissionDenied("no access"), .same).countedBytes == 0)

        // ShredReview.snapshots: protection, strict links, overlap, one snapshot per item
        let home = SafetyGuard.home
        let protectedDir = base.appendingPathComponent("protected-dir")
        _ = file(protectedDir.appendingPathComponent("secret.txt"))
        let withLink = base.appendingPathComponent("with-link")
        _ = file(withLink.appendingPathComponent("a.txt"))
        try? fm.createSymbolicLink(at: withLink.appendingPathComponent("to-protected"), withDestinationURL: protectedDir)
        let plain = base.appendingPathComponent("plain")
        _ = file(plain.appendingPathComponent("inner/b.txt"))
        let inner = plain.appendingPathComponent("inner")
        let single = file(base.appendingPathComponent("single.txt"))
        ProtectedPaths.set(savedProtected + [protectedDir.path])
        var calls: [String] = []
        let counted: ShredReview.Snapshotter = { calls.append($0); return LocalFileSystem().shredSnapshot(at: $0) }
        let rows = ShredReview.snapshots([("p", protectedDir), ("l", withLink), ("plain", plain), ("inner", inner),
                                          ("s1", single), ("s2", single), ("ok", file(base.appendingPathComponent("ok.txt")))],
                                         shredSnapshotter: counted)
        func row(_ id: String) -> ShredReviewRow? { rows.first { $0.id == id } }
        check("snapshots: a protected root is blocked and never snapshotted", row("p")?.blockedReason != nil && !calls.contains(AppCleanup.physicalPath(protectedDir)))
        check("snapshots: a link inside that points at a protected path blocks the item", row("l")?.blockedReason != nil && row("l")?.snapshot == nil)
        check("snapshots: a plain item is ready, with a candidate and display bytes",
              row("plain")?.snapshot != nil && row("plain")?.candidate?.targets.count == 1 && (row("plain")?.allocatedBytes ?? 0) > 0)
        check("snapshots: an item inside another is blocked as already included", row("inner")?.blockedReason == "Already included in plain" && row("plain")?.snapshot != nil)
        check("snapshots: the same item twice is blocked once", row("s1")?.snapshot != nil && row("s2")?.blockedReason == "Already included in single.txt")
        check("snapshots: an unrelated item stays ready", row("ok")?.snapshot != nil)
        let expected = [withLink, plain, inner, single, single, base.appendingPathComponent("ok.txt")].map { AppCleanup.physicalPath($0) }
        check("snapshots: the snapshot function ran exactly once per item that reached it", calls == expected)
        check("snapshots: nothing in the review changed any file", fm.fileExists(atPath: single.path) && fm.fileExists(atPath: protectedDir.appendingPathComponent("secret.txt").path))
        _ = home
    }

    // MARK: The Shredder screen end to end: review off the main thread, approval, executor (M01-04c-2)

    static func shredScreen(dir: URL, runID: String, savedProtected: [String]) {
        print("Shredder screen: review → approval → executor → list, History and message (M01-04c-2)")
        let fm = FileManager.default
        let base = dir.appendingPathComponent("shred-screen-\(runID)")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { ProtectedPaths.set(savedProtected) }
        @discardableResult func make(_ rel: String, _ text: String = "data") -> URL {
            let u = base.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: u)
            return u
        }
        func spin(_ done: () -> Bool) {
            let end = Date().addingTimeInterval(30)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
        func shredRecords() -> [CleanupRecord] { MainActor.assumeIsolated { HistoryStore.shared.records.filter { $0.title == "Files Shredded" } } }
        @MainActor func review(_ m: ShredderModel, _ urls: [URL]) -> ReviewRequest? {
            m.add(urls)
            let got = Slot<ReviewRequest>()
            m.prepareReview { got.value = $0 }
            spin { got.value != nil }
            return got.value
        }
        @MainActor func confirm(_ m: ShredderModel, _ r: ReviewRequest) {
            m.message = nil
            ReviewConfirmation.confirm(r)
            spin { m.message != nil }
        }
        let recordsAtStart = shredRecords().count

        MainActor.assumeIsolated {
            // 1. An approved folder with sub-folders
            let m1 = ShredderModel()
            let tree = make("tree/a.txt", String(repeating: "a", count: 5000))
            make("tree/sub/deep/b.txt", String(repeating: "b", count: 5000))
            let base1 = base.appendingPathComponent("tree")
            guard let r1 = review(m1, [base1]) else { check("review: the sheet was presented", false); return }
            check("review: the sheet lists the item ready with its measured size and a shred plan",
                  r1.items.first?.blocked == nil && (r1.items.first?.size ?? 0) > 0 && r1.trashPlan != nil
                  && m1.items.first?.isPreview == false && !m1.preparing)
            check("review: the plan's disposition is overwrite-then-delete for module shredder",
                  r1.trashPlan?.entries.allSatisfy { $0.disposition == .overwriteThenDelete && $0.candidate.module == "shredder" } == true)
            confirm(m1, r1)
            check("an approved shred removes the folder and its sub-folders and the row", !fm.fileExists(atPath: base1.path) && m1.items.isEmpty)
            let recs = shredRecords()
            let newest = recs.max { $0.date < $1.date }
            check("History has 'Files Shredded' with the report's estimate and a measured free-space change",
                  recs.count == recordsAtStart + 1 && newest?.outcome == .deleted && m1.lastReport != nil
                  && newest?.bytes == m1.lastReport?.freedBytes && (newest?.bytes ?? 0) > 0 && newest?.measuredFreeChange != nil)
            check("the message says 'about' and isn't an error", m1.message?.text.contains("Overwrote and deleted about") == true && m1.message?.isError == false)
            _ = tree

            // 2. Everything blocked: nothing runs
            let m2 = ShredderModel()
            let hard1 = make("blk/hard1.txt"), hard2 = base.appendingPathComponent("blk/hard2.txt")
            link(hard1.path, hard2.path)
            let locked = make("blk/locked.txt")
            chflags(locked.path, UInt32(UF_IMMUTABLE))
            let target = make("blk/target.txt")
            let lnk = base.appendingPathComponent("blk/lnk")
            try? fm.createSymbolicLink(at: lnk, withDestinationURL: target)
            let outside = URL(fileURLWithPath: "/private/tmp/maccleaner-selftest-\(runID)-x")
            let r2 = review(m2, [hard1, locked, lnk, outside])
            check("review: a hard link, a locked file, a link as the item and an item outside home are all blocked rows",
                  r2?.items.count == 4 && r2?.items.allSatisfy { $0.blocked != nil } == true && m2.ready.isEmpty)
            check("review: with no ready row there is no plan, so confirm has nothing to approve", r2?.trashPlan == nil && r2?.allowed.isEmpty == true)
            if let r2 { confirm(m2, r2) }
            check("a nil approval shreds nothing and says so",
                  m2.message?.text.hasPrefix("Nothing was shredded") == true && m2.message?.isError == true
                  && [hard1, hard2, locked, target].allSatisfy { fm.fileExists(atPath: $0.path) } && text(hard1) == "data")
            chflags(locked.path, 0)

            // 3. A refused approval
            let m3 = ShredderModel()
            let t3 = make("t3/a.txt")
            if let r3 = review(m3, [base.appendingPathComponent("t3")]), let plan = r3.trashPlan {
                m3.message = nil
                Task { @MainActor in await m3.shred(rows: [], approval: .refused(plan: plan, reason: "No approval was issued")) }
                spin { m3.message != nil }
                check("a refused approval shreds nothing and says why",
                      m3.message?.text.contains("Nothing was shredded") == true && m3.message?.text.contains("No approval was issued") == true
                      && text(t3) == "data" && m3.items.count == 1)
            } else { check("refused approval: review was built", false) }

            // 4. Edited between review and confirm
            let m4 = ShredderModel()
            make("t4/keep.txt", "untouched"); let edited = make("t4/edit.txt", "reviewed")
            if let r4 = review(m4, [base.appendingPathComponent("t4")]) {
                try? Data("reviewed and then edited".utf8).write(to: edited)
                confirm(m4, r4)
                check("a file edited after review is kept, reported, and the row stays",
                      text(edited) == "reviewed and then edited" && m4.message?.isError == true && m4.items.count == 1
                      && fm.fileExists(atPath: base.appendingPathComponent("t4").path))
            } else { check("edited after review: review was built", false) }

            // 5. Protected after review
            let m5 = ShredderModel()
            let t5 = make("t5/a.txt")
            if let r5 = review(m5, [base.appendingPathComponent("t5")]) {
                ProtectedPaths.set(savedProtected + [base.appendingPathComponent("t5").path])
                confirm(m5, r5)
                ProtectedPaths.set(savedProtected)
                check("an item protected after review is skipped and nothing is touched",
                      text(t5) == "data" && m5.message?.isError == true && m5.items.count == 1)
            } else { check("protected after review: review was built", false) }

            // 6. Changed between add and review: the sheet shows the fresh size or blocked state, not the preview
            let m6 = ShredderModel()
            let f6 = make("t6/grow.txt", "tiny"), f6b = make("t6/later-linked.txt")
            m6.add([f6, f6b])
            check("add: rows appear at once, sized off the main thread (preview, not reviewed)",
                  m6.items.count == 2 && m6.items.allSatisfy { $0.isPreview && $0.blocked == nil })
            try? Data(repeating: 7, count: 300_000).write(to: f6)
            link(f6b.path, base.appendingPathComponent("t6/other-name").path)
            let got6 = Slot<ReviewRequest>()
            m6.prepareReview { got6.value = $0 }
            let busyAdd = { m6.add([base.appendingPathComponent("t6/x")]); return m6.items.count }()
            check("while a review is prepared, Add does nothing and the model is busy", m6.preparing && busyAdd == 2 && m6.busy)
            spin { got6.value != nil }
            let grown = got6.value?.items.first { $0.id == f6.path }
            check("review: the sheet shows the item's fresh size, not the preview",
                  (grown?.size ?? 0) >= 300_000 && m6.items.first { $0.id == f6.path }?.isPreview == false)
            check("review: an item that became a hard link after it was added is blocked now",
                  got6.value?.items.first { $0.id == f6b.path }?.blocked != nil && m6.items.first { $0.id == f6b.path }?.blocked != nil)

            // 7. The builder's perform does nothing
            let rows7 = ShredReview.snapshots([(id: "p", url: make("t7/a.txt"))])
            let called = Slot<Bool>()
            let req7 = ReviewBuild.shred(rows: rows7) { _, _ in called.value = true }
            req7.perform(["p"])
            check("builder: perform does nothing; only the approved path runs the model", called.value == nil && text(base.appendingPathComponent("t7/a.txt")) == "data")
            check("builder: the request is the permanent, acknowledged 'Shred' review",
                  req7.verb == "Shred" && req7.needsAcknowledgement && req7.items.first?.note == "cannot be recovered"
                  && req7.items.first?.size == rows7.first?.allocatedBytes)

            // 8. Root replaced after shredding: the replacement stays, blocked, untouched
            let x8 = make("t8/x.txt", "reviewed")
            let rows8 = ShredReview.snapshots([(id: x8.path, url: x8)])
            if let plan8 = ReviewBuild.shred(rows: rows8, perform: { _, _ in }).trashPlan, let target8 = plan8.candidates.first?.targets.first {
                let m8 = ShredderModel()
                m8.add([x8])
                try? fm.removeItem(at: x8)
                make("t8/x.txt", "a new file that must survive")
                let out = ItemOutcome(candidateID: x8.path, target: target8, result: .removed(bytes: 100), removedFiles: 1)
                let rep8 = CleanupReport(planDigest: plan8.digest, outcomes: [out], wasCancelled: false)
                m8.finish(report: rep8, plan: plan8, rootStates: ShredderModel.rootStates(report: rep8, plan: plan8), freeBefore: 0, freeAfter: 0)
                check("a different item at the path after shredding stays in the list, blocked, and is untouched",
                      text(x8) == "a new file that must survive" && m8.items.first?.blocked == ShredReview.otherItemNote
                      && m8.message?.text.contains("different item") == true)
            } else { check("replaced root: plan was built", false) }

            // 8b. Missing at execution, then a different item appeared at the path: the row stays, blocked, untouched
            let x8b = make("t8b/x.txt", "reviewed")
            let rows8b = ShredReview.snapshots([(id: x8b.path, url: x8b)])
            if let plan8b = ReviewBuild.shred(rows: rows8b, perform: { _, _ in }).trashPlan, let target8b = plan8b.candidates.first?.targets.first {
                let m8b = ShredderModel()
                m8b.add([x8b])
                try? fm.removeItem(at: x8b)
                make("t8b/x.txt", "appeared after the item went missing")
                let out = ItemOutcome(candidateID: plan8b.candidates[0].id, target: target8b, result: .skipped(.missing))
                let rep8b = CleanupReport(planDigest: plan8b.digest, outcomes: [out], wasCancelled: false)
                let states8b = ShredderModel.rootStates(report: rep8b, plan: plan8b)
                let before8b = shredRecords().count
                m8b.finish(report: rep8b, plan: plan8b, rootStates: states8b, freeBefore: 0, freeAfter: 0)
                check("missing at execution, then a different item at the path: the row stays, blocked, and the new item is untouched",
                      states8b[plan8b.candidates[0].id] == .other && m8b.items.count == 1
                      && m8b.items.first?.blocked == ShredReview.otherItemNote
                      && text(x8b) == "appeared after the item went missing"
                      && m8b.message?.text.contains("different item") == true && shredRecords().count == before8b)
                // The same outcome with the path still empty removes the row.
                try? fm.removeItem(at: x8b)
                let m8c = ShredderModel()
                m8c.add([x8b])
                m8c.finish(report: rep8b, plan: plan8b, rootStates: ShredderModel.rootStates(report: rep8b, plan: plan8b), freeBefore: 0, freeAfter: 0)
                check("missing at execution with the path still empty: the row is removed",
                      m8c.items.isEmpty && m8c.message?.text.contains("no longer there") == true)
            } else { check("missing then replaced: plan was built", false) }

            // 9. Gone, but its work folder is left behind
            let d9 = make("t9/item/a.txt")
            let rows9 = ShredReview.snapshots([(id: d9.deletingLastPathComponent().path, url: d9.deletingLastPathComponent())])
            if let plan9 = ReviewBuild.shred(rows: rows9, perform: { _, _ in }).trashPlan, let target9 = plan9.candidates.first?.targets.first {
                let m9 = ShredderModel()
                m9.add([d9.deletingLastPathComponent()])
                try? fm.removeItem(at: d9.deletingLastPathComponent())
                let staging = KeptEntry(path: base.path + "/t9/.maccleaner-shred-abc", reason: .stagingLeftBehind)
                let out = ItemOutcome(candidateID: plan9.candidates[0].id, target: target9,
                                      result: .partiallyDone(freedBytes: 50, kept: [staging], damaged: []), removedFiles: 1)
                let before = shredRecords().count
                let rep9 = CleanupReport(planDigest: plan9.digest, outcomes: [out], wasCancelled: false)
                m9.finish(report: rep9, plan: plan9, rootStates: ShredderModel.rootStates(report: rep9, plan: plan9), freeBefore: 5, freeAfter: 3)
                check("an item gone with a work folder left behind leaves the list and says where the folder is",
                      m9.items.isEmpty && m9.message?.text.contains("work folder") == true && m9.message?.text.contains(staging.path) == true
                      && m9.message?.isError == true)
                check("…and History records it with a free-space change of at least zero",
                      shredRecords().count == before + 1 && shredRecords().max { $0.date < $1.date }?.measuredFreeChange == 0)
            } else { check("leftover work folder: plan was built", false) }

            // 5b. One file inside protected after review: an item that holds a protected file is refused whole (the root check),
            // so nothing in it is touched (the executor's per-entry check is covered by the package tests)
            let m5b = ShredderModel()
            let a5b = make("t5b/a.txt", "A"), b5b = make("t5b/b.txt", "B"), c5b = make("t5b/c.txt", "C")
            if let r5b = review(m5b, [base.appendingPathComponent("t5b")]) {
                ProtectedPaths.set(savedProtected + [AppCleanup.physicalPath(b5b)])
                confirm(m5b, r5b)
                ProtectedPaths.set(savedProtected)
                check("an item holding a file protected after review is refused whole: nothing in it is touched",
                      text(a5b) == "A" && text(b5b) == "B" && text(c5b) == "C" && m5b.message?.isError == true)
            } else { check("a file protected after review: review was built", false) }

            // 10. A real partial result (#7): the second of three files is edited after review. The first is shredded,
            // the edited one and the one after it stay, and the message says how far it got.
            let m10 = ShredderModel()
            let a10 = make("t10/a.txt", "A"), b10 = make("t10/b.txt", "B"), c10 = make("t10/c.txt", "C")
            if let r10 = review(m10, [base.appendingPathComponent("t10")]) {
                try? Data("B edited after review".utf8).write(to: b10)
                confirm(m10, r10)
                let msg = m10.message?.text ?? ""
                check("a stopped shred keeps the failed file and the rest, and the row stays",
                      !fm.fileExists(atPath: a10.path) && text(b10) == "B edited after review" && text(c10) == "C" && m10.items.count == 1)
                check("a partial result says how far it got: 'stopped after N of M file(s)' and 'only partly'",
                      msg.contains("stopped after 1 of 3 file(s)") && msg.contains("1 item(s) only partly") && m10.message?.isError == true)
                check("a partial result names what was kept, at its current path", msg.contains(b10.path) || msg.contains(AppCleanup.physicalPath(b10)))
            } else { check("partial result: review was built", false) }

            // 11. A file overwritten part-way and kept (#8) is named as damaged in the message (a real outcome needs a
            // failing disk write, which only the package tests can make; the model's mapping is fed the outcome shape).
            let d11 = make("t11/item/a.txt", "AAAAAAAA"); make("t11/item/b.txt", "B")
            let rows11 = ShredReview.snapshots([(id: "t11", url: d11.deletingLastPathComponent())])
            if let plan11 = ReviewBuild.shred(rows: rows11, perform: { _, _ in }).trashPlan, let target11 = plan11.candidates.first?.targets.first {
                let m11 = ShredderModel()
                m11.add([d11.deletingLastPathComponent()])
                let out = ItemOutcome(candidateID: "t11", target: target11,
                                      result: .partiallyDone(freedBytes: 0, kept: [KeptEntry(path: AppCleanup.physicalPath(d11), reason: .failed("damaged: writing failed"))],
                                                             damaged: [AppCleanup.physicalPath(d11)]), removedFiles: 0)
                let rep11 = CleanupReport(planDigest: plan11.digest, outcomes: [out], wasCancelled: false)
                m11.finish(report: rep11, plan: plan11, rootStates: ShredderModel.rootStates(report: rep11, plan: plan11), freeBefore: 0, freeAfter: 0)
                let msg = m11.message?.text ?? ""
                check("a damaged file is named in the message and the row stays",
                      msg.contains(AppCleanup.physicalPath(d11)) && msg.contains("partly overwritten") && m11.items.count == 1
                      && m11.message?.isError == true)
            } else { check("damaged file: plan was built", false) }

            // 13. The same item spelled two ways is one row (N4)
            let dir13 = base.appendingPathComponent("t13"); make("t13/sub/a.txt")
            let m13 = ShredderModel()
            m13.add([dir13, dir13.appendingPathComponent("sub").appendingPathComponent(".."), URL(string: "file://" + dir13.path + "/")!])
            check("adding the same folder as …/dir, …/dir/sub/.. and …/dir/ gives one row, id = its standardized path",
                  m13.items.count == 1 && m13.items.first?.id == dir13.standardizedFileURL.path)

            // 14. A review with some rows blocked: the allowed ids are exactly the plan's candidates (N9)
            let m14 = ShredderModel()
            let ok14 = make("t14/ok.txt"), hl14 = make("t14/hard.txt")
            link(hl14.path, base.appendingPathComponent("t14-alias").path)
            let ok14b = make("t14/ok2/b.txt")
            if let r14 = review(m14, [ok14, hl14, ok14b.deletingLastPathComponent()]) {
                check("mixed review: the allowed row ids are exactly the plan's candidate ids",
                      Set(r14.allowed.map(\.id)) == Set(r14.trashPlan?.candidates.map(\.id) ?? ["no plan"])
                      && r14.allowed.count == 2 && r14.items.count == 3 && r14.items.contains { $0.blocked != nil })
            } else { check("mixed review: review was built", false) }

            // 15. A shred plan is never approved or run as a Trash move, and a Trash plan is never run as a shred (S1)
            let m15 = ShredderModel()
            let keep15 = make("t15/keep.txt", "keep")
            let rows15 = ShredReview.snapshots([(id: "k15", url: keep15)])
            let got15 = Slot<TrashApproval?>()
            let shredReq = ReviewBuild.shred(rows: rows15) { _, approval in got15.value = .some(approval) }
            check("a shred plan is refused by the Trash approval guard", shredReq.trashPlan.flatMap { AppCleanup.nonTrashRefusal($0) } != nil)
            ReviewConfirmation.confirm(shredReq)
            spin { got15.value != nil }
            if case .some(.some(let shredApproval)) = got15.value {
                let ran = wait { await AppCleanup.moveToTrash(shredApproval, source: "Self-test") }
                check("a shred-disposition plan is refused by moveToTrash and nothing is touched",
                      ran?.moved.isEmpty == true && ran?.problems.isEmpty == false && text(keep15) == "keep")
            } else { check("a shred approval was issued for the guard test", false) }
            if case .some(.some(let trashApproval)) = confirmTrashReview([make("t15/trash-me.txt", "trash")]) {
                m15.message = nil
                Task { @MainActor in await m15.shred(rows: [], approval: trashApproval) }
                spin { m15.message != nil }
                check("a Trash plan is refused by ShredderModel.shred and nothing is touched",
                      m15.message?.text.contains("isn't a shred plan") == true && text(base.appendingPathComponent("t15/trash-me.txt")) == "trash")
            } else { check("a Trash approval was issued for the guard test", false) }

            // 16. Already shredding: a second request while busy is told so, not dropped silently (N1)
            let m16 = ShredderModel()
            m16.working = true
            m16.message = nil
            Task { @MainActor in await m16.shred(rows: [], approval: nil) }
            spin { m16.message != nil }
            check("a shred requested while one is running says 'Already shredding'", m16.message?.text == "Already shredding" && m16.working)
        }

        // 12. No shred work folder is left anywhere in the self-test area (#23).
        let leftover = (fm.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
            .filter { ($0 as NSString).lastPathComponent.hasPrefix(LocalFileSystem.shredStagingPrefix) }
        check("no shred work folders are left in the self-test area", leftover.isEmpty)
    }

    // MARK: SDK archives and System Data through the executor (M01-04b-3a)

    static func engineTrash(dir: URL, runID: String) {
        print("SDK archives and System Data: review / preview snapshot → approval → engine → executor (M01-04b-3a)")
        let fm = FileManager.default
        let home = SafetyGuard.home
        func folder(_ u: URL, _ text: String = "x") -> URL {
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: u.appendingPathComponent("content.txt"))
            return u
        }
        func log(_ u: URL) -> [TrashedItem] { TrashLog.shared.present().filter { $0.original == AppCleanup.physicalPath(u) } }
        func putBack(_ u: URL) -> Bool { log(u).first.map { TrashOps.restore($0) == nil } ?? false }
        /// An archive as the scan reports it: identity captured now ("when it was found").
        func archive(_ name: String, _ u: URL, id: String? = nil, identity: FileIdentity?? = nil) -> SDKItem {
            SDKItem(id: id ?? u.path, group: .xcode, kind: "Archives", name: name, detail: "", size: 10, reveal: u,
                    action: .trash(u), review: true, regen: "can't be rebuilt exactly",
                    identity: identity ?? AppCleanup.snapshot(u))
        }
        /// Opens the review the screen opens, confirms it through the review sheet's confirmation, returns what the
        /// screen gets.
        @MainActor func confirmed<I>(_ build: (@escaping ([I], TrashApproval?) -> Void) -> ReviewRequest,
                                     beforeConfirm: () -> Void = {}) -> ([I], TrashApproval?)? {
            let got = Slot<([I], TrashApproval?)>()
            let request = build { got.value = ($0, $1) }
            beforeConfirm()
            ReviewConfirmation.confirm(request)
            let end = Date().addingTimeInterval(30)
            while got.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return got.value
        }

        // A review mixing an archive (Trash) and Device Support (deleted permanently, its own flow).
        let arch = folder(dir.appendingPathComponent("A-\(runID).xcarchive"), "archive")
        let devDir = folder(home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport/selftest-\(runID)"))
        let dev = SDKItem(id: devDir.path, group: .xcode, kind: "Device support", name: "DS", detail: "", size: 5, reveal: devDir,
                          action: .delete([devDir]), regen: "copied again")
        let mixed = MainActor.assumeIsolated { confirmed { ReviewBuild.sdks([archive("A", arch), dev], perform: $0) } }
        let plannedIDs: [String]? = { if case .approved(let a)? = mixed?.1 { return a.plan.candidates.map(\.id) }; return nil }()
        check("the SDK review's Trash approval covers only the archive, not the permanent delete",
              plannedIDs == [arch.path] && SDKEngine.reason(dev) == nil)
        let r1 = SDKEngine.remove(mixed?.0 ?? [], trash: mixed?.1)
        check("the archive goes to the Trash through the executor and the Device Support folder is deleted as before",
              r1.errors.isEmpty && r1.trashed == 10 && r1.bytes == 15 && !fm.fileExists(atPath: arch.path) && !fm.fileExists(atPath: devDir.path))
        check("the archive is logged as Developer SDKs and Put Back restores it",
              log(arch).first?.source == "Developer SDKs" && putBack(arch) && fm.fileExists(atPath: arch.appendingPathComponent("content.txt").path))

        // Replaced after the sheet opened.
        let scannedA = archive("A", arch)
        let stale = MainActor.assumeIsolated {
            confirmed({ ReviewBuild.sdks([scannedA], perform: $0) }, beforeConfirm: {
                try? fm.removeItem(at: arch); _ = folder(arch, "someone else's")
            })
        }
        let r2 = SDKEngine.remove(stale?.0 ?? [], trash: stale?.1)
        check("an archive replaced after review is left alone and reported",
              r2.trashed == 0 && r2.errors.first?.contains("changed after you reviewed") == true
              && (try? String(contentsOf: arch.appendingPathComponent("content.txt"), encoding: .utf8)) == "someone else's")

        // No approval, a refused one, and an approval that doesn't match the items: nothing moves.
        let none = SDKEngine.remove([archive("A", arch)], trash: nil)
        check("an archive without an approval stays and says so",
              none.trashed == 0 && none.errors.first?.contains("wasn't approved") == true && fm.fileExists(atPath: arch.path))
        let other = folder(dir.appendingPathComponent("B-\(runID).xcarchive"))
        let forOther = MainActor.assumeIsolated { confirmed { ReviewBuild.sdks([archive("B", other)], perform: $0) } }
        if case .approved(let a)? = forOther?.1 {
            let refused = SDKEngine.remove(forOther?.0 ?? [], trash: .refused(plan: a.plan, reason: "No approval was issued (test)"))
            check("a refused approval moves nothing and says why",
                  refused.trashed == 0 && refused.errors.first?.contains("No approval was issued") == true && fm.fileExists(atPath: other.path))
            let mismatch = SDKEngine.remove([archive("A", arch)], trash: forOther?.1)
            check("an approval for different items moves nothing at all",
                  mismatch.trashed == 0 && mismatch.errors.first?.contains("doesn't match") == true
                  && fm.fileExists(atPath: arch.path) && fm.fileExists(atPath: other.path))
        } else { check("an approval was issued for the second archive", false) }

        // Partial failure: one archive can't move.
        let free = folder(dir.appendingPathComponent("C-\(runID).xcarchive")), locked = folder(dir.appendingPathComponent("D-\(runID).xcarchive"))
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        let both = MainActor.assumeIsolated { confirmed { ReviewBuild.sdks([archive("C", free), archive("D", locked)], perform: $0) } }
        let r3 = SDKEngine.remove(both?.0 ?? [], trash: both?.1)
        chflags(locked.path, 0)
        check("an archive that can't move is reported, the other moves",
              r3.trashed == 10 && r3.errors.count == 1 && r3.errors.first?.hasPrefix("D:") == true
              && !fm.fileExists(atPath: free.path) && fm.fileExists(atPath: locked.path) && log(locked).isEmpty)
        check("the moved archive can be put back", putBack(free))

        // The approved plan must be exactly the engine's items' own Trash targets (finding: id-only check).
        let x = folder(dir.appendingPathComponent("X-\(runID).xcarchive"), "x"), y = folder(dir.appendingPathComponent("Y-\(runID).xcarchive"), "y")
        let forX = MainActor.assumeIsolated { confirmed { ReviewBuild.sdks([archive("X", x)], perform: $0) } }
        let sameIDOtherURL = SDKEngine.remove([archive("X", y, id: x.path)], trash: forX?.1)
        check("an item with the approved id but a different Trash path moves nothing",
              sameIDOtherURL.trashed == 0 && sameIDOtherURL.errors.first?.contains("different path") == true
              && fm.fileExists(atPath: x.path) && fm.fileExists(atPath: y.path))
        let sameIDOtherIdentity = SDKEngine.remove([archive("X", x, identity: AppCleanup.snapshot(y))], trash: forX?.1)
        check("an item whose scanned identity isn't the approved one moves nothing",
              sameIDOtherIdentity.trashed == 0 && sameIDOtherIdentity.errors.first?.contains("isn't the item the scan found") == true
              && fm.fileExists(atPath: x.path))
        let otherModule = SystemDataEngine.remove([SysItem(id: x.path, section: .backups, name: "X", detail: "", size: 10, reveal: x,
                                                           action: .trash(x), identity: AppCleanup.snapshot(x))], trash: forX?.1)
        check("an SDK approval can't move System Data items, even with the same id and path",
              otherModule.bytes == 0 && otherModule.errors.first?.contains("belongs to sdks") == true && fm.fileExists(atPath: x.path))
        let twice = MainActor.assumeIsolated { confirmed { ReviewBuild.sdks([archive("X1", x, id: "one"), archive("X2", x, id: "two")], perform: $0) } }
        let dup = SDKEngine.remove(twice?.0 ?? [], trash: twice?.1)
        check("two items naming the same path move nothing", dup.trashed == 0
              && dup.errors.first?.contains("named twice") == true && fm.fileExists(atPath: x.path))

        // Replaced between the scan and opening the sheet: the row describes the scanned item, so it is refused.
        let scannedY = archive("Y", y)
        try? fm.removeItem(at: y); _ = folder(y, "replaced before the sheet opened")
        let rescan = MainActor.assumeIsolated { () -> (ReviewRequest, ([SDKItem], TrashApproval?)?) in
            let request = ReviewBuild.sdks([scannedY]) { _, _ in }
            return (request, confirmed { ReviewBuild.sdks([scannedY], perform: $0) })
        }
        check("an archive replaced between the scan and the review is blocked and needs a rescan",
              rescan.0.items.first?.blocked?.contains("changed since the scan") == true && rescan.0.trashPlan == nil)
        let afterRescanRefusal = SDKEngine.remove(rescan.1?.0 ?? [], trash: rescan.1?.1)
        check("…and nothing moves", afterRescanRefusal.trashed == 0 && fm.fileExists(atPath: y.path))
        let unscanned = MainActor.assumeIsolated { ReviewBuild.sdks([archive("Y", y, identity: .some(nil))]) { _, _ in } }
        check("an archive the scan didn't identify is blocked", unscanned.items.first?.blocked?.contains("Scan again") == true)

        // System Data review: a backup folder.
        let backup = folder(dir.appendingPathComponent("backup-\(runID)"), "backup")
        let sys = SysItem(id: backup.path, section: .backups, name: "Phone", detail: "", size: 7, reveal: backup, action: .trash(backup),
                          review: true, identity: AppCleanup.snapshot(backup))
        let sysOK = MainActor.assumeIsolated { confirmed { ReviewBuild.systemData([sys], perform: $0) } }
        let sysScanned = sys
        let s1 = SystemDataEngine.remove(sysOK?.0 ?? [], trash: sysOK?.1)
        check("a reviewed backup goes to the Trash through the executor, logged as System Data, and can be put back",
              s1.errors.isEmpty && s1.bytes == 7 && log(backup).first?.source == "System Data" && putBack(backup))
        let sysStale = MainActor.assumeIsolated {
            confirmed({ ReviewBuild.systemData([SysItem(id: backup.path, section: .backups, name: "Phone", detail: "", size: 7,
                                                        reveal: backup, action: .trash(backup), review: true,
                                                        identity: AppCleanup.snapshot(backup))], perform: $0) },
                      beforeConfirm: { try? fm.removeItem(at: backup); _ = folder(backup, "new") })
        }
        _ = sysScanned
        let s2 = SystemDataEngine.remove(sysStale?.0 ?? [], trash: sysStale?.1)
        check("a backup replaced after review is left alone and reported",
              s2.bytes == 0 && s2.errors.first?.contains("changed after you reviewed") == true && fm.fileExists(atPath: backup.path))

        // MCP, with the real scans finding items in this home folder.
        let day = home.appendingPathComponent("Library/Developer/Xcode/Archives/2026-01-01")
        let mcpArch = folder(day.appendingPathComponent("SelfTest-\(runID).xcarchive"), "mcp archive")
        (["Name": "SelfTest"] as NSDictionary).write(to: mcpArch.appendingPathComponent("Info.plist"), atomically: true)
        approvals.asked = []; approvals.answer = true
        /// The id the tool itself reports for the item (as an AI client would use it).
        func toolID(_ tool: String, _ args: [String: Any], endingWith tail: String) -> String {
            let items = ((try? MCPServer.call(tool, args)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            return items.compactMap { $0["id"] as? String }.first { $0.hasSuffix(tail) } ?? "missing"
        }
        let archTail = "/Archives/2026-01-01/SelfTest-\(runID).xcarchive"
        func sdkConfirm(_ approval: ToolApproval?) -> [String: Any]? {
            let sdkID = toolID("list_sdks", ["group": "Xcode"], endingWith: archTail)
            let pv = (try? MCPServer.call("remove_sdks", ["ids": [sdkID]])) as? [String: Any]
            let id = pv?["preview_id"] as? String ?? ""
            return (try? MCPServer.call("remove_sdks", ["ids": [sdkID], "confirm": true, "preview_id": id], approval: approval)) as? [String: Any]
        }
        let m1 = sdkConfirm(nil)
        check("MCP remove_sdks moves the archive through the executor after the window, logged as the AI assistant",
              (m1?["errors"] as? [String])?.isEmpty == true && !fm.fileExists(atPath: mcpArch.path) && approvals.asked.count == 1
              && log(mcpArch).first?.source == "Developer SDKs · AI assistant")
        check("the MCP archive can be put back", putBack(mcpArch))
        let m2 = sdkConfirm(.yesFlag)
        check("remove_sdks with --yes is logged as the non-interactive override",
              (m2?["errors"] as? [String])?.isEmpty == true
              && log(mcpArch).first?.source == "Developer SDKs · Command line (--yes, not confirmed by a person)")
        _ = putBack(mcpArch)
        HumanApproval.ask = { _ in try? fm.removeItem(at: mcpArch); _ = folder(mcpArch, "replaced while asking"); return true }
        let m3 = sdkConfirm(nil)
        installTestApprover(); approvals.answer = true
        check("an archive replaced during the confirmation window is left alone and reported",
              (m3?["errors"] as? [String])?.first?.contains("changed after you reviewed") == true && fm.fileExists(atPath: mcpArch.path))

        // Replaced between list_sdks and the preview: refused, not approved, not moved.
        _ = toolID("list_sdks", ["group": "Xcode"], endingWith: archTail)
        let scanID = toolID("list_sdks", ["group": "Xcode"], endingWith: archTail)
        try? fm.removeItem(at: mcpArch); _ = folder(mcpArch, "replaced after list_sdks")
        let rpv = (try? MCPServer.call("remove_sdks", ["ids": [scanID]])) as? [String: Any]
        let rRow = (rpv?["items"] as? [[String: Any]])?.first
        let rc = (try? MCPServer.call("remove_sdks", ["ids": [scanID], "confirm": true,
                                                      "preview_id": rpv?["preview_id"] as? String ?? ""])) as? [String: Any]
        check("an archive replaced between list_sdks and the preview is refused and isn't moved",
              rRow?["allowed"] as? Bool == false && (rRow?["reason"] as? String)?.contains("changed since the scan") == true
              && fm.fileExists(atPath: mcpArch.path) && (rc?["moved_to_trash"] as? String) == ByteText.string(0))

        let mcpBackup = folder(home.appendingPathComponent("Library/Application Support/MobileSync/Backup/selftest-\(runID)"), "mcp backup")
        let backupID = toolID("system_data", [:], endingWith: "/MobileSync/Backup/selftest-\(runID)")
        let spv = (try? MCPServer.call("remove_system_data", ["ids": [backupID]])) as? [String: Any]
        let sm = (try? MCPServer.call("remove_system_data", ["ids": [backupID], "confirm": true,
                                                             "preview_id": spv?["preview_id"] as? String ?? ""], approval: .terminal)) as? [String: Any]
        check("MCP remove_system_data moves the backup through the executor, logged with who confirmed",
              (sm?["errors"] as? [String])?.isEmpty == true && !fm.fileExists(atPath: mcpBackup.path)
              && log(mcpBackup).first?.source == "System Data · Command line")
        check("the MCP backup can be put back", putBack(mcpBackup))
        try? fm.removeItem(at: mcpArch); try? fm.removeItem(at: mcpBackup)
    }

    // MARK: Uninstall and Remove alerts through the executor (M01-04b-3b)

    /// Installed usage skills (M01-04b-3c): Connect never overwrites a skill that isn't provably Mac Cleaner's and
    /// unchanged, Disconnect moves only such a skill to the Trash (AppOwnedTrash) and disconnects the server either way,
    /// and a Connect that fails part-way changes nothing. A fake client in this run's folder; settings in memory.
    @MainActor
    static func installedSkills(dir: URL, runID: String) {
        print("Installed skills: ownership record → Connect / Disconnect (M01-04b-3c)")
        let fm = FileManager.default
        let base = dir.appendingPathComponent("skills-\(runID)")
        let skillsDir = base.appendingPathComponent("client/skills")
        let config = base.appendingPathComponent("client/mcp.json")
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let client = AIClient(id: "selftest", name: "SelfTest", detail: "", kind: .json(file: config.path, key: "mcpServers", vscodeStyle: false),
                              skillsDir: skillsDir.path, presence: base.path)
        let store = MemorySettings()
        let skills = InstalledSkills(store: store)
        let model = IntegrationsModel(clients: [client], skills: skills)
        let folder = InstalledSkills.folderPath(in: skillsDir.path)
        let skillFile = URL(fileURLWithPath: folder).appendingPathComponent("SKILL.md")
        func text(_ u: URL = skillFile) -> String? { try? String(contentsOf: u, encoding: .utf8) }
        func inode(_ u: URL) -> UInt64? { (try? fm.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? UInt64 }
        func connected() -> Bool {
            let d = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (d?["mcpServers"] as? [String: Any])?["mac-cleaner"] != nil
        }
        func connect() -> (text: String, isError: Bool)? { model.connect(client); return model.message }
        func disconnect() -> (text: String, isError: Bool)? { model.disconnect(client); return model.message }
        func recorded() -> Bool { (store.object(forKey: InstalledSkills.key) as? [String: String])?[folder] != nil }
        func owned(current: Bool = true) -> Bool { if case .owned(_, let c) = skills.state(at: folder) { return c == current }; return false }
        func notOwned() -> Bool { if case .notOwned = skills.state(at: folder) { return true }; return false }
        func reset() { try? fm.removeItem(atPath: folder); skills.forget(folder); try? fm.removeItem(at: config) }

        // 1. Connect: the skill is installed and recorded, the server registered; again: left as it is.
        let c1 = connect()
        check("Connect installs the skill, records it as Mac Cleaner's only after writing it, and registers the server",
              c1?.isError == false && c1?.text.contains("Skill installed") == true && text() == SkillText.markdown
              && owned() && recorded() && connected())
        let inode1 = inode(skillFile)
        let c1b = connect()
        check("Connect again leaves an unchanged installed skill as it is",
              c1b?.text.contains("already installed") == true && inode(skillFile) == inode1 && inode1 != nil)

        // 2. Disconnect: the verified skill goes to the Trash (Put Back works); the server is removed; the record forgotten.
        let d1 = disconnect()
        let e1 = TrashLog.shared.present().first { $0.original == folder }
        check("Disconnect moves a verified, unchanged Mac Cleaner skill to the Trash through the executor and removes the server",
              d1?.isError == false && d1?.text.contains("moved to the Trash") == true && !fm.fileExists(atPath: folder)
              && !connected() && SelfTest.inIsolatedTrash(e1?.trashed) && e1?.restorable == true && e1?.source == "Disconnect SelfTest")
        check("…and forgets its record", !recorded())
        check("the removed skill can be put back", e1.map { TrashOps.restore($0) == nil } == true && text() == SkillText.markdown)

        // 3. The put-back folder has no record, like a skill an older version installed: never treated as Mac Cleaner's,
        // even with matching text. Same for the person's own skill.
        let c3 = connect()
        check("an unrecorded skill folder with Mac Cleaner's text (older install) isn't Mac Cleaner's: Connect keeps it and says so",
              c3?.isError == false && c3?.text.contains("kept as it is") == true && c3?.text.contains("no record") == true
              && text() == SkillText.markdown && notOwned() && !recorded() && connected())
        let d3 = disconnect()
        check("…and Disconnect keeps it, still removing the server, and says the skill was kept",
              d3?.isError == false && d3?.text.contains("was kept") == true && fm.fileExists(atPath: folder) && !connected())
        try? "my own skill".write(to: skillFile, atomically: false, encoding: .utf8)
        let c3b = connect()
        check("Connect never overwrites a skill the person put there", text() == "my own skill" && c3b?.text.contains("kept as it is") == true && connected())
        let d3b = disconnect()
        check("…and Disconnect never removes it", text() == "my own skill" && d3b?.text.contains("was kept") == true && !connected())
        reset()

        // 4. An installed skill the person edited, or added files to: kept by Disconnect and by Connect.
        _ = connect()
        try? (SkillText.markdown + "\nMy notes.\n").write(to: skillFile, atomically: false, encoding: .utf8)
        let d4 = disconnect()
        check("Disconnect keeps an installed skill that was edited, says why, and still removes the server",
              d4?.text.contains("was edited") == true && text()?.hasSuffix("My notes.\n") == true && !connected())
        let c4 = connect()
        check("…and Connect doesn't overwrite it", text()?.hasSuffix("My notes.\n") == true && c4?.text.contains("kept as it is") == true)
        reset()
        _ = connect()
        let notes = URL(fileURLWithPath: folder).appendingPathComponent("notes.md")
        try? "mine".write(to: notes, atomically: true, encoding: .utf8)
        let d4b = disconnect()
        check("Disconnect keeps an installed skill folder that holds other files, with those files",
              d4b?.text.contains("holds files") == true && text(notes) == "mine" && text() == SkillText.markdown && !connected())
        reset()

        // 5. Changed after it was verified (the proof) and before the move: checked again right before it, and kept.
        _ = connect()
        if case .owned(let v, _) = skills.state(at: folder) {
            try? fm.removeItem(at: skillFile)
            try? SkillText.markdown.write(to: skillFile, atomically: false, encoding: .utf8)   // the same text, another file
            check("a skill whose SKILL.md was replaced after it was verified is kept",
                  { if case .kept(let why) = AppOwnedTrash.trashSkill(v, source: "Self-test") { return why.contains("replaced") }; return false }() && fm.fileExists(atPath: folder))
        } else { check("a skill whose SKILL.md was replaced after it was verified is kept", false) }
        reset()
        _ = connect()
        if case .owned(let v, _) = skills.state(at: folder) {
            try? "x".write(to: URL(fileURLWithPath: folder).appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
            check("…and so is one that gained a file after it was verified",
                  { if case .kept(let why) = AppOwnedTrash.trashSkill(v, source: "Self-test") { return why.contains("holds files") }; return false }() && fm.fileExists(atPath: folder))
        } else { check("…and so is one that gained a file after it was verified", false) }
        reset()

        // 6. A Connect that fails part-way changes nothing.
        try? "{ not json".write(to: config, atomically: true, encoding: .utf8)
        let c6 = connect()
        check("a Connect whose config can't be changed removes the skill it just installed, and changes nothing",
              c6?.isError == true && c6?.text.contains("removed again") == true && !fm.fileExists(atPath: folder) && !recorded()
              && text(config) == "{ not json")
        reset()
        let blocker = base.appendingPathComponent("blocker")
        try? Data("a file, not a folder".utf8).write(to: blocker)
        let blocked = AIClient(id: "selftest-blocked", name: "SelfTestBlocked", detail: "",
                               kind: .json(file: config.path, key: "mcpServers", vscodeStyle: false),
                               skillsDir: blocker.appendingPathComponent("skills").path, presence: base.path)
        let model2 = IntegrationsModel(clients: [blocked], skills: skills)
        model2.connect(blocked)
        check("a Connect whose skill can't be installed doesn't change the config",
              model2.message?.isError == true && model2.message?.text.contains("couldn't be installed") == true && !fm.fileExists(atPath: config.path))

        // 6b. Moved to the Trash, but its Trash-list record can't be written: the move stands (never undone), reported as
        // moved but unrecorded, with where it is and how to restore it from Finder.
        _ = connect()
        let savedRecord = AppCleanup.recordMove
        AppCleanup.recordMove = { _, _, _, _, _ in false }
        let movesBefore6 = SelfTest.isolatedMoves.count
        let d6 = disconnect()
        AppCleanup.recordMove = savedRecord
        let dest6 = SelfTest.isolatedMoves.count > movesBefore6 ? SelfTest.isolatedMoves.all.last : nil
        check("a skill moved to the Trash whose record couldn't be written is reported as moved but unrecorded, with its Trash path and Finder recovery",
              d6?.isError == true && d6?.text.contains("couldn't be added to Mac Cleaner's Trash list") == true && d6?.text.contains("Finder") == true
              && !fm.fileExists(atPath: folder) && !connected()
              && dest6.map { fm.fileExists(atPath: $0 + "/SKILL.md") && d6?.text.contains($0) == true } == true)
        check("…its ownership record is forgotten (it left its place) and no Trash-list entry claims it",
              !recorded() && !TrashLog.shared.present().contains { $0.original == folder })
        if let dest6 { try? fm.removeItem(atPath: (dest6 as NSString).deletingLastPathComponent) }
        reset()

        // 7. An unchanged skill an earlier version installed (recorded) is kept as it is: never rewritten.
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: false)
        try? "an older version's text".write(to: skillFile, atomically: false, encoding: .utf8)
        let fsys = LocalFileSystem()
        if let d = try? fsys.identity(at: folder), let f = try? fsys.identity(at: skillFile.path),
           let json = try? JSONEncoder().encode(InstalledSkills.Record(folderDevice: d.device, folderInode: d.inode, fileDevice: f.device,
                                                                     fileInode: f.inode, sha256: InstalledSkills.sha256(Data("an older version's text".utf8)))) {
            store.set([folder: String(decoding: json, as: UTF8.self)], forKey: InstalledSkills.key)
        }
        let before7 = owned(current: false), inode7 = inode(skillFile)
        let c7 = connect()
        check("Connect keeps an older Mac Cleaner skill as it is (never rewrites a skill folder) and says so",
              before7 && c7?.isError == false && c7?.text.contains("earlier version installed was kept") == true
              && text() == "an older version's text" && inode(skillFile) == inode7 && owned(current: false) && connected())
        reset()

        // 7b. Undoing an install (a Connect that failed) removes only what is provably the installed folder at the moment
        // of removal: changes made after the ownership check and before the removal are left untouched.
        func undo(_ change: () -> Void) -> String?? {
            guard let made = try? skills.install(in: skillsDir.path) else { return nil }
            return .some(skills.undoInstall(folder: made.folder, record: made.record, afterCheck: change))
        }
        func noLeftovers(_ dir: String) -> Bool {
            !((try? fm.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasPrefix(".maccleaner-undo-") }
        }
        let u1 = undo { try? fm.removeItem(at: skillFile); try? "the person's own skill".write(to: skillFile, atomically: false, encoding: .utf8) }
        check("undoing an install never removes a SKILL.md replaced after the check",
              u1??.contains("replaced") == true && text() == "the person's own skill" && noLeftovers(folder) && noLeftovers(skillsDir.path))
        reset()
        let u2 = undo { try? (SkillText.markdown + "edited").write(to: skillFile, atomically: false, encoding: .utf8) }
        check("…nor one edited in place after the check",
              u2??.contains("edited") == true && text() == SkillText.markdown + "edited" && noLeftovers(folder) && noLeftovers(skillsDir.path))
        reset()
        let moved7 = skillsDir.appendingPathComponent("moved-away")
        let u3 = undo {
            try? fm.moveItem(atPath: folder, toPath: moved7.path)
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: false)
            try? "a new folder's skill".write(to: skillFile, atomically: false, encoding: .utf8)
        }
        check("…nor a folder replaced after the check (and the moved original is untouched too)",
              u3??.contains("isn't the folder") == true && text() == "a new folder's skill"
              && text(moved7.appendingPathComponent("SKILL.md")) == SkillText.markdown && noLeftovers(skillsDir.path))
        try? fm.removeItem(at: moved7); reset()
        let extra7 = URL(fileURLWithPath: folder).appendingPathComponent("notes.md")
        let u4 = undo { try? "mine".write(to: extra7, atomically: true, encoding: .utf8) }
        check("…nor a folder that gained a file after the check: the file and SKILL.md both stay",
              u4??.contains("holds files") == true && text(extra7) == "mine" && text() == SkillText.markdown
              && noLeftovers(folder) && noLeftovers(skillsDir.path))
        reset()
        let u5 = undo {}
        check("an unchanged installed folder is removed by the undo, and its record forgotten",
              u5 == .some(nil) && !fm.fileExists(atPath: folder) && !recorded() && noLeftovers(skillsDir.path))
        reset()

        // 7c. Claude Code through its command line (a fake): registration is replaced only after the old one is removed,
        // restored if the new one can't be added, and Disconnect touches the skill only once the server is really gone.
        final class FakeClaude {
            let config: URL
            var failRemove = false, failAdd = false, failRestore = false, installed = true
            var calls: [String] = []
            init(_ config: URL) { self.config = config }
            var entry: [String: Any]? {
                get {
                    let d = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    return (d?["mcpServers"] as? [String: Any])?["mac-cleaner"] as? [String: Any]
                }
                set {
                    var d = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    var servers = d["mcpServers"] as? [String: Any] ?? [:]
                    servers["mac-cleaner"] = newValue
                    d["mcpServers"] = servers
                    try? JSONSerialization.data(withJSONObject: d).write(to: config)
                }
            }
            func run(_ args: [String]) -> (status: Int32, output: String?)? {
                guard installed else { return nil }
                calls.append(args.prefix(2).joined(separator: " "))
                switch args[1] {
                case "remove": if failRemove { return (1, "remove refused") }; entry = nil
                case "add": if failAdd { return (1, "add refused") }; entry = ["type": "stdio", "command": args[args.count - 2], "args": [args[args.count - 1]]]
                case "add-json":
                    if failRestore { return (1, "restore refused") }
                    entry = (try? JSONSerialization.jsonObject(with: Data(args[args.count - 1].utf8))) as? [String: Any]
                default: return (2, "unknown")
                }
                return (0, "")
            }
        }
        let ccDir = base.appendingPathComponent("claude")
        let ccConfig = ccDir.appendingPathComponent("claude.json"), ccSkills = ccDir.appendingPathComponent("skills")
        try? fm.createDirectory(at: ccSkills, withIntermediateDirectories: true)
        let cc = AIClient(id: "selftest-claude", name: "SelfTestClaude", detail: "", kind: .claudeCode(config: ccConfig.path),
                          skillsDir: ccSkills.path, presence: ccDir.path)
        let fake = FakeClaude(ccConfig)
        let ccModel = IntegrationsModel(clients: [cc], skills: skills, claude: { fake.run($0) })
        let ccFolder = InstalledSkills.folderPath(in: ccSkills.path)
        let older: [String: Any] = ["type": "stdio", "command": "/old/Mac Cleaner", "args": ["--mcp"]]
        func ccMessage(_ connect: Bool) -> (text: String, isError: Bool)? {
            if connect { ccModel.connect(cc) } else { ccModel.disconnect(cc) }
            return ccModel.message
        }
        func entryIs(_ e: [String: Any]?) -> Bool { (fake.entry as NSDictionary?) == (e as NSDictionary?) }
        func ccReset() { try? fm.removeItem(atPath: ccFolder); skills.forget(ccFolder); try? fm.removeItem(at: ccConfig) }

        fake.entry = older; fake.failAdd = true
        let k1 = ccMessage(true)
        check("a Claude Code registration that can't be added restores the previous one, says so, and undoes the skill",
              k1?.isError == true && k1?.text.contains("previous Mac Cleaner registration was restored") == true
              && entryIs(older) && !fm.fileExists(atPath: ccFolder) && fake.calls == ["mcp remove", "mcp add", "mcp add-json"])
        ccReset(); fake.calls = []
        fake.entry = older; fake.failRestore = true
        let k2 = ccMessage(true)
        check("…and says truthfully when the previous one couldn't be restored either",
              k2?.isError == true && k2?.text.contains("removed and couldn't be restored") == true && fake.entry == nil)
        ccReset(); fake.calls = []; fake.failAdd = false; fake.failRestore = false
        fake.entry = older; fake.failRemove = true
        let k3 = ccMessage(true)
        check("a previous registration that can't be removed is left as it was, and nothing is added",
              k3?.isError == true && k3?.text.contains("left as it was") == true && entryIs(older) && fake.calls == ["mcp remove"]
              && !fm.fileExists(atPath: ccFolder))
        ccReset(); fake.calls = []; fake.failRemove = false
        let k4 = ccMessage(true)
        let registered: [String: Any] = ["type": "stdio", "command": SkillText.serverCommand, "args": ["--mcp"]]
        check("Connect registers through the command line and installs the skill",
              k4?.isError == false && entryIs(registered) && fake.calls == ["mcp add"] && fm.fileExists(atPath: ccFolder))
        fake.calls = []
        let k5 = ccMessage(true)
        check("…and changes nothing when it is already registered as needed", k5?.isError == false && fake.calls.isEmpty && entryIs(registered))
        fake.failRemove = true
        let k6 = ccMessage(false)
        check("a Disconnect whose remove fails reports that the server is still registered, and keeps the skill",
              k6?.isError == true && k6?.text.contains("still registered") == true && entryIs(registered)
              && text(URL(fileURLWithPath: ccFolder).appendingPathComponent("SKILL.md")) == SkillText.markdown)
        fake.failRemove = false
        let k7 = ccMessage(false)
        check("…and once the remove works, the server is gone and the skill moved to the Trash",
              k7?.isError == false && fake.entry == nil && k7?.text.contains("moved to the Trash") == true && !fm.fileExists(atPath: ccFolder))
        ccReset(); fake.installed = false; fake.calls = []
        let k8 = ccMessage(true)
        check("without the command line, Connect writes the registration into the config file",
              k8?.isError == false && entryIs(registered) && fake.calls.isEmpty)
        ccReset()

        // 8. Save skill folder (a place the person picked): never overwrites, never recorded, so never removed.
        let saveDir = base.appendingPathComponent("saved")
        try? fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let saved = try? InstalledSkills.saveCopy(in: saveDir.path)
        let savedFile = saved.map { URL(fileURLWithPath: $0).appendingPathComponent("SKILL.md") }
        if let savedFile { try? "edited".write(to: savedFile, atomically: false, encoding: .utf8) }
        let again: Bool = (try? InstalledSkills.saveCopy(in: saveDir.path)) == nil
        let savedState: Bool = saved.map { if case .notOwned = skills.state(at: $0) { return true }; return false } ?? false
        check("Save skill folder never overwrites an existing folder, and its copy is never recorded as Mac Cleaner's",
              saved != nil && again && savedFile.flatMap { text($0) } == "edited" && savedState)
        try? fm.removeItem(at: base)
    }

    static func uninstallAndAlerts(dir: URL, runID: String, savedProtected: [String]) {
        print("Uninstall and Remove alerts: scan identity → review / alert → executor; the password step checks identity (M01-04b-3b)")
        let fm = FileManager.default
        let base = dir.appendingPathComponent("3b")
        func folder(_ u: URL, _ text: String = "x") -> URL {
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: u.appendingPathComponent("content.txt"))
            return u
        }
        func plain(_ u: URL, _ text: String) -> URL {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: u)
            return u
        }
        func log(_ u: URL) -> [TrashedItem] { TrashLog.shared.present().filter { $0.original == AppCleanup.physicalPath(u) } }
        func putBack(_ u: URL) -> Bool { log(u).first.map { TrashOps.restore($0) == nil } ?? false }
        func leftover(_ u: URL, admin: Bool = false) -> AppLeftover {
            var l = AppLeftover(id: u.path, url: u, label: "Support", size: 5, include: true, note: nil)
            l.needsAdmin = admin
            l.identity = AppCleanup.snapshot(u)
            return l
        }
        /// An app and its leftovers as the scan reports them (identities captured now).
        func app(_ name: String, _ u: URL, _ leftovers: [AppLeftover]) -> AppInfo {
            AppInfo(id: u.path, url: u, name: name, bundleID: "com.example.selftest.\(name)", version: "1", isApple: false,
                    appSize: 10, lastUsed: nil, leftovers: leftovers, caches: [], identity: AppCleanup.snapshot(u))
        }
        @MainActor func confirmed(_ a: AppInfo, beforeConfirm: () -> Void = {}) -> ([AppLeftover], TrashApproval?)? {
            let got = Slot<([AppLeftover], TrashApproval?)>()
            let request = ReviewBuild.uninstall(a, running: false) { got.value = ($0, $1) }
            beforeConfirm()
            ReviewConfirmation.confirm(request)
            let end = Date().addingTimeInterval(30)
            while got.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return got.value
        }
        // The password step is watched, never run: it records what it would have been given.
        // Passed in, never global: every uninstall here gets this watcher instead of the real password step.
        let isolatedMover = AppCleanup.trashMover
        let stepCalls = PathList()
        let step: AppEngine.AdminStepRunner = { items, _ in
            stepCalls.add(items.map { "\($0.id)|\($0.identity.map { "\($0.device):\($0.inode)" } ?? "none")" }.joined(separator: ","))
            return .cancelled
        }
        let allowAll: @Sendable (URL) -> Bool = { _ in true }, allowNone: @Sendable (URL) -> Bool = { _ in false }
        defer { AppCleanup.trashMover = isolatedMover; ProtectedPaths.set(savedProtected) }

        // 1. A normal uninstall: the app and both leftovers go to the Trash through the executor.
        let fooURL = folder(base.appendingPathComponent("Foo-\(runID).app"), "app")
        let fooSupport = folder(base.appendingPathComponent("Support/Foo-\(runID)"), "support")
        let fooPrefs = plain(base.appendingPathComponent("Prefs/com.example.foo-\(runID).plist"), "prefs")
        let foo = app("Foo", fooURL, [leftover(fooSupport), leftover(fooPrefs)])
        let r1in = MainActor.assumeIsolated { confirmed(foo) }
        let r1 = AppEngine.uninstall(foo, picked: r1in?.0 ?? [], trash: r1in?.1, adminStep: step, adminAllowed: allowNone)
        check("an uninstall moves the app and its reviewed leftovers through the executor",
              r1.appRemoved && r1.errors.isEmpty && r1.bytes == 20 && ![fooURL, fooSupport, fooPrefs].contains { fm.fileExists(atPath: $0.path) }
              && stepCalls.count == 0)
        check("an app moved to the Trash by the executor is reported and recorded in History as uninstalled (#41)",
              r1.appInTrash && r1.historyTitle(appName: "Foo") == "Foo Uninstalled")
        check("each is logged as the uninstall and Put Back restores them",
              log(fooURL).first?.source == "Uninstall Foo" && putBack(fooURL) && putBack(fooSupport) && putBack(fooPrefs))

        // 2. A preference file rewritten while the app quits (after the confirmation) is changed: kept and reported.
        let foo2 = app("Foo", fooURL, [leftover(fooSupport), leftover(fooPrefs)])
        let r2in = MainActor.assumeIsolated { confirmed(foo2) }
        try? Data("rewritten on quit".utf8).write(to: fooPrefs)
        let r2 = AppEngine.uninstall(foo2, picked: r2in?.0 ?? [], trash: r2in?.1, adminStep: step, adminAllowed: allowNone)
        check("preferences rewritten during quit are left alone and reported; the rest is uninstalled",
              r2.appRemoved && fm.fileExists(atPath: fooPrefs.path) && !fm.fileExists(atPath: fooSupport.path)
              && r2.errors.first?.contains("changed after you reviewed") == true)
        _ = putBack(fooURL); _ = putBack(fooSupport)

        // 3. The app replaced after the review: nothing is removed, the leftovers stay.
        let foo3 = app("Foo", fooURL, [leftover(fooSupport)])
        let r3in = MainActor.assumeIsolated { confirmed(foo3, beforeConfirm: { try? fm.removeItem(at: fooURL); _ = folder(fooURL, "other app") }) }
        let r3 = AppEngine.uninstall(foo3, picked: r3in?.0 ?? [], trash: r3in?.1, adminStep: step, adminAllowed: allowNone)
        check("an app replaced after review is left alone, and so are its leftovers",
              !r3.appRemoved && fm.fileExists(atPath: fooURL.path) && fm.fileExists(atPath: fooSupport.path)
              && r3.errors.contains { $0.contains("changed after you reviewed") } && stepCalls.count == 0)

        // 4. Replaced between the scan and the review: the row is blocked (rescan), the app can't be confirmed.
        let foo4 = app("Foo", fooURL, [leftover(fooSupport)])
        try? fm.removeItem(at: fooURL); _ = folder(fooURL, "replaced before review")
        let req4 = MainActor.assumeIsolated { ReviewBuild.uninstall(foo4, running: false) { _, _ in } }
        check("an app replaced between the scan and the review is blocked and needs a rescan",
              req4.items.first?.blocked?.contains("changed since the scan") == true && !req4.allowed.contains { $0.id == fooURL.path })

        // 5. A protected app never reaches the password step, even when its Trash move would be refused for permission.
        let foo5 = app("Foo", fooURL, [leftover(fooSupport)])
        let r5in = MainActor.assumeIsolated { confirmed(foo5) }
        ProtectedPaths.set(savedProtected + [fooURL.path])
        AppCleanup.trashMover = { url in if url.path.hasSuffix("/Foo-\(runID).app") { throw CocoaError(.fileWriteNoPermission) }; return try isolatedMover(url) }
        let r5 = AppEngine.uninstall(foo5, picked: r5in?.0 ?? [], trash: r5in?.1, adminStep: step, adminAllowed: allowAll)
        ProtectedPaths.set(savedProtected)
        check("a protection refusal never falls back to the password step",
              !r5.appRemoved && stepCalls.count == 0 && fm.fileExists(atPath: fooURL.path) && fm.fileExists(atPath: fooSupport.path))

        // 6. Refused only for permission, in an allowed folder, unchanged: the password step gets the reviewed app.
        let foo6 = app("Foo", fooURL, [leftover(fooSupport)])
        let r6in = MainActor.assumeIsolated { confirmed(foo6) }
        let r6 = AppEngine.uninstall(foo6, picked: r6in?.0 ?? [], trash: r6in?.1, adminStep: step, adminAllowed: allowAll)
        let expected6 = "\(fooURL.path)|\(foo6.identity.map { "\($0.device):\($0.inode)" } ?? "?")"
        check("a permission refusal for an unchanged app in an allowed folder goes to the password step with its reviewed identity",
              stepCalls.all.last == expected6 && r6.adminNote.contains("cancelled") && !fm.fileExists(atPath: fooSupport.path))
        _ = putBack(fooSupport)

        // 7. Refused for permission but not in a folder the password step may touch: nothing more happens.
        let before7 = stepCalls.count
        let foo7 = app("Foo", fooURL, [leftover(fooSupport)])
        let r7in = MainActor.assumeIsolated { confirmed(foo7) }
        let r7 = AppEngine.uninstall(foo7, picked: r7in?.0 ?? [], trash: r7in?.1, adminStep: step, adminAllowed: allowNone)
        check("a permission refusal outside the allowed folders doesn't use the password step, and the leftovers stay",
              stepCalls.count == before7 && !r7.appRemoved && fm.fileExists(atPath: fooSupport.path)
              && r7.errors.first?.contains("password step can't be used") == true)

        // 8. Refused for permission, then replaced before the fallback: no password step.
        let foo8 = app("Foo", fooURL, [leftover(fooSupport)])
        let r8in = MainActor.assumeIsolated { confirmed(foo8) }
        AppCleanup.trashMover = { url in
            if url.path.hasSuffix("/Foo-\(runID).app") {
                let f = FileManager.default
                try? f.removeItem(at: fooURL)
                try? f.createDirectory(at: fooURL, withIntermediateDirectories: true)
                try? Data("swapped during the attempt".utf8).write(to: fooURL.appendingPathComponent("content.txt"))
                throw CocoaError(.fileWriteNoPermission)
            }
            return try isolatedMover(url)
        }
        let r8 = AppEngine.uninstall(foo8, picked: r8in?.0 ?? [], trash: r8in?.1, adminStep: step, adminAllowed: allowAll)
        AppCleanup.trashMover = isolatedMover
        check("an app that changed before the fallback doesn't go to the password step, and no leftover moved",
              stepCalls.count == before7 + 0 && !r8.appRemoved && r8.errors.first?.contains("changed after you reviewed") == true
              && fm.fileExists(atPath: fooSupport.path) && log(fooSupport).isEmpty)
        let foo8b = app("Foo", fooURL, [leftover(fooSupport)])
        let r8bin = MainActor.assumeIsolated { confirmed(foo8b) }
        let protectPath = fooURL.path, protectedList = savedProtected
        AppCleanup.trashMover = { url in
            if url.path.hasSuffix("/Foo-\(runID).app") {
                ProtectedPaths.set(protectedList + [protectPath])   // protected between the refusal and the decision
                throw CocoaError(.fileWriteNoPermission)
            }
            return try isolatedMover(url)
        }
        let r8b = AppEngine.uninstall(foo8b, picked: r8bin?.0 ?? [], trash: r8bin?.1, adminStep: step, adminAllowed: allowAll)
        AppCleanup.trashMover = isolatedMover
        ProtectedPaths.set(savedProtected)
        check("an app protected between the permission refusal and the decision doesn't go to the password step, and no leftover moved",
              stepCalls.count == before7 && !r8b.appRemoved && fm.fileExists(atPath: fooSupport.path) && log(fooSupport).isEmpty)

        // A leftover's launch job is stopped only after its own file went to the Trash.
        let jobs = PathList()
        let stopJob: @Sendable (String) -> Void = { jobs.add($0) }
        let agentA = plain(base.appendingPathComponent("Agents/com.example.foo.a-\(runID).plist"), "a")
        let agentB = plain(base.appendingPathComponent("Agents/com.example.foo.b-\(runID).plist"), "b")
        var la = leftover(agentA); la.launchLabel = "com.example.foo.a"
        var lb = leftover(agentB); lb.launchLabel = "com.example.foo.b"
        let foo9 = app("Foo", fooURL, [la, lb])
        let r9in = MainActor.assumeIsolated { confirmed(foo9) }
        try? fm.removeItem(at: agentB); _ = plain(agentB, "replaced after review")
        _ = AppEngine.uninstall(foo9, picked: r9in?.0 ?? [], trash: r9in?.1, adminStep: step, adminAllowed: allowNone, stopUserJob: stopJob)
        check("only the moved leftover's launch job is stopped; a replaced one's job isn't touched",
              jobs.all == ["com.example.foo.a"] && fm.fileExists(atPath: agentB.path) && !fm.fileExists(atPath: agentA.path))
        _ = putBack(fooURL); _ = putBack(agentA)

        check("the fallback decision: only a permission refusal, allowed folder, no protection and an unchanged item qualify",
              AppEngine.adminFallbackRefusal(outcome: .permissionDenied("x"), reviewed: foo8.identity, current: foo8.identity,
                                             protection: nil, adminAllowed: true) == nil
              && AppEngine.adminFallbackRefusal(outcome: .failed("x"), reviewed: foo8.identity, current: foo8.identity,
                                                protection: nil, adminAllowed: true) != nil
              && AppEngine.adminFallbackRefusal(outcome: .skipped(.protected("p")), reviewed: foo8.identity, current: foo8.identity,
                                                protection: nil, adminAllowed: true) != nil
              && AppEngine.adminFallbackRefusal(outcome: .skipped(.changed(.replaced)), reviewed: foo8.identity, current: foo8.identity,
                                                protection: nil, adminAllowed: true) != nil
              && AppEngine.adminFallbackRefusal(outcome: .permissionDenied("x"), reviewed: foo8.identity, current: foo8.identity,
                                                protection: "Protected", adminAllowed: true) != nil
              && AppEngine.adminFallbackRefusal(outcome: .permissionDenied("x"), reviewed: foo8.identity, current: nil,
                                                protection: nil, adminAllowed: true) != nil)

        // 9. The privileged move itself checks the reviewed identity (run as you on throwaway files).
        let sys = base.appendingPathComponent("sys")
        try? fm.createDirectory(at: sys, withIntermediateDirectories: true)
        func privileged(_ items: [AppLeftover]) -> (report: AdminStep.Report, staging: URL?) {
            let script = AdminStep.script(items, uid: getuid(), allowed: { _ in true }, parentOwner: getuid(), chown: "/usr/bin/true")
            let r = Shell.run("/bin/sh", ["-c", script])
            let staging = AdminStep.parseStaging(r.output)
            return (AdminStep.Report.parse(r.output), staging)
        }
        let same = plain(sys.appendingPathComponent("same.plist"), "same")
        let swapped = plain(sys.appendingPathComponent("swapped.plist"), "reviewed")
        let unknown = plain(sys.appendingPathComponent("unknown.plist"), "?")
        let reviewedItems = [leftover(same, admin: true), leftover(swapped, admin: true), {
            var l = leftover(unknown, admin: true); l.identity = nil; return l }()]
        try? fm.removeItem(at: swapped); _ = plain(swapped, "replaced during the password dialog")
        let p9 = privileged(reviewedItems)
        let staged = p9.staging.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) }?.sorted() ?? []
        // Launch jobs and receipts: only after their item was verified and moved.
        let calls = base.appendingPathComponent("tools.log")
        func recorder(_ name: String) -> String {
            let t = base.appendingPathComponent("fake-\(name)")
            try? "#!/bin/sh\nprintf '\(name) %s\\n' \"$*\" >> \(AdminStep.q(calls.path))\n".write(to: t, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t.path)
            return t.path
        }
        let fakeLaunchctl = recorder("launchctl"), fakePkgutil = recorder("pkgutil")
        func privilegedWithTools(_ items: [AppLeftover]) -> (lines: [String], staging: URL?) {
            try? fm.removeItem(at: calls)
            let script = AdminStep.script(items, uid: getuid(), allowed: { _ in true }, parentOwner: getuid(), chown: "/usr/bin/true",
                                          launchctl: fakeLaunchctl, pkgutil: fakePkgutil)
            let r = Shell.run("/bin/sh", ["-c", script])
            let lines = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            return (lines, AdminStep.parseStaging(r.output))
        }
        let jobOK = plain(sys.appendingPathComponent("job-ok.plist"), "ok"), jobStale = plain(sys.appendingPathComponent("job-stale.plist"), "old")
        var okItem = leftover(jobOK, admin: true); okItem.launchLabel = "com.example.ok"; okItem.launchSystem = true
        var staleItem = leftover(jobStale, admin: true); staleItem.launchLabel = "com.example.stale"; staleItem.launchSystem = true
        var receipt = AppLeftover(id: "receipt:com.example.pkg", url: URL(fileURLWithPath: "/"), label: "Receipt", size: 0, include: true,
                                  note: nil, needsAdmin: true)
        receipt.receipt = "com.example.pkg"
        try? fm.removeItem(at: jobStale); _ = plain(jobStale, "replaced during the dialog")
        let mixed = privilegedWithTools([okItem, staleItem, receipt])
        check("the privileged step stops a job only after verifying and moving its file; a replaced item stops nothing",
              mixed.lines == ["launchctl bootout system/com.example.ok"] && fm.fileExists(atPath: jobStale.path))
        check("installer receipts aren't forgotten when any item wasn't verified", !mixed.lines.contains { $0.hasPrefix("pkgutil") })
        if let st = mixed.staging { try? fm.removeItem(at: st) }
        let jobOK2 = plain(sys.appendingPathComponent("job-ok2.plist"), "ok")
        var ok2 = leftover(jobOK2, admin: true); ok2.launchLabel = "com.example.ok2"; ok2.launchSystem = true
        let clean = privilegedWithTools([ok2, receipt])
        check("…and are forgotten once every item was verified and moved",
              clean.lines == ["launchctl bootout system/com.example.ok2", "pkgutil --forget com.example.pkg"])
        if let st = clean.staging { try? fm.removeItem(at: st) }

        check("the privileged move moves the unchanged item, puts back a replaced one and refuses an unidentified one",
              staged == ["0-same.plist"] && p9.report.changed == [1] && p9.report.unidentified == [2]
              && (try? String(contentsOf: swapped, encoding: .utf8)) == "replaced during the password dialog"
              && fm.fileExists(atPath: unknown.path))
        if let st = p9.staging { try? fm.removeItem(at: st) }

        // Only verified moves count: never inferred from the original being gone.
        let asYou: AppEngine.AdminStepRunner = { items, uid in
            let script = AdminStep.script(items, uid: uid, allowed: { _ in true }, parentOwner: uid, chown: "/usr/bin/true")
            return AdminStep.staging(fromOutput: Shell.run("/bin/sh", ["-c", script]).output, items: items, uid: uid)
        }
        let vOK = plain(sys.appendingPathComponent("v-ok.plist"), "ok")
        let vGone = plain(sys.appendingPathComponent("v-gone.plist"), "gone")
        let vLocked = plain(sys.appendingPathComponent("v-locked.plist"), "locked")
        let vSwapped = plain(sys.appendingPathComponent("v-swapped.plist"), "reviewed")
        let vItems = [leftover(vOK, admin: true), leftover(vGone, admin: true), leftover(vLocked, admin: true), leftover(vSwapped, admin: true)]
        try? fm.removeItem(at: vGone)                                         // gone before the privileged step
        chflags(vLocked.path, UInt32(UF_IMMUTABLE))                           // its move will fail
        try? fm.removeItem(at: vSwapped); _ = plain(vSwapped, "replaced")     // replaced
        let mixed2 = AppEngine.removeSystemItems(vItems, adminStep: asYou)
        chflags(vLocked.path, 0)
        check("only the verified item counts as removed: not one that vanished, failed to move or was replaced",
              mixed2.removed == [vOK] && mixed2.inTrash && !fm.fileExists(atPath: vOK.path)
              && fm.fileExists(atPath: vLocked.path) && fm.fileExists(atPath: vSwapped.path))
        check("each item that wasn't moved says why",
              mixed2.errors.contains { $0.hasPrefix("v-gone.plist:") && $0.contains("gone before the password step") }
              && mixed2.errors.contains { $0.hasPrefix("v-locked.plist:") && $0.contains("couldn't be moved") }
              && mixed2.errors.contains { $0.hasPrefix("v-swapped.plist:") && $0.contains("changed after you reviewed") })
        check("an item the privileged step didn't report on is never assumed moved",
              AdminStep.Report().notMovedReason(0)?.contains("can't confirm") == true
              && AdminStep.Report.parse("MACCLEANER-MOVED 0\nMACCLEANER-MISSING 1").notMovedReason(0) == nil
              && AdminStep.Report.parse("MACCLEANER-MOVED 0\nMACCLEANER-MISSING 1").notMovedReason(1) != nil)
        // The staging folder goes to the Trash only as the app-owned folder the step made (AppOwnedTrash.trashStaging),
        // proven by the step's own result and holding exactly the items reported moved. Real staging folders, made by the
        // root script run as you; anything unexpected leaves the folder untouched and says where it is.
        func stagedRun(_ name: String) -> (staging: AdminStep.Staging, item: URL)? {
            let u = plain(sys.appendingPathComponent("\(name)-\(runID).plist"), name)
            guard case .ok(let s) = asYou([leftover(u, admin: true)], getuid()) else { return nil }
            return (s, u)
        }
        func stagedItem(_ s: AdminStep.Staging) -> URL { s.url.appendingPathComponent(s.expected.keys.first ?? "none") }
        func drop(_ s: AdminStep.Staging?) {
            guard let s else { return }
            chflags(s.folder.path, 0); chmod(s.folder.path, 0o700)
            try? fm.removeItem(at: s.url)
        }
        let foreign = ["/private/var/tmp/MacCleaner-uninstall", base.path, base.appendingPathComponent("MacCleaner-uninstall.AbCdEf1234").path]
        check("only the step's own result is proof: a staging path that isn't exactly what mktemp makes is refused",
              foreign.allSatisfy { p in if case .failed = AdminStep.staging(fromOutput: "MACCLEANER-MOVED 0\n\(p)", items: [], uid: getuid()) { return true }; return false })
        if let loose = { () -> String? in
            var t = Array((AdminStep.stagingTemplate).utf8CString)
            return mkdtemp(&t).map { String(cString: $0) }
        }() {
            chmod(loose, 0o755)
            let r = AdminStep.staging(fromOutput: loose, items: [], uid: getuid())
            check("…and so is a staging folder others can open", { if case .failed = r { return true }; return false }())
            rmdir(loose)
        }
        check("the app-owned protection allows only the one folder, only as a Trash move",
              AppOwnedTrash.OneFolder(path: "/private/var/tmp/MacCleaner-uninstall.AbCdEf1234", rules: { _ in nil })
                .refusal(path: "/private/var/tmp/MacCleaner-uninstall.AbCdEf1234", disposition: .trash) == nil
              && AppOwnedTrash.OneFolder(path: "/private/var/tmp/MacCleaner-uninstall.AbCdEf1234", rules: { _ in nil })
                .refusal(path: "/private/var/tmp", disposition: .trash) != nil
              && AppOwnedTrash.OneFolder(path: "/private/var/tmp/MacCleaner-uninstall.AbCdEf1234", rules: { _ in nil })
                .refusal(path: "/private/var/tmp/MacCleaner-uninstall.AbCdEf1234", disposition: .permanentDelete) != nil)

        // A clean run: the folder reaches the Trash, logged as not restorable from Mac Cleaner (Finder only).
        if let (s, item) = stagedRun("st-ok") {
            let r = AppOwnedTrash.trashStaging(s, source: "Self-test staging")
            let entry = TrashLog.shared.present().first { $0.original == s.folder.path }
            check("a staging folder holding exactly the moved items goes to the Trash through the executor",
                  r.inTrash && r.error == nil && !fm.fileExists(atPath: s.folder.path) && !fm.fileExists(atPath: item.path)
                  && SelfTest.inIsolatedTrash(entry?.trashed))
            check("it is logged as not restorable item by item: Put Back points to Finder and moves nothing",
                  entry?.restorable == false && entry?.source == "Self-test staging"
                  && entry.map { TrashOps.restore($0)?.contains("Finder") == true && !fm.fileExists(atPath: s.folder.path) } == true)
        }
        // Moved, but its Trash-list record can't be written: still in the Trash (never moved back), and the report says
        // where it is and how to restore it from Finder.
        if let (s, _) = stagedRun("st-unrecorded") {
            let saved = AppCleanup.recordMove
            AppCleanup.recordMove = { _, _, _, _, _ in false }
            let before = SelfTest.isolatedMoves.count
            let r = AppOwnedTrash.trashStaging(s, source: "Self-test")
            AppCleanup.recordMove = saved
            let dest = SelfTest.isolatedMoves.count > before ? SelfTest.isolatedMoves.all.last : nil
            check("a staging folder moved to the Trash whose record couldn't be written stays in the Trash and is reported with its path and Finder recovery",
                  r.inTrash && r.error?.contains("couldn't be added to Mac Cleaner's Trash list") == true && r.error?.contains("Finder") == true
                  && !fm.fileExists(atPath: s.folder.path) && !TrashLog.shared.present().contains { $0.original == s.folder.path }
                  && dest.map { fm.fileExists(atPath: $0 + "/" + (s.expected.keys.first ?? "?")) && r.error?.contains($0) == true } == true)
            if let dest { try? fm.removeItem(atPath: (dest as NSString).deletingLastPathComponent) }
        }
        // Unexpected, modified, replaced, linked or missing contents; a replaced or opened folder: left untouched.
        func refused(_ name: String, _ change: (AdminStep.Staging) -> Void, _ expect: String) -> Bool {
            guard let (s, _) = stagedRun(name) else { return false }
            defer { drop(s) }
            change(s)
            let before = (try? fm.contentsOfDirectory(atPath: s.folder.path))?.sorted()
            let r = AppOwnedTrash.trashStaging(s, source: "Self-test")
            return !r.inTrash && r.error?.contains(expect) == true && r.error?.contains(s.folder.path) == true
                && fm.fileExists(atPath: s.folder.path) && (try? fm.contentsOfDirectory(atPath: s.folder.path))?.sorted() == before
        }
        check("a staging folder with an unexpected entry is left untouched, and the report says where it is",
              refused("st-extra", { try? Data("x".utf8).write(to: $0.url.appendingPathComponent("unexpected")) }, "something other than"))
        check("…also one hidden under the executor's own staging prefix",
              refused("st-hidden", { try? fm.createDirectory(at: $0.url.appendingPathComponent(".maccleaner-rm-planted"), withIntermediateDirectories: false) }, "something other than"))
        check("…a moved item that was modified after the move",
              refused("st-modified", { try? Data("written later, longer".utf8).write(to: stagedItem($0)) }, "isn't the item"))
        check("…a moved item that was replaced",
              refused("st-replaced", { try? fm.removeItem(at: stagedItem($0)); try? Data("st-replaced".utf8).write(to: stagedItem($0)) }, "isn't the item"))
        check("…a moved item replaced by a symlink",
              refused("st-link", { try? fm.removeItem(at: stagedItem($0)); try? fm.createSymbolicLink(atPath: stagedItem($0).path, withDestinationPath: "/etc") }, "isn't the item"))
        check("…a moved item that is missing",
              refused("st-missing", { try? fm.removeItem(at: stagedItem($0)) }, "weren't found"))
        check("…a staging folder others can open",
              refused("st-mode", { chmod($0.folder.path, 0o755) }, "no longer the private folder"))
        if let (s, item) = stagedRun("st-swapped") {
            // The proof names the folder the step made; a new folder with the same name and contents isn't it.
            let moved = s.url.deletingLastPathComponent().appendingPathComponent("moved-\(runID)")
            try? fm.moveItem(at: s.url, to: moved)
            try? fm.createDirectory(at: s.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try? fm.copyItem(at: moved.appendingPathComponent(s.expected.keys.first!), to: stagedItem(s))
            let r = AppOwnedTrash.trashStaging(s, source: "Self-test")
            check("a staging folder replaced after the step (same name, copied contents) is refused and left alone",
                  !r.inTrash && r.error?.contains("replaced after the password step") == true && fm.fileExists(atPath: s.folder.path))
            try? fm.removeItem(at: s.url); try? fm.removeItem(at: moved); _ = item
        }
        // The staging folder can't reach the Trash: the moved items are reported as staged, not as in the Trash.
        let vStaged = plain(sys.appendingPathComponent("v-staged.plist"), "staged")
        AppCleanup.trashMover = { url in
            if url.path.contains("MacCleaner-uninstall.") { throw CocoaError(.fileWriteUnknown) }
            return try isolatedMover(url)
        }
        var refusedStaging: AdminStep.Staging?
        let stagedOnly = AppEngine.removeSystemItems([leftover(vStaged, admin: true)], adminStep: { items, uid in
            let r = asYou(items, uid)
            if case .ok(let s) = r { refusedStaging = s }
            return r
        })
        AppCleanup.trashMover = isolatedMover
        check("items moved into staging whose folder can't reach the Trash are reported as staged, not in the Trash",
              stagedOnly.removed == [vStaged] && !stagedOnly.inTrash
              && stagedOnly.errors.contains { $0.contains("couldn't be sent to the Trash") && $0.contains(refusedStaging?.folder.path ?? "?") }
              && refusedStaging.map { fm.fileExists(atPath: stagedItem($0).path) } == true)
        drop(refusedStaging)
        // A staging folder the system won't list, and an empty one (nothing moved) that can or can't be removed.
        if let (s, _) = stagedRun("st-unreadable") {
            chmod(s.folder.path, 0)
            let r = AppOwnedTrash.trashStaging(s, source: "Self-test")
            chmod(s.folder.path, 0o700)
            check("a staging folder the system won't list is reported and left alone",
                  !r.inTrash && r.error?.contains("couldn't be checked") == true && fm.fileExists(atPath: stagedItem(s).path))
            drop(s)
        }
        let gone = plain(sys.appendingPathComponent("st-gone-\(runID).plist"), "gone")
        let goneItem = leftover(gone, admin: true)
        try? fm.removeItem(at: gone)
        if case .ok(let s) = asYou([goneItem], getuid()) {
            chflags(s.folder.path, UInt32(UF_IMMUTABLE))
            let stuck = AppOwnedTrash.trashStaging(s, source: "Self-test")
            chflags(s.folder.path, 0)
            check("an empty staging folder that can't be removed is reported, not cleaned up silently",
                  stuck.error?.contains("couldn't be removed") == true && fm.fileExists(atPath: s.folder.path))
            let removed = AppOwnedTrash.trashStaging(s, source: "Self-test")
            check("an empty staging folder (nothing moved) is removed", removed.inTrash && removed.error == nil && !fm.fileExists(atPath: s.folder.path))
            drop(s)
        }

        // The same rule in an uninstall: a leftover that vanished isn't counted, and the note says what happened.
        let fooSys = plain(sys.appendingPathComponent("com.example.foo-gone-\(runID).plist"), "daemon")
        // (The review blocks system leftovers outside the folders the password step may touch, and this one is in the
        // sandbox, so it is passed to the engine directly next to what the review approved.)
        let sysLeftover = leftover(fooSys, admin: true)
        let fooA = app("Foo", fooURL, [leftover(fooSupport)])
        let rAin = MainActor.assumeIsolated { confirmed(fooA) }
        try? fm.removeItem(at: fooSys)
        let rA = AppEngine.uninstall(fooA, picked: (rAin?.0 ?? []) + [sysLeftover], trash: rAin?.1, adminStep: asYou, adminAllowed: allowNone)
        check("an uninstall doesn't count a system leftover that vanished, and says no system item was moved",
              rA.appRemoved && rA.bytes == 15 && rA.adminNote.contains("No system item was moved")
              && rA.errors.contains { $0.contains("gone before the password step") })
        _ = putBack(fooURL); _ = putBack(fooSupport)

        // #41: History and the result say "in the Trash" only for an app that got there. The bundle's Trash move is
        // refused for permission, so the password step (run as you) moves it into staging.
        func viaPasswordStep(stagingReachesTrash: Bool) -> (AppEngine.UninstallResult, AdminStep.Staging?) {
            let a = app("Foo", fooURL, [leftover(fooSupport)])
            let picked = MainActor.assumeIsolated { confirmed(a) }
            AppCleanup.trashMover = { url in
                if url.path.hasSuffix("/Foo-\(runID).app") { throw CocoaError(.fileWriteNoPermission) }
                if !stagingReachesTrash && url.path.contains("MacCleaner-uninstall.") { throw CocoaError(.fileWriteUnknown) }
                return try isolatedMover(url)
            }
            var staging: AdminStep.Staging?
            let r = AppEngine.uninstall(a, picked: picked?.0 ?? [], trash: picked?.1, adminStep: { items, uid in
                let r = asYou(items, uid)
                if case .ok(let s) = r { staging = s }
                return r
            }, adminAllowed: allowAll)
            AppCleanup.trashMover = isolatedMover
            return (r, staging)
        }
        let (r41, st41) = viaPasswordStep(stagingReachesTrash: false)
        check("an app left in the password step's staging folder isn't reported or recorded as in the Trash (#41)",
              r41.appRemoved && !r41.appInTrash && r41.historyTitle(appName: "Foo") == "Foo leftovers"
              && r41.adminNote.contains(st41?.folder.path ?? "?") && r41.adminNote.contains("not yet the Trash")
              && !fm.fileExists(atPath: fooURL.path) && st41.map { fm.fileExists(atPath: $0.url.appendingPathComponent("0-Foo-\(runID).app").path) } == true)
        if let st41 { try? fm.moveItem(at: st41.url.appendingPathComponent("0-Foo-\(runID).app"), to: fooURL); try? fm.removeItem(at: st41.url) }
        _ = putBack(fooSupport)
        let (r41b, st41b) = viaPasswordStep(stagingReachesTrash: true)
        let st41bEntry = TrashLog.shared.present().first { $0.original == st41b?.folder.path }
        check("…and is, once its staging folder reached the Trash",
              r41b.appRemoved && r41b.appInTrash && r41b.historyTitle(appName: "Foo") == "Foo Uninstalled"
              && st41bEntry?.restorable == false && SelfTest.inIsolatedTrash(st41bEntry?.trashed))
        if let e = st41bEntry { try? fm.moveItem(atPath: e.trashed + "/0-Foo-\(runID).app", toPath: fooURL.path) }
        _ = putBack(fooSupport)
        check("a cancelled password step records only the leftovers that reached the Trash, or nothing",
              AppEngine.UninstallResult(appRemoved: false, appInTrash: false, bytes: 0).historyTitle(appName: "Foo") == nil
              && AppEngine.UninstallResult(appRemoved: false, appInTrash: false, bytes: 5).historyTitle(appName: "Foo") == "Foo leftovers")

        // 10. MCP uninstall_app, on a fake app in this home folder only.
        let mcpApp = folder(SafetyGuard.home.appendingPathComponent("Applications/SelfTestUninstall\(runID).app/Contents"), "x")
            .deletingLastPathComponent()
        (["CFBundleIdentifier": "com.example.selftest.uninstall\(runID)", "CFBundleName": "SelfTestUninstall\(runID)"] as NSDictionary)
            .write(to: mcpApp.appendingPathComponent("Contents/Info.plist"), atomically: true)
        approvals.asked = []; approvals.answer = true
        let mcpBundleID = "com.example.selftest.uninstall\(runID)"   // unique: only this fake app can match it
        let up = (try? MCPServer.call("uninstall_app", ["app": mcpBundleID])) as? [String: Any]
        let uc = (try? MCPServer.call("uninstall_app", ["app": mcpBundleID, "confirm": true,
                                                        "preview_id": up?["preview_id"] as? String ?? ""])) as? [String: Any]
        check("MCP uninstall_app removes the previewed app through the executor after the window, logged with who confirmed",
              uc?["app_removed"] as? Bool == true && !fm.fileExists(atPath: mcpApp.path) && approvals.asked.count == 1
              && log(mcpApp).first?.source == "Uninstall SelfTestUninstall\(runID) · AI assistant")
        check("the MCP-uninstalled app can be put back", putBack(mcpApp))
        try? fm.removeItem(at: mcpApp)

        // 11. Remove alerts (Extensions, Startup items).
        let extURL = folder(base.appendingPathComponent("Ext-\(runID).plugin"), "ext")
        func ext() -> ExtItem {
            ExtItem(id: extURL.path, url: extURL, name: "Ext", kind: "Plug-in", symbol: "puzzlepiece", allUsers: false, size: 3,
                    identity: AppCleanup.snapshot(extURL))
        }
        @MainActor func alert(_ m: ExtensionsModel, _ x: ExtItem, beforeConfirm: () -> Void = {}) {
            m.ask(x)
            beforeConfirm()
            let done = Slot<Bool>()
            AlertConfirmation.confirm(id: x.id, name: x.name, shown: m.pendingShown, module: "extensions") { trash, refusal in
                Task { @MainActor in await m.remove(x, trash: trash, refusal: refusal); done.value = true }
            }
            let end = Date().addingTimeInterval(60)
            while done.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        let extOK: Bool = MainActor.assumeIsolated {
            let m = ExtensionsModel()
            alert(m, ext())
            return m.message?.1 == false
        }
        check("an extension confirmed in its Remove alert goes to the Trash through the executor",
              extOK && !fm.fileExists(atPath: extURL.path) && log(extURL).first?.source == "Extensions" && putBack(extURL))
        let extStale: Bool = MainActor.assumeIsolated {
            let m = ExtensionsModel()
            let x = ext()
            alert(m, x, beforeConfirm: { try? fm.removeItem(at: extURL); _ = folder(extURL, "replaced while the alert was open") })
            return m.message?.1 == true && m.message?.0.contains("changed after you reviewed") == true
        }
        check("an extension replaced while its alert was open is left alone and reported", extStale && fm.fileExists(atPath: extURL.path))
        let extRescan: Bool = MainActor.assumeIsolated {
            let m = ExtensionsModel()
            let x = ext()
            try? fm.removeItem(at: extURL); _ = folder(extURL, "replaced before the alert")
            alert(m, x)
            return m.message?.0.contains("changed since the scan") == true
        }
        check("an extension replaced between the scan and its alert is refused (rescan)", extRescan && fm.fileExists(atPath: extURL.path))

        // All-users extension and system startup item: the alert's refusal stops them before the password prompt.
        let sysExt = folder(base.appendingPathComponent("AllUsersExt-\(runID).plugin"), "x")
        func allUsersExt(_ identity: FileIdentity?) -> ExtItem {
            ExtItem(id: sysExt.path, url: sysExt, name: "AllUsersExt", kind: "Plug-in", symbol: "puzzlepiece", allUsers: true, size: 1,
                    identity: identity)
        }
        let promptsBefore = stepCalls.count
        let staleAllUsers: String? = MainActor.assumeIsolated {
            let m = ExtensionsModel()
            let x = allUsersExt(AppCleanup.snapshot(sysExt))
            try? fm.removeItem(at: sysExt); _ = folder(sysExt, "replaced before the alert")
            m.ask(x)
            let refusal = m.pendingShown.refusal
            _ = wait { await m.remove(x, trash: nil, refusal: refusal, adminStep: step); return true }
            return m.message?.0
        }
        let unidentifiedAllUsers: String? = MainActor.assumeIsolated {
            let m = ExtensionsModel()
            let x = allUsersExt(nil)
            m.ask(x)
            let refusal = m.pendingShown.refusal
            _ = wait { await m.remove(x, trash: nil, refusal: refusal, adminStep: step); return true }
            return m.message?.0
        }
        check("an all-users extension that changed or wasn't identified is refused before the password prompt",
              stepCalls.count == promptsBefore && staleAllUsers?.contains("changed since the scan") == true
              && unidentifiedAllUsers?.contains("wasn't identified") == true && fm.fileExists(atPath: sysExt.path))
        let freshAllUsers: Bool = MainActor.assumeIsolated {
            let m = ExtensionsModel()
            let x = allUsersExt(AppCleanup.snapshot(sysExt))
            m.ask(x)
            let refusal = m.pendingShown.refusal
            _ = wait { await m.remove(x, trash: nil, refusal: refusal, adminStep: step); return true }
            return refusal == nil
        }
        check("an unchanged all-users extension goes to the password step with its scanned identity",
              freshAllUsers && stepCalls.count == promptsBefore + 1 && stepCalls.all.last?.hasPrefix(sysExt.path + "|") == true)
        let sysAgent = plain(base.appendingPathComponent("com.example.system-\(runID).plist"), "daemon")
        let staleSystem: String? = MainActor.assumeIsolated {
            let m = StartupModel()
            let st = StartupItem(id: sysAgent.path, url: sysAgent, label: "com.example.system-\(runID)", program: "/bin/true",
                                 owner: "SystemJob", scope: .system, running: true, runAtLoad: true, identity: AppCleanup.snapshot(sysAgent))
            try? fm.removeItem(at: sysAgent); _ = plain(sysAgent, "replaced before the alert")
            m.ask(st)
            let refusal = m.pendingShown.refusal
            _ = wait { await m.remove(st, trash: nil, refusal: refusal, adminStep: step, stopJob: stopJob); return true }
            return m.message?.0
        }
        check("a system startup item that changed is refused before the password prompt",
              stepCalls.count == promptsBefore + 1 && staleSystem?.contains("changed since the scan") == true && fm.fileExists(atPath: sysAgent.path))

        // A refused Trash approval (or a changed file) for your startup item stops nothing and moves nothing.
        let myAgent = plain(base.appendingPathComponent("com.example.mine-\(runID).plist"), "mine")
        let jobsBefore = jobs.count
        let refusedStartup: String? = MainActor.assumeIsolated {
            let m = StartupModel()
            let st = StartupItem(id: myAgent.path, url: myAgent, label: "com.example.mine-\(runID)", program: "/bin/true",
                                 owner: "Mine", scope: .user, running: true, runAtLoad: true, identity: AppCleanup.snapshot(myAgent))
            m.ask(st)
            guard let plan = AppCleanup.trashPlan([(st.id, st.owner, m.pendingShown.identity!, 0, "")], module: "startup") else { return nil }
            _ = wait { await m.remove(st, trash: .refused(plan: plan, reason: "No approval was issued (test)"), refusal: nil,
                                      adminStep: step, stopJob: stopJob); return true }
            return m.message?.0
        }
        check("a refused approval for a startup item runs no launchctl and leaves the file untouched",
              jobs.count == jobsBefore && refusedStartup?.contains("No approval was issued") == true
              && (try? String(contentsOf: myAgent, encoding: .utf8)) == "mine")
        let staleStartup: Bool = MainActor.assumeIsolated {
            let m = StartupModel()
            let st = StartupItem(id: myAgent.path, url: myAgent, label: "com.example.mine-\(runID)", program: "/bin/true",
                                 owner: "Mine", scope: .user, running: true, runAtLoad: true, identity: AppCleanup.snapshot(myAgent))
            m.ask(st)
            try? fm.removeItem(at: myAgent); _ = plain(myAgent, "replaced while the alert was open")
            let done = Slot<Bool>()
            AlertConfirmation.confirm(id: st.id, name: st.owner, shown: m.pendingShown, module: "startup") { trash, refusal in
                Task { @MainActor in await m.remove(st, trash: trash, refusal: refusal, adminStep: step, stopJob: stopJob); done.value = true }
            }
            let end = Date().addingTimeInterval(60)
            while done.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return m.message?.0.contains("changed after you reviewed") == true
        }
        check("a startup item replaced while its alert was open stops nothing and stays",
              staleStartup && jobs.count == jobsBefore && fm.fileExists(atPath: myAgent.path))

        let agent = plain(base.appendingPathComponent("com.example.selftest-\(runID).plist"), "agent")
        let startupOK: Bool = MainActor.assumeIsolated {
            let m = StartupModel()
            let s = StartupItem(id: agent.path, url: agent, label: "com.example.selftest-\(runID)", program: "/bin/true",
                                owner: "SelfTest", scope: .user, running: false, runAtLoad: false, identity: AppCleanup.snapshot(agent))
            m.ask(s)
            let done = Slot<Bool>()
            AlertConfirmation.confirm(id: s.id, name: s.owner, shown: m.pendingShown, module: "startup") { trash, refusal in
                Task { @MainActor in await m.remove(s, trash: trash, refusal: refusal, adminStep: step, stopJob: stopJob); done.value = true }
            }
            let end = Date().addingTimeInterval(60)
            while done.value == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return m.message?.1 == false
        }
        check("a startup item confirmed in its alert is moved through the executor, then stopped, and can be put back",
              startupOK && !fm.fileExists(atPath: agent.path) && log(agent).first?.source == "Startup items"
              && jobs.all.last == "com.example.selftest-\(runID)" && putBack(agent))
    }

    // MARK: Trash isolation

    /// The self-test's Trash: a folder in the throwaway home (set by `isolateTrash`).
    nonisolated(unsafe) static var isolatedTrash = URL(fileURLWithPath: "/nonexistent")
    /// Every Trash move the self-test made.
    static let isolatedMoves = PathList()

    final class PathList: @unchecked Sendable {   // `items` behind `lock`
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ p: String) { lock.lock(); items.append(p); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        var count: Int { all.count }
    }

    /// True once `isolateTrash` has replaced the Trash mover in this process.
    nonisolated(unsafe) static var trashIsIsolated = false

    /// True when `path` lies inside this run's isolated Trash folder.
    static func inIsolatedTrash(_ path: String?) -> Bool {
        guard let path, trashIsIsolated else { return false }
        return path.hasPrefix(isolatedTrash.path + "/") || path.hasPrefix(AppCleanup.physicalPath(isolatedTrash) + "/")
    }

    /// Points every Trash move (every cleanup executor's) at `dir` instead of the real Trash.
    static func isolateTrash(in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        isolatedTrash = dir
        trashIsIsolated = true
        AppCleanup.trashMover = { url in
            let slot = dir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: false)
            let dest = slot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)   // a rename: the item itself, never what a link points to
            isolatedMoves.add(dest.path)
            return dest
        }
    }

    #if MACCLEANER_TEST_HOOKS
    /// Asks a fresh process of this build where its Trash moves would go, given this run's isolated folder, and
    /// checks the probe can tell (the same process without the folder must say "system"). Destructive child
    /// processes run only when this is true, so a broken isolation hook fails these checks instead of moving files
    /// into the real Trash.
    static func subprocessTrashIsIsolated() -> Bool {
        func probe(_ extra: [String: String]) -> String {
            let p = Process()
            p.executableURL = Bundle.main.executableURL
            p.arguments = ["--cli", "status"]
            var env = ProcessInfo.processInfo.environment
            env["MACCLEANER_TEST_TRASH_DIR"] = nil
            p.environment = env.merging(extra.merging(["MACCLEANER_TEST_TRASH_PROBE": "1"]) { a, _ in a }) { _, new in new }
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isolated = probe(["MACCLEANER_TEST_TRASH_DIR": isolatedTrash.path])
        let unset = probe([:])
        let ok = isolated == "trash-destination: \(isolatedTrash.path)" && unset == "trash-destination: system"
        check("a child process reports the self-test's isolated Trash before it may move anything", ok)
        if !ok { print("    (skipping destructive child-process checks: got \"\(isolated)\" / \"\(unset)\")") }
        return ok
    }

    /// `--selftest-child <task> ...`: work the self-test runs in a separate process. Compiled only into the
    /// test-hooks build, never into Release. Even there it refuses unless started by the self-test
    /// (MACCLEANER_SELFTEST_CHILD=1) in a throwaway home folder.
    static func child(_ args: [String]) -> Int32 {
        guard ProcessInfo.processInfo.environment["MACCLEANER_SELFTEST_CHILD"] == "1",
              SafetyGuard.home.path != accountHome?.path else {
            print("This mode is only for the self-test.")
            return 2
        }
        guard args.count == 3, args[0] == "trash-then-die" else { return 2 }
        if let dir = ProcessInfo.processInfo.environment["MACCLEANER_TEST_TRASH_DIR"] { isolateTrash(in: URL(fileURLWithPath: dir)) }
        else { return 2 }   // never touch the real Trash
        let urls = [URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2])]
        // Kill this process the moment the first move has been recorded: no cleanup, no flushing.
        AppCleanup.afterRecording = { _ in kill(getpid(), SIGKILL) }
        let approval = MainActor.assumeIsolated { confirmTrashReview(urls) }
        guard case .some(.some(let a)) = approval else { return 3 }
        _ = wait { await AppCleanup.moveToTrash(a, source: "Self-test") }
        return 4   // not reached when the first move succeeds
    }
    #endif
}
