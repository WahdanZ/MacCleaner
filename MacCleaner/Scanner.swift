import AppKit
import Foundation

enum Scanner {
    static let fm = FileManager.default
    static let home = SafetyGuard.home

    /// ~/.cache folders you chose to keep; listed, but not pre-selected.
    static let keepByDefault: Set<String> = ["uv"]
    /// ~/Library/Caches entries that are listed elsewhere (or are ours).
    static let claimedLibraryCaches: Set<String> = [
        "Yarn", "Homebrew", "CocoaPods", "pip", "JetBrains", "com.apple.dt.Xcode", "io.github.wahdanz.maccleaner", "local.maccleaner",
    ]
    /// App caches that hold something you may want to keep.
    static let reviewAppCaches: [String: String] = [
        "com.spotify.client": "Includes Spotify offline music; it re-downloads.",
    ]
    /// App caches smaller than this are merged into one row.
    static let smallCacheLimit: Int64 = 25_000_000

    // MARK: - Plan (cheap: lists folders, no sizes)

    static func plan() -> [CleanTarget] {
        var p: [CleanTarget] = []

        func dir(_ c: CacheCategory, _ id: String, _ name: String, _ rel: String, _ note: String,
                 contents: Bool = false, recommended: Bool = true) {
            let u = url(rel)
            p.append(CleanTarget(id: id, category: c, name: name, path: "~/" + rel, note: note,
                                 action: contents ? .removeContents(u) : .removeItem(u),
                                 recommended: recommended))
        }

        // Xcode
        dir(.xcode, "xcode.derived", "DerivedData", "Library/Developer/Xcode/DerivedData",
            "Build intermediates. Rebuilt on the next build.", contents: true)
        for os in SafetyGuard.deviceSupportOSes {
            dir(.xcode, "xcode.ds.\(os)", "\(os) DeviceSupport", "Library/Developer/Xcode/\(os) DeviceSupport",
                "Device debug symbols. Re-copied when a device connects.", contents: true)
        }
        dir(.xcode, "xcode.previews", "SwiftUI Previews", "Library/Developer/Xcode/UserData/Previews",
            "Preview builds and simulators. Recreated on demand.", contents: true)
        dir(.xcode, "xcode.simcaches", "Simulator caches", "Library/Developer/CoreSimulator/Caches",
            "Simulator dyld and runtime caches.", contents: true)
        dir(.xcode, "xcode.cache", "Xcode app cache", "Library/Caches/com.apple.dt.Xcode", "Xcode's own cache.")
        p.append(CleanTarget(id: "xcode.sims", category: .xcode, name: "Unavailable simulators",
                             path: "xcrun simctl delete unavailable",
                             note: "Simulators whose iOS runtime is gone.",
                             action: .deleteUnavailableSimulators))
        for rt in simRuntimes() {
            p.append(CleanTarget(id: "simrt.\(rt.id)", category: .xcode, name: "\(rt.name) simulator runtime",
                                 path: "xcrun simctl runtime delete \(rt.id)",
                                 note: "Needed to run \(rt.name) simulators. Re-download in Xcode › Settings › Components.",
                                 action: .deleteSimRuntime(rt.id), recommended: false,
                                 sizeBytes: rt.size, exists: rt.size > 0))
        }
        dir(.xcode, "xcode.archives", "Archives", "Library/Developer/Xcode/Archives",
            "Old app archives and dSYMs. Keep them if you symbolicate crashes.", contents: true, recommended: false)

        // Android & Flutter
        dir(.android, "gradle.caches", "Gradle caches", ".gradle/caches",
            "Dependencies and build cache. Re-downloaded on the next build.")
        dir(.android, "gradle.daemon", "Gradle daemon logs", ".gradle/daemon", "Old daemon logs.")
        dir(.android, "gradle.wrapper", "Gradle versions", ".gradle/wrapper/dists",
            "Downloaded Gradle distributions. Re-downloaded per project.", recommended: false)
        dir(.android, "android.cache", "Android SDK cache", ".android/cache", "SDK manager downloads.")
        dir(.android, "pub.hosted", "pub packages", ".pub-cache/hosted", "Re-downloaded by flutter pub get.")
        dir(.android, "pub.git", "pub git packages", ".pub-cache/git", "Re-cloned by flutter pub get.")
        dir(.android, "dart.server", "Dart analyzer cache", ".dartServer", "Rebuilt by your editor.")
        for avd in children(".android/avd") where avd.pathExtension == "avd" {
            let base = avd.deletingPathExtension().lastPathComponent
            let ini = avd.deletingLastPathComponent().appendingPathComponent(base + ".ini")
            p.append(CleanTarget(id: "avd.\(base)", category: .android, name: "Emulator \(base)",
                                 path: tilde(avd),
                                 note: "Android emulator and its saved state. Recreate it in Device Manager.",
                                 action: .removeItems([avd, ini]), recommended: false))
        }
        for img in children("Library/Android/sdk/system-images") where isDirectory(img) {
            p.append(CleanTarget(id: "sysimg.\(img.lastPathComponent)", category: .android,
                                 name: "System image \(img.lastPathComponent)", path: tilde(img),
                                 note: "Emulator OS image. Reinstall from SDK Manager.",
                                 action: .removeItem(img), recommended: false))
        }

        // Package managers
        dir(.packages, "npm", "npm cache", ".npm/_cacache", "Re-downloaded by npm install.")
        dir(.packages, "yarn", "Yarn cache", "Library/Caches/Yarn", "Re-downloaded by yarn install.")
        dir(.packages, "pnpm", "pnpm store", "Library/pnpm/store", "Re-downloaded by pnpm install.")
        dir(.packages, "bun", "Bun cache", ".bun/install/cache", "Re-downloaded by bun install.")
        dir(.packages, "brew", "Homebrew downloads", "Library/Caches/Homebrew", "Old bottles and downloads.")
        dir(.packages, "pods", "CocoaPods cache", "Library/Caches/CocoaPods", "Re-downloaded by pod install.")
        dir(.packages, "pip", "pip cache", "Library/Caches/pip", "Re-downloaded by pip install.")
        dir(.packages, "cargo.registry", "Cargo registry (Rust)", ".cargo/registry",
            "Downloaded crates. Re-downloaded by the next cargo build.", contents: true)
        dir(.packages, "cargo.git", "Cargo git checkouts (Rust)", ".cargo/git",
            "Git dependencies. Re-cloned by the next cargo build.", contents: true)
        dir(.packages, "go.modcache", "Go module cache", "go/pkg/mod",
            "Downloaded Go modules. Re-downloaded by go build (same as go clean -modcache).", contents: true)
        dir(.packages, "maven", "Maven repository (Java)", ".m2/repository",
            "Downloaded dependencies and anything you installed locally with mvn install. Re-downloaded on the next build; offline builds need network once.",
            contents: true, recommended: false)
        dir(.packages, "ivy", "Ivy / sbt cache (Scala)", ".ivy2/cache", "Re-downloaded by the next sbt build.",
            contents: true, recommended: false)
        dir(.packages, "gem.specs", "RubyGems index cache", ".gem/specs", "Gem index. Re-downloaded by gem install.", contents: true)
        dir(.packages, "bundler", "Bundler cache (Ruby)", ".bundle/cache", "Re-downloaded by bundle install.", contents: true)
        dir(.packages, "nuget", "NuGet packages (.NET)", ".nuget/packages",
            "Downloaded packages. Restored by dotnet restore.", contents: true, recommended: false)
        dir(.packages, "nuget.http", "NuGet HTTP cache", ".local/share/NuGet", "Download cache. Rebuilt by dotnet restore.", contents: true)
        dir(.packages, "hex", "Hex packages (Elixir)", ".hex/packages", "Re-downloaded by mix deps.get.", contents: true)
        dir(.packages, "cabal", "Cabal packages (Haskell)", ".cabal/packages", "Re-downloaded by cabal build.", contents: true)
        dir(.packages, "composer", "Composer cache (PHP)", ".composer/cache", "Re-downloaded by composer install.", contents: true)
        dir(.packages, "cocoapods.repos", "CocoaPods spec repos", ".cocoapods/repos",
            "Pod specs index. Re-cloned by pod install (takes a while).", contents: true, recommended: false)
        for conda in ["miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs", "opt/miniconda3/pkgs", "opt/anaconda3/pkgs", ".conda/pkgs"] {
            dir(.packages, "conda.\(conda)", "Conda package cache", conda,
                "Downloaded packages (same as conda clean). Environments keep working.", contents: true, recommended: false)
        }

        // IDEs & editors
        for (folder, label) in SafetyGuard.editorApps {
            let subs = SafetyGuard.editorCacheFolders.map { url("Library/Application Support/\(folder)/\($0)") }
            p.append(CleanTarget(id: "editor.\(folder)", category: .editors, name: "\(label) caches",
                                 path: "~/Library/Application Support/\(folder)/{Cache, CachedData, logs…}",
                                 note: "Editor caches and logs. Extensions and settings stay.",
                                 action: .removeItems(subs)))
        }
        dir(.editors, "jetbrains.caches", "JetBrains caches", "Library/Caches/JetBrains",
            "Indexes. Rebuilt the next time you open a project.")
        dir(.editors, "jetbrains.logs", "JetBrains logs", "Library/Logs/JetBrains", "IDE logs.")

        // ~/.cache
        for c in children(".cache") {
            let n = c.lastPathComponent
            let keep = keepByDefault.contains(n)
            p.append(CleanTarget(id: "cache.\(n)", category: .devCache, name: n, path: "~/.cache/\(n)",
                                 note: keep ? "You kept this last time. Re-downloads if removed."
                                            : "Tool cache. Recreated when needed.",
                                 action: .removeItem(c), recommended: !keep))
        }

        // App caches (~/Library/Caches)
        for c in children("Library/Caches") {
            let n = c.lastPathComponent
            if n.hasPrefix(".") || n.hasPrefix("com.apple.") || claimedLibraryCaches.contains(n) { continue }
            p.append(CleanTarget(id: "appcache.\(n)", category: .appCaches, name: appName(for: n),
                                 path: "~/Library/Caches/\(n)",
                                 note: reviewAppCaches[n] ?? "App cache. Quit the app first for the cleanest result.",
                                 action: .removeItem(c), recommended: reviewAppCaches[n] == nil))
        }

        // Sandboxed app caches (~/Library/Containers/<app>/Data/Library/Caches)
        for c in children("Library/Containers") {
            let id = c.lastPathComponent
            if id.hasPrefix(".") || id.hasPrefix("com.apple.") { continue }
            let caches = c.appendingPathComponent("Data/Library/Caches")
            p.append(CleanTarget(id: "container.\(id)", category: .appCaches,
                                 name: appName(for: id) + " (sandboxed)", path: tilde(caches),
                                 note: "Sandboxed app cache. Quit the app first.",
                                 action: .removeContents(caches)))
        }

        // Browser & Electron caches (~/Library/Application Support/<app>/…/Cache, GPUCache, …)
        for top in children("Library/Application Support") where isDirectory(top) {
            let n = top.lastPathComponent
            if n.hasPrefix(".") || n.hasPrefix("com.apple.") || SafetyGuard.editorApps.contains(where: { $0.0 == n })
                || ["MobileSync", "CallHistoryDB", "AddressBook"].contains(n) { continue }
            p.append(CleanTarget(id: "web.\(n)", category: .webCaches, name: "\(n) web caches",
                                 path: "~/Library/Application Support/\(n)",
                                 note: "Cache, Code Cache, GPUCache, Service Worker caches. Logins and settings stay.",
                                 action: .webCachesIn(top)))
        }

        // Logs
        let logs = children("Library/Logs").filter {
            $0.lastPathComponent != "JetBrains" && !$0.lastPathComponent.hasPrefix("com.apple.")
        }
        p.append(CleanTarget(id: "logs.user", category: .logs, name: "App logs", path: "~/Library/Logs",
                             note: "Log files and crash reports from your apps.", action: .removeItems(logs)))

        // Trash
        p.append(CleanTarget(id: "trash", category: .trash, name: "Trash", path: "~/.Trash",
                             note: "Files you already deleted. Emptying is permanent.",
                             action: .removeContents(url(".Trash")), recommended: false))
        return p
    }

