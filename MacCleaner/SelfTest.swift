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
        let mcp = (try? MCPServer.call("move_to_trash", ["paths": [keep.path], "confirm": true])) as? [String: Any]
        check("MCP move_to_trash refuses protected even with confirm",
              (mcp?["moved_to_trash"] as? [String])?.isEmpty == true && fm.fileExists(atPath: keep.path))
        check("Shredder refuses protected (same rule)", TrashGuard.reason(keep) != nil)
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

        print("Automation (weekly safe clean)")
        func target(_ id: String, _ c: CacheCategory, _ u: URL, rec: Bool = true) -> CleanTarget {
            CleanTarget(id: id, category: c, name: id, path: u.path, note: "", action: .removeItem(u),
                        recommended: rec, sizeBytes: 100, exists: true)
        }
        let picked = AutoClean.select([
            target("ok", .devCache, cacheItem),
            target("notrec", .devCache, cacheItem, rec: false),
            target("trash", .trash, h(".Trash/x")),
            target("dl", .appCaches, h("Downloads/x")),
            target("docs", .appCaches, h("Documents/x")),
        ]).map(\.id)
        check("takes recommended caches", picked.contains("ok"))
        check("skips not-recommended, Trash, Downloads and Documents", picked == ["ok"])
        ProtectedPaths.set(savedProtected + [cacheItem.path])
        check("skips protected caches", AutoClean.select([target("ok", .devCache, cacheItem)]).isEmpty)
        ProtectedPaths.set(savedProtected)

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
                       {"name":"MacCleaner-1.3.0.dmg.sha256","size":90,"browser_download_url":"\(base)MacCleaner-1.3.0.dmg.sha256"}]}
            """.utf8)
        }
        let rel = Updater.parseRelease(releaseJSON())
        check("reads the release: version, DMG, checksum and size",
              rel?.version == "1.3.0" && rel?.dmg.lastPathComponent == "MacCleaner-1.3.0.dmg"
              && rel?.checksum?.lastPathComponent == "MacCleaner-1.3.0.dmg.sha256" && rel?.size == 5_700_000)
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

        print("\n\(passed) passed, \(failed.count) failed")
        if !failed.isEmpty { print("FAILED:\n" + failed.map { "  - " + $0 }.joined(separator: "\n")) }
        return failed.isEmpty
    }
}
