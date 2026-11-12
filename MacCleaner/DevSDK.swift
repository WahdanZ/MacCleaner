import Foundation
import Observation

/// One removable SDK component: a simulator runtime, a DeviceSupport folder, an Android system image, a Docker group…
struct SDKItem: Identifiable, Sendable, Hashable {
    enum Group: String, CaseIterable, Sendable { case xcode = "Xcode", android = "Android", docker = "Docker" }
    enum Action: Sendable, Hashable {
        case simRuntime(String)     // xcrun simctl runtime delete <uuid>
        case delete([URL])          // permanent; regenerable (re-download / re-copy)
        case trash(URL)             // not regenerable (Xcode archives)
        case docker(String)         // images | containers | volumes | build
    }

    let id: String
    let group: Group
    let kind: String
    let name: String
    let detail: String
    let size: Int64
    let reveal: URL?
    let action: Action
    /// Why it's probably still needed ("Used by 3 projects", "Emulator Pixel_8"). Never pre-selected.
    var inUse: String?
    /// Informational flag ("Newest").
    var note: String?
    var review = false
    let regen: String

    var isProtected: Bool {
        switch action {
        case .delete(let us): return us.contains { ProtectedPaths.isBlocked($0) }
        case .trash(let u): return ProtectedPaths.isBlocked(u)
        default: return false
        }
    }
    /// Safe to pick with "Select unused".
    var isUnused: Bool { inUse == nil && note == nil && !review && !isProtected }
}

/// What the user's projects ask for (compileSdk, ndkVersion, buildToolsVersion).
struct AndroidUsage: Sendable {
    var platforms: [String: Int] = [:]      // "35" → project count
    var ndk: [String: Int] = [:]
    var buildTools: [String: Int] = [:]
    var filesRead = 0
    var flutterProjects = 0
    var flutterCompileSdk: String?
    var flutterNdk: String?
    var timedOut = false
}

struct SDKScan: Sendable {
    var items: [SDKItem] = []
    var usage = AndroidUsage()
    var dockerStatus: String?           // nil = running; otherwise why there's nothing to show
}

/// Synchronous, shared by the window and the MCP server. Call off the main thread.
enum SDKEngine {
    static let home = SafetyGuard.home
    static let androidSDK = home.appendingPathComponent("Library/Android/sdk")
    private static let fm = FileManager.default

    static func scan(roots: [URL] = ProjectEngine.defaultRoots) -> SDKScan {
        var out = SDKScan()
        out.usage = androidUsage(roots: roots)
        out.items += xcode()
        out.items += android(out.usage)
        let d = docker()
        out.items += d.items
        out.dockerStatus = d.status
        return out
    }

    // MARK: Xcode