    // MARK: - Measure (slow: walks the folder)

    static func measure(_ target: CleanTarget) -> CleanTarget {
        var t = target
        switch t.action {
        case .removeItem(let u):
            t.exists = fm.fileExists(atPath: u.path) && SafetyGuard.isAllowed(u)
            t.sizeBytes = t.exists ? allocatedSize(u) : 0
        case .removeContents(let u):
            t.exists = fm.fileExists(atPath: u.path) && SafetyGuard.isAllowed(u, allowContainer: true)
            t.sizeBytes = t.exists ? allocatedSize(u) : 0
        case .removeItems(let us):
            let ok = us.filter { fm.fileExists(atPath: $0.path) && SafetyGuard.isAllowed($0) }
            t.action = .removeItems(ok)
            t.exists = !ok.isEmpty
            t.sizeBytes = ok.reduce(0) { $0 + allocatedSize($1) }
        case .deleteSimRuntime:
            break
        case .webCachesIn(let top):
            var found: [URL] = []
            collectWebCaches(top, depth: 0, into: &found)
            let ok = found.filter { SafetyGuard.isAllowed($0) }
            t.action = .removeItems(ok)
            t.exists = !ok.isEmpty
            t.sizeBytes = ok.reduce(0) { $0 + allocatedSize($1) }
        case .deleteUnavailableSimulators:
            let udids = unavailableSimulatorIDs()
            let devices = url("Library/Developer/CoreSimulator/Devices")
            t.exists = !udids.isEmpty
            t.sizeBytes = udids.reduce(0) { $0 + allocatedSize(devices.appendingPathComponent($1)) }
            if t.exists && t.sizeBytes == 0 { t.sizeBytes = 1 }
        }
        return t
    }

    /// Drops empty targets, merges small app caches, sorts by category then size.
    static func finalize(_ ts: [CleanTarget]) -> [CleanTarget] {
        var out: [CleanTarget] = []
        var small: [CleanTarget] = []
        for t in ts where t.isCleanable {
            if case .removeContents = t.action, t.category == .appCaches, t.sizeBytes < smallCacheLimit { continue }
            if t.category == .appCaches && t.recommended && t.sizeBytes < smallCacheLimit {
                small.append(t)
            } else {
                out.append(t)
            }
        }
        if !small.isEmpty {
            let urls = small.flatMap { t -> [URL] in
                if case .removeItem(let u) = t.action { return [u] }
                return []
            }
            let names = small.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(6).map(\.name).joined(separator: ", ")
            var merged = CleanTarget(id: "appcache.small", category: .appCaches,
                                     name: "\(small.count) smaller app caches", path: "~/Library/Caches/…",
                                     note: names + (small.count > 6 ? ", …" : ""), action: .removeItems(urls))
            merged.exists = true
            merged.sizeBytes = small.reduce(0) { $0 + $1.sizeBytes }
            out.append(merged)
        }
        let order = Dictionary(uniqueKeysWithValues: CacheCategory.allCases.enumerated().map { ($1, $0) })
        return out.sorted {
            (order[$0.category] ?? 0, -$0.sizeBytes) < (order[$1.category] ?? 0, -$1.sizeBytes)
        }
    }