    static func xcode() -> [SDKItem] {
        var items: [SDKItem] = []

        // Simulator runtimes + how many simulators use each.
        var deviceCount: [String: Int] = [:]
        if let out = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 20).output,
           let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            for (rt, list) in devices { deviceCount[rt] = list.count }
        }
        if let out = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 20).output,
           let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: [String: Any]] {
            var rts: [(String, String, String, String, Int64)] = []   // uuid, os, version, identifier, size
            for (key, v) in json where UUID(uuidString: key) != nil && (v["deletable"] as? Bool) != false {
                let plat = (v["platformIdentifier"] as? String ?? "").lowercased()
                let os = plat.contains("iphone") ? "iOS" : plat.contains("watch") ? "watchOS"
                    : plat.contains("appletv") ? "tvOS" : plat.contains("xr") ? "visionOS" : "Simulator"
                rts.append((key, os, v["version"] as? String ?? "", v["runtimeIdentifier"] as? String ?? "",
                            (v["sizeBytes"] as? NSNumber)?.int64Value ?? 0))
            }
            let newest = Dictionary(grouping: rts, by: \.1).mapValues { $0.map(\.2).max(by: versionLess) ?? "" }
            for r in rts {
                let sims = deviceCount[r.3] ?? 0
                items.append(SDKItem(id: "simrt.\(r.0)", group: .xcode, kind: "Simulator runtimes",
                                     name: "\(r.1) \(r.2)", detail: sims > 0 ? "\(sims) simulator(s) use it" : "No simulators use it",
                                     size: r.4, reveal: nil, action: .simRuntime(r.0),
                                     inUse: nil, note: newest[r.1] == r.2 ? "Newest \(r.1)" : nil,
                                     regen: "Xcode › Settings › Components"))
            }
        }

        // DeviceSupport: one folder per device OS version.
        for os in SafetyGuard.deviceSupportOSes {
            let dir = home.appendingPathComponent("Library/Developer/Xcode/\(os) DeviceSupport")
            let kids = children(dir)
            let versions = kids.map { versionIn($0.lastPathComponent) }
            let top = versions.max(by: versionLess)
            for (k, v) in zip(kids, versions) {
                items.append(SDKItem(id: k.path, group: .xcode, kind: "Device support", name: "\(os) \(k.lastPathComponent)",
                                     detail: "Debug symbols copied from a device", size: Scanner.allocatedSize(k), reveal: k,
                                     action: .delete([k]), note: v == top ? "Newest" : nil,
                                     regen: "copied again when you connect a device on \(os) \(v)"))
            }
        }

        // Archives: not regenerable → Trash, REVIEW.
        let archives = home.appendingPathComponent("Library/Developer/Xcode/Archives")
        for day in children(archives) {
            for a in children(day) where a.pathExtension == "xcarchive" {
                let info = NSDictionary(contentsOf: a.appendingPathComponent("Info.plist"))
                let name = info?["Name"] as? String ?? a.deletingPathExtension().lastPathComponent
                let props = info?["ApplicationProperties"] as? [String: Any]
                let ver = props?["CFBundleShortVersionString"] as? String
                let date = info?["CreationDate"] as? Date
                items.append(SDKItem(id: a.path, group: .xcode, kind: "Archives",
                                     name: name + (ver.map { " \($0)" } ?? ""),
                                     detail: (date?.formatted(date: .abbreviated, time: .omitted) ?? day.lastPathComponent)
                                        + " · keep it if you need to read crash reports for this build",
                                     size: Scanner.allocatedSize(a), reveal: a, action: .trash(a), review: true,
                                     regen: "can't be rebuilt exactly; goes to the Trash"))
            }
        }
        return items
    }

    // MARK: Android

    static func android(_ use: AndroidUsage) -> [SDKItem] {
        var items: [SDKItem] = []
        let sdk = androidSDK
        guard fm.fileExists(atPath: sdk.path) else { return [] }

        // Emulators and the image each one boots.
        var avdImage: [String: [String]] = [:]   // "system-images/android-34/google_apis/arm64-v8a" → [avd names]
        let avdDir = home.appendingPathComponent(".android/avd")
        var avds: [SDKItem] = []
        for avd in children(avdDir) where avd.pathExtension == "avd" {
            let base = avd.deletingPathExtension().lastPathComponent
            let ini = avdDir.appendingPathComponent(base + ".ini")
            let cfg = (try? String(contentsOf: avd.appendingPathComponent("config.ini"), encoding: .utf8)) ?? ""
            var display = base
            for line in cfg.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                if kv[0] == "image.sysdir.1" {
                    let img = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    avdImage[img, default: []].append(base)
                }
                if kv[0] == "avd.ini.displayname" { display = kv[1] }
            }
            avds.append(SDKItem(id: avd.path, group: .android, kind: "Emulators", name: display,
                                detail: "Emulator with its saved state and data", size: Scanner.allocatedSize(avd),
                                reveal: avd, action: .delete([avd, ini]), review: true,
                                regen: "Device Manager in Android Studio (its data is lost)"))
        }

        // System images: system-images/<api>/<tag>/<abi>
        let images = sdk.appendingPathComponent("system-images")
        for api in children(images) {
            for tag in children(api) {
                for abi in children(tag) {
                    let rel = "system-images/\(api.lastPathComponent)/\(tag.lastPathComponent)/\(abi.lastPathComponent)"
                    let users = avdImage[rel] ?? []
                    items.append(SDKItem(id: abi.path, group: .android, kind: "System images",
                                         name: "\(api.lastPathComponent) · \(tag.lastPathComponent)",
                                         detail: abi.lastPathComponent, size: Scanner.allocatedSize(abi), reveal: abi,
                                         action: .delete([abi]),
                                         inUse: users.isEmpty ? nil : "Emulator \(users.joined(separator: ", "))",
                                         regen: "SDK Manager"))
                }
            }
        }

        // Platforms: android-<api>
        for p in children(sdk.appendingPathComponent("platforms")) {
            let api = p.lastPathComponent.replacingOccurrences(of: "android-", with: "")
            items.append(SDKItem(id: p.path, group: .android, kind: "Platforms", name: "Android API \(api)",
                                 detail: "android.jar and resources to compile against", size: Scanner.allocatedSize(p), reveal: p,
                                 action: .delete([p]), inUse: usedBy(api, use.platforms, flutter: use.flutterCompileSdk, use),
                                 regen: "SDK Manager, or automatically by Gradle"))
        }

        // NDK versions
        let ndks = children(sdk.appendingPathComponent("ndk"))
        for n in ndks {
            let v = n.lastPathComponent
            items.append(SDKItem(id: n.path, group: .android, kind: "NDK", name: "NDK \(v)",
                                 detail: "Native (C/C++) toolchain", size: Scanner.allocatedSize(n), reveal: n,
                                 action: .delete([n]), inUse: usedBy(v, use.ndk, flutter: use.flutterNdk, use),
                                 regen: "SDK Manager, or automatically by Gradle"))
        }

        // Build tools
        let bts = children(sdk.appendingPathComponent("build-tools"))
        let newestBT = bts.map(\.lastPathComponent).max(by: versionLess)
        for b in bts {
            let v = b.lastPathComponent
            items.append(SDKItem(id: b.path, group: .android, kind: "Build tools", name: "Build tools \(v)",
                                 detail: "aapt, d8, apksigner…", size: Scanner.allocatedSize(b), reveal: b,
                                 action: .delete([b]), inUse: usedBy(v, use.buildTools, flutter: nil, use),
                                 note: v == newestBT ? "Newest" : nil,
                                 regen: "SDK Manager, or automatically by Gradle"))
        }
        return items + avds
    }

    private static func usedBy(_ v: String, _ map: [String: Int], flutter: String?, _ use: AndroidUsage) -> String? {
        var parts: [String] = []
        if let n = map[v] { parts.append("Used by \(n) project\(n == 1 ? "" : "s")") }
        if let f = flutter, f == v, use.flutterProjects > 0 { parts.append("Flutter's default (\(use.flutterProjects) app\(use.flutterProjects == 1 ? "" : "s"))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Reads build.gradle(.kts) files in the project folders. Stops after 20 s (a folder may be waiting on a macOS prompt).
    static func androidUsage(roots: [URL]) -> AndroidUsage {
        let box = Box(AndroidUsage())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let skip: Set<String> = ["node_modules", "build", "Pods", "DerivedData", "target", "ios", "macos", "web", "windows", "linux"]
            let rx: [(String, WritableKeyPath<AndroidUsage, [String: Int]>)] = [
                (#"compileSdk(?:Version)?\s*[=(]?\s*(?:android-)?(\d+(?:\.\d+)?)"#, \.platforms),
                (#"ndkVersion\s*[=(]?\s*["']([\d.]+)["']"#, \.ndk),
                (#"buildToolsVersion\s*[=(]?\s*["']([\d.]+)["']"#, \.buildTools),
            ]
            for root in roots where !ProtectedPaths.isInsideProtected(root) {
                guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let u as URL in e {
                    let name = u.lastPathComponent
                    if e.level > 7 || skip.contains(name) { e.skipDescendants(); continue }
                    guard name == "build.gradle" || name == "build.gradle.kts" else { continue }
                    guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                    box.mutate { use in
                        use.filesRead += 1
                        if text.contains("flutter.compileSdkVersion") { use.flutterProjects += 1 }
                        for (pattern, kp) in rx {
                            for v in Set(matches(pattern, in: text)) { use[keyPath: kp][v, default: 0] += 1 }
                        }
                    }
                }
            }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 20) == .success
        var use = box.value
        use.timedOut = !finished
        (use.flutterCompileSdk, use.flutterNdk) = flutterDefaults()
        return use
    }

    /// Flutter's own default compileSdk / NDK, read from the installed Flutter SDK.
    static func flutterDefaults() -> (String?, String?) {
        let candidates = ["/opt/homebrew/bin/flutter", "/usr/local/bin/flutter",
                          home.appendingPathComponent("fvm/default/bin/flutter").path,
                          home.appendingPathComponent("flutter/bin/flutter").path,
                          home.appendingPathComponent("development/flutter/bin/flutter").path]
        guard let bin = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return (nil, nil) }
        let root = URL(fileURLWithPath: bin).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent("packages/flutter_tools/gradle/src/main")
        var sdk: String?, ndk: String?
        for rel in ["kotlin/FlutterExtension.kt", "groovy/flutter.groovy"] {
            guard let t = try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8) else { continue }
            sdk = sdk ?? matches(#"compileSdkVersion\s*(?::\s*Int)?\s*=\s*(\d+)"#, in: t).first
            ndk = ndk ?? matches(#"ndkVersion\s*(?::\s*String)?\s*=\s*"([\d.]+)""#, in: t).first
        }
        return (sdk, ndk)
    }

    // MARK: Docker

    static var dockerPath: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    static func docker() -> (items: [SDKItem], status: String?) {
        guard let docker = dockerPath else { return ([], "Docker isn't installed.") }
        let r = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 15)
        guard r.status == 0, let out = r.output else {
            return ([], "Docker isn't running. Start Docker Desktop to see images, containers and build cache.")
        }
        var items: [SDKItem] = []
        for line in out.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String] else { continue }
            let type = row["Type"] ?? ""
            let reclaim = parseDockerSize(row["Reclaimable"] ?? "0B")
            let total = row["TotalCount"] ?? "0", active = row["Active"] ?? "0"
            let detail = "\(total) total, \(active) in use · \(row["Size"] ?? "") on disk"
            let spec: (String, String, String, Bool, String)?   // kind, name, prune kind, review, regen
            switch type {
            case "Images": spec = ("Docker", "Unused images", "images", false, "docker pull / docker build")
            case "Containers": spec = ("Docker", "Stopped containers", "containers", true, "docker run (their files are lost)")
            case "Local Volumes": spec = ("Docker", "Unused volumes", "volumes", true, "nothing: volumes hold data such as databases")
            case "Build Cache": spec = ("Docker", "Build cache", "build", false, "the next docker build")
            default: spec = nil
            }
            guard let s = spec else { continue }
            items.append(SDKItem(id: "docker.\(s.2)", group: .docker, kind: s.0, name: s.1, detail: detail,
                                 size: reclaim, reveal: nil, action: .docker(s.2), review: s.3, regen: s.4))
        }
        return (items, nil)
    }

    static let dockerPrune: [String: [String]] = [
        "images": ["image", "prune", "-a", "-f"],
        "containers": ["container", "prune", "-f"],
        "volumes": ["volume", "prune", "-a", "-f"],
        "build": ["builder", "prune", "-a", "-f"],
    ]

    /// "1.234GB" / "512MB (40%)" / "0B" → bytes (Docker uses powers of 1000).
    static func parseDockerSize(_ s: String) -> Int64 {
        let head = s.split(separator: " ").first.map(String.init) ?? s
        guard let r = head.range(of: #"^[\d.]+"#, options: .regularExpression), let n = Double(head[r]) else { return 0 }
        let unit = head[r.upperBound...].uppercased()
        let mult: Double = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit] ?? 1
        return Int64(n * mult)
    }

    // MARK: Remove

    /// Why this item can't be removed, or nil.
    static func reason(_ item: SDKItem) -> String? {
        switch item.action {
        case .simRuntime(let id): return UUID(uuidString: id) == nil ? "Bad runtime id" : nil
        case .delete(let us):
            for u in us where fm.fileExists(atPath: u.path) {
                if let why = ProtectedPaths.reason(u) { return why }
                if !SafetyGuard.isAllowed(u) { return "Outside the SDK folders Mac Cleaner may delete" }
            }
            return nil
        case .trash(let u): return TrashGuard.reason(u)
        case .docker(let k): return dockerPrune[k] == nil ? "Unknown Docker group" : (dockerPath == nil ? "Docker isn't installed" : nil)
        }
    }

    /// `bytes` = everything removed; `trashed` = the part that went to the Trash (archives).
    static func remove(_ items: [SDKItem], progress: (String) -> Void = { _ in }) -> (bytes: Int64, trashed: Int64, errors: [String]) {
        var bytes: Int64 = 0, trashed: Int64 = 0
        var errors: [String] = []
        for item in items {
            progress(item.name)
            if let why = reason(item) { errors.append("\(item.name): \(why)"); continue }
            var ok = true
            switch item.action {
            case .simRuntime(let id):
                let r = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", id])
                if r.status != 0 { ok = false; errors.append("\(item.name): \(r.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "simctl failed")") }
            case .delete(let us):
                for u in us where fm.fileExists(atPath: u.path) {
                    do { try fm.removeItem(at: u) } catch { ok = false; errors.append("\(item.name): \(error.localizedDescription)") }
                }
                // Drop now-empty parents inside system-images (…/android-34/google_apis).
                if let first = us.first, first.path.contains("/system-images/") {
                    var p = first.deletingLastPathComponent()
                    for _ in 0..<2 where (try? fm.contentsOfDirectory(atPath: p.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true
                        && SafetyGuard.isAllowed(p) {
                        try? fm.removeItem(at: p)
                        p = p.deletingLastPathComponent()
                    }
                }
            case .trash(let u):
                if let e = AppEngine.trash(u, size: item.size, source: "Developer SDKs") { ok = false; errors.append("\(item.name): \(e)") }
            case .docker(let k):
                let r = Shell.run(dockerPath!, dockerPrune[k]!, timeout: 600)
                if r.status != 0 { ok = false; errors.append("\(item.name): \(r.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "docker failed")") }
            }
            if ok {
                bytes += item.size
                if case .trash = item.action { trashed += item.size }
            }
        }
        return (bytes, trashed, errors)
    }

    // MARK: Helpers

    static func children(_ dir: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// "iPhone15,2 17.5 (21F79)" → "17.5"
    static func versionIn(_ s: String) -> String {
        for part in s.split(separator: " ") where part.first?.isNumber == true && part.contains(".") { return String(part) }
        return s
    }

    static func versionLess(_ a: String, _ b: String) -> Bool { a.compare(b, options: .numeric) == .orderedAscending }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
}

/// Tiny lock-protected value for background work.
final class Box<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

@MainActor @Observable
final class SDKModel {
    enum Phase { case idle, scanning, done, removing }
    var phase: Phase = .idle
    var scan = SDKScan()
    var selected: Set<String> = []
    var filter: SDKItem.Group? = nil
    var current = ""
    var confirming = false
    var message: (text: String, isError: Bool)?

    var items: [SDKItem] { scan.items.filter { filter == nil || $0.group == filter } }
    var chosen: [SDKItem] { scan.items.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { chosen.reduce(0) { $0 + $1.size } }
    func total(_ g: SDKItem.Group?) -> Int64 { scan.items.filter { g == nil || $0.group == g }.reduce(0) { $0 + $1.size } }

    func load() async {
        phase = .scanning
        current = "Xcode, Android SDK and Docker…"
        let roots = ProjectsModel.savedRoots
        scan = await Task.detached(priority: .userInitiated) { SDKEngine.scan(roots: roots) }.value
        selected = selected.filter { id in scan.items.contains { $0.id == id } }
        phase = .done
    }

    func toggle(_ i: SDKItem) {
        guard !i.isProtected else { return }
        if selected.contains(i.id) { selected.remove(i.id) } else { selected.insert(i.id) }
    }

    func selectUnused() { selected.formUnion(items.filter(\.isUnused).map(\.id)) }

    func remove() async {
        let list = chosen
        guard !list.isEmpty else { return }
        phase = .removing
        let r = await Task.detached(priority: .userInitiated) { () -> (bytes: Int64, trashed: Int64, errors: [String]) in
            SDKEngine.remove(list) { name in Task { @MainActor [weak self] in self?.current = name } }
        }.value
        HistoryStore.shared.add("Developer SDKs Removed", bytes: r.bytes - r.trashed, symbol: "shippingbox", outcome: .deleted)
        HistoryStore.shared.add("Xcode Archives Moved to Trash", bytes: r.trashed, symbol: "archivebox", outcome: .trashed)
        message = r.errors.isEmpty
            ? ("Removed \(ByteText.string(r.bytes)) in \(list.count) item(s)."
               + (list.contains { if case .trash = $0.action { return true }; return false } ? " Archives went to the Trash." : ""), false)
            : ("Removed \(ByteText.string(r.bytes)). \(r.errors.count) problem(s): \(r.errors.prefix(2).joined(separator: "; "))", true)
        selected = []
        await load()
    }
}