    // MARK: - Helpers

    static func url(_ rel: String) -> URL { home.appendingPathComponent(rel) }

    static func tilde(_ u: URL) -> String {
        u.path.hasPrefix(home.path) ? "~" + u.path.dropFirst(home.path.count) : u.path
    }

    static func children(_ rel: String) -> [URL] {
        (try? fm.contentsOfDirectory(at: url(rel), includingPropertiesForKeys: nil)) ?? []
    }

    static func isDirectory(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// "com.google.Chrome" → "Google Chrome" when the app is installed.
    static func appName(for folder: String) -> String {
        if folder.contains("."),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) {
            return fm.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }
        return folder
    }

    static func collectWebCaches(_ dir: URL, depth: Int, into out: inout [URL]) {
        guard depth < 4 else { return }
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                options: [.skipsHiddenFiles])) ?? []
        for k in kids {
            guard let v = try? k.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            let n = k.lastPathComponent
            if SafetyGuard.webCacheNames.contains(n) { out.append(k); continue }
            if n == "Service Worker" {
                for sub in ["CacheStorage", "ScriptCache"] {
                    let u = k.appendingPathComponent(sub)
                    if fm.fileExists(atPath: u.path) { out.append(u) }
                }
                continue
            }
            if ["app", "bundle", "framework", "plugin"].contains(k.pathExtension) { continue }
            collectWebCaches(k, depth: depth + 1, into: &out)
        }
    }

    struct SimRuntime { let id: String; let name: String; let size: Int64 }

    static func simRuntimes() -> [SimRuntime] {
        guard let out = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]).output,
              let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return json.compactMap { key, v in
            guard UUID(uuidString: key) != nil, (v["deletable"] as? Bool) != false else { return nil }
            let plat = (v["platformIdentifier"] as? String ?? "").lowercased()
            let os = plat.contains("iphone") ? "iOS" : plat.contains("watch") ? "watchOS"
                : plat.contains("appletv") ? "tvOS" : plat.contains("xr") ? "visionOS" : "Simulator"
            let version = v["version"] as? String ?? ""
            let size = (v["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            return SimRuntime(id: key, name: "\(os) \(version)", size: size)
        }
    }

    /// Full Disk Access lets the scan read Trash and protected app data.
    static func hasFullDiskAccess() -> Bool {
        (try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"))) != nil
    }

    static func unavailableSimulatorIDs() -> [String] {
        guard let out = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]).output,
              let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
    }

    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        let generation = SizeCache.generation
        if let cached = SizeCache.get(url.path) { return cached }
        let m = DirSize.measure(atPath: url.path)
        if m.complete { SizeCache.put(url.path, m.bytes, generation: generation) }
        return m.bytes
    }

    /// The previous folder walk (FileManager enumerator). Kept so the self-test can check DirSize against it.
    static func allocatedSizeSlow(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                    options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let r = try? f.resourceValues(forKeys: keys) {
                total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func totalBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(v?.volumeTotalCapacity ?? 0)
    }

    static func freeBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

enum Cleaner {
    /// Adds owner write permission to a folder tree (used only on paths a guard already allowed).
    static func makeOwnerWritable(_ url: URL) {
        let fm = FileManager.default
        func fix(_ u: URL) {
            if let a = try? fm.attributesOfItem(atPath: u.path), let p = a[.posixPermissions] as? NSNumber {
                try? fm.setAttributes([.posixPermissions: p.intValue | 0o700], ofItemAtPath: u.path)
            }
        }
        fix(url)
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isDirectory == true && v?.isSymbolicLink != true { fix(u) }
            }
        }
    }

    /// Deletes the given targets. Returns one message per failure.
    static func run(_ targets: [CleanTarget]) -> [String] {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        let fm = FileManager.default
        var errors: [String] = []

        func remove(_ url: URL, label: String) {
            guard SafetyGuard.isAllowed(url) else {
                errors.append("\(label): refused, \(url.lastPathComponent) is outside the allowed cache folders")
                return
            }
            do { try fm.removeItem(at: url) }
            catch {
                // Some caches are read-only on purpose (Go modules). The path is already allowed, so make it
                // writable for the owner and try once more.
                makeOwnerWritable(url)
                do { try fm.removeItem(at: url) } catch { errors.append("\(label): \(error.localizedDescription)") }
            }
        }

        for t in targets {
            switch t.action {
            case .removeItem(let url):
                remove(url, label: t.name)
            case .removeItems(let urls):
                for u in urls { remove(u, label: t.name) }
            case .removeContents(let url):
                guard SafetyGuard.isAllowed(url, allowContainer: true) else {
                    errors.append("\(t.name): refused, outside the allowed cache folders")
                    continue
                }
                let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for kid in kids { remove(kid, label: t.name) }
            case .deleteUnavailableSimulators:
                let r = Shell.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
                if r.status != 0 { errors.append("Simulators: \(r.output ?? "simctl failed")") }
            case .deleteSimRuntime(let id):
                guard UUID(uuidString: id) != nil else { errors.append("\(t.name): bad runtime id"); continue }
                let r = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", id])
                if r.status != 0 { errors.append("\(t.name): \(r.output ?? "simctl failed")") }
            case .webCachesIn:
                errors.append("\(t.name): not measured")
            }
        }
        return errors
    }
}

enum Shell {
    /// Runs a tool and returns its exit status and combined output. With a timeout, the tool is stopped after that many seconds.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval? = nil,
                    env: [String: String] = [:]) -> (status: Int32, output: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak p] in
                if let p, p.isRunning { p.terminate() }
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8))
    }
}
