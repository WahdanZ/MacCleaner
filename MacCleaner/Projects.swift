import AppKit
import Foundation
import Observation

/// A regenerable folder inside a project (node_modules, build, .dart_tool…).
struct ProjectArtifact: Identifiable, Sendable {
    let id: String          // absolute path
    let url: URL
    let rel: String         // path inside the project, e.g. "android/.gradle"
    let kind: String        // "npm packages", "Gradle build output"…
    let regen: String       // how it comes back
    let review: Bool        // not pre-selected (e.g. dist, .venv)
    var size: Int64
}

struct DevProject: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let stack: String       // Flutter, Node, Android…
    let lastTouched: Date?
    var artifacts: [ProjectArtifact]
    var total: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    var isProtected: Bool { ProtectedPaths.isInsideProtected(url) }

    func idleMonths(now: Date = Date()) -> Int {
        guard let d = lastTouched else { return 999 }
        return Calendar.current.dateComponents([.month], from: d, to: now).month ?? 0
    }
}

enum ProjectEngine {
    /// Files that make a folder a project.
    static let markers: [(String, String)] = [
        ("pubspec.yaml", "Flutter"), ("package.json", "Node"), ("build.gradle", "Android/Gradle"),
        ("build.gradle.kts", "Android/Gradle"), ("settings.gradle", "Android/Gradle"), ("settings.gradle.kts", "Android/Gradle"),
        ("Podfile", "iOS"), ("Package.swift", "Swift"), ("Cargo.toml", "Rust"), ("pom.xml", "Java/Maven"),
        ("pyproject.toml", "Python"), ("requirements.txt", "Python"), ("CMakeLists.txt", "C/C++"), ("go.mod", "Go"),
        ("setup.py", "Python"), ("Pipfile", "Python"), ("tox.ini", "Python"),
        ("*.csproj", ".NET"), ("*.fsproj", ".NET"), ("mix.exs", "Elixir"), ("*.tf", "Terraform"),
        ("stack.yaml", "Haskell"), ("*.cabal", "Haskell"), ("cabal.project", "Haskell"), ("build.zig", "Zig"),
        ("elm.json", "Elm"), ("composer.json", "PHP"), ("Cartfile", "iOS"), ("build.sbt", "Scala"), ("Gemfile", "Ruby"),
    ]

    /// Project files named after the project ("App.csproj", "main.tf") count as "*.<ext>" markers.
    static let extensionMarkers = ["csproj", "fsproj", "tf", "cabal"]

    static let pythonMarkers: Set<String> = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "tox.ini"]
    static let gradleMarkers: Set<String> = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    /// Folder name → (what it is, how it comes back, needs review, markers that make it valid there)
    static let artifactRules: [String: (kind: String, regen: String, review: Bool, needs: Set<String>)] = [
        "node_modules": ("npm packages", "npm / yarn / pnpm install", false, ["package.json"]),
        ".dart_tool": ("Dart tool cache", "flutter pub get", false, ["pubspec.yaml"]),
        "build": ("Build output", "next build", false,
                  ["pubspec.yaml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
                   "CMakeLists.txt", "package.json"]),
        ".gradle": ("Gradle project cache", "next Gradle build", false,
                    ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
        "Pods": ("CocoaPods", "pod install", false, ["Podfile"]),
        ".build": ("Swift build output", "swift build", false, ["Package.swift"]),
        "target": ("Build output", "cargo / mvn / sbt build", false, ["Cargo.toml", "pom.xml", "build.sbt"]),
        ".next": ("Next.js build cache", "next build", false, ["package.json"]),
        ".nuxt": ("Nuxt build cache", "nuxt build", false, ["package.json"]),
        ".turbo": ("Turborepo cache", "next build", false, ["package.json"]),
        ".svelte-kit": ("SvelteKit output", "next build", false, ["package.json"]),
        ".parcel-cache": ("Parcel cache", "next build", false, ["package.json"]),
        ".angular": ("Angular cache", "next build", false, ["package.json"]),
        ".expo": ("Expo cache", "expo start", false, ["package.json"]),
        ".cxx": ("Android native build", "next Gradle build", false, ["build.gradle", "build.gradle.kts"]),
        "dist": ("Distribution output", "next build (may be a release you want to keep)", true, ["package.json", "pyproject.toml"]),
        ".venv": ("Python virtualenv", "re-create + pip install (custom installs are lost)", true, pythonMarkers),
        "venv": ("Python virtualenv", "re-create + pip install (custom installs are lost)", true, pythonMarkers),
        "__pycache__": ("Python bytecode", "the next run", false, pythonMarkers),
        ".pytest_cache": ("pytest cache", "the next test run", false, pythonMarkers),
        ".mypy_cache": ("mypy cache", "the next type check", false, pythonMarkers),
        ".ruff_cache": ("Ruff cache", "the next lint", false, pythonMarkers),
        ".tox": ("tox environments", "tox", false, pythonMarkers),
        ".nox": ("nox environments", "nox", false, pythonMarkers.union(["noxfile.py"])),
        "bin": (".NET build output", "dotnet build", false, ["*.csproj", "*.fsproj"]),
        "obj": (".NET intermediate files", "dotnet build", false, ["*.csproj", "*.fsproj"]),
        "_build": ("Elixir build output", "mix compile", false, ["mix.exs"]),
        "deps": ("Elixir dependencies", "mix deps.get", false, ["mix.exs"]),
        ".elixir_ls": ("ElixirLS cache", "your editor", false, ["mix.exs"]),
        ".terraform": ("Terraform providers and modules", "terraform init", false, ["*.tf"]),
        ".stack-work": ("Haskell Stack build", "stack build", false, ["stack.yaml"]),
        "dist-newstyle": ("Cabal build output", "cabal build", false, ["*.cabal", "cabal.project"]),
        ".zig-cache": ("Zig cache", "zig build", false, ["build.zig"]),
        "zig-cache": ("Zig cache", "zig build", false, ["build.zig"]),
        "zig-out": ("Zig build output", "zig build", true, ["build.zig"]),
        "elm-stuff": ("Elm packages and build", "elm make", false, ["elm.json"]),
        ".kotlin": ("Kotlin build cache", "next Gradle build", false, gradleMarkers),
        "vendor": ("Composer packages", "composer install (some projects commit this folder)", true, ["composer.json"]),
        "Carthage": ("Carthage checkouts and builds", "carthage bootstrap", false, ["Cartfile"]),
    ]

    static let skipDirs: Set<String> = [".git", ".svn", ".hg", ".idea", ".vscode", "Library"]

    static var defaultRoots: [URL] {
        ["IdeaProjects", "StudioProjects", "AndroidStudioProjects", "Developer", "Projects", "Code", "dev", "src", "Documents"]
            .map { SafetyGuard.home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isDir(_ u: URL) -> Bool {
        guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return v.isDirectory == true && v.isSymbolicLink != true
    }

    /// Finds projects under the roots (depth ≤ 7). Nested projects (e.g. a Flutter app's android/ folder)
    /// add their build output to the outermost project.
    static func scan(roots: [URL], progress: @Sendable (String) -> Void) -> [DevProject] {
        let fm = FileManager.default
        var projects: [String: DevProject] = [:]
        var order: [String] = []

        func walk(_ dir: URL, depth: Int, owner: String?) {
            guard depth <= 7, !ProtectedPaths.isInsideProtected(dir) else { return }
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            var nameSet = Set(names)
            for ext in extensionMarkers where names.contains(where: { $0.hasSuffix("." + ext) }) { nameSet.insert("*." + ext) }
            let markersHere = markers.filter { nameSet.contains($0.0) }
            var currentOwner = owner
            if !markersHere.isEmpty && owner == nil {
                progress(dir.path)
                let stack = markersHere.first { $0.1 == "Flutter" }?.1 ?? markersHere[0].1
                projects[dir.path] = DevProject(id: dir.path, url: dir, name: dir.lastPathComponent, stack: stack,
                                                lastTouched: lastTouched(dir), artifacts: [])
                order.append(dir.path)
                currentOwner = dir.path
            }
            for n in names {
                let child = dir.appendingPathComponent(n)
                if let rule = artifactRules[n], !markersHere.isEmpty,
                   !rule.needs.isDisjoint(with: nameSet), let ownerPath = currentOwner, isDir(child) {
                    let rel = String(child.path.dropFirst(ownerPath.count + 1))
                    // A plain "build" folder in a Node-only project might be scripts, so it needs review.
                    let buildMarkers: Set<String> = ["pubspec.yaml", "build.gradle", "build.gradle.kts", "settings.gradle",
                                                     "settings.gradle.kts", "CMakeLists.txt"]
                    let review = rule.review || (n == "build" && buildMarkers.isDisjoint(with: nameSet))
                    projects[ownerPath]?.artifacts.append(
                        ProjectArtifact(id: child.path, url: child, rel: rel, kind: rule.kind, regen: rule.regen,
                                        review: review, size: 0))
                    continue
                }
                if n.hasPrefix(".") || skipDirs.contains(n) || n == "node_modules" { continue }
                if ["app", "framework", "bundle", "xcarchive", "photoslibrary"].contains(child.pathExtension) { continue }
                if isDir(child) { walk(child, depth: depth + 1, owner: currentOwner) }
            }
        }

        for r in roots where !ProtectedPaths.isInsideProtected(r) { walk(r, depth: 0, owner: nil) }

        // Measure build output in parallel.
        var list = order.compactMap { projects[$0] }.filter { !$0.artifacts.isEmpty }
        let flat = list.enumerated().flatMap { pi, p in p.artifacts.indices.map { (pi, $0) } }
        var sizes = [Int64](repeating: 0, count: flat.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: flat.count) { i in
                buf[i] = Scanner.allocatedSize(list[flat[i].0].artifacts[flat[i].1].url)
            }
        }
        for (i, pair) in flat.enumerated() { list[pair.0].artifacts[pair.1].size = sizes[i] }
        for i in list.indices { list[i].artifacts.removeAll { $0.size == 0 }; list[i].artifacts.sort { $0.size > $1.size } }
        return list.filter { $0.total > 0 }.sorted { $0.total > $1.total }
    }

    /// Newest change outside build output and .git (plus the git index), capped at 30k files.
    static func lastTouched(_ project: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var newest: Date?
        if let d = try? URL(fileURLWithPath: project.path + "/.git/index").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            newest = d
        }
        guard let e = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return newest }
        var count = 0
        for case let u as URL in e {
            let n = u.lastPathComponent
            if artifactRules[n] != nil || skipDirs.contains(n) { e.skipDescendants(); continue }
            count += 1
            if count > 30_000 { break }
            if let d = try? u.resourceValues(forKeys: Set(keys)).contentModificationDate, d > (newest ?? .distantPast) {
                newest = d
            }
        }
        return newest
    }

    /// nil if this artifact may be deleted. Re-checked right before deleting.
    static func reason(_ a: ProjectArtifact, in project: DevProject) -> String? {
        let fm = FileManager.default
        if let why = ProtectedPaths.reason(a.url) { return why }
        guard artifactRules[a.url.lastPathComponent] != nil else { return "Not a known build folder" }
        guard let v = try? a.url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              v.isSymbolicLink != true, v.isDirectory == true else { return "Not a real folder (symlink?)" }
        let resolved = a.url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = project.url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root + "/") else { return "Outside its project" }
        guard resolved.hasPrefix(SafetyGuard.home.path + "/") else { return "Outside your home folder" }
        guard fm.fileExists(atPath: a.url.path) else { return "Already gone" }
        return nil
    }

    /// Permanently deletes the artifacts (they are regenerable). Returns errors.
    static func clean(_ items: [(ProjectArtifact, DevProject)], progress: @Sendable (String) -> Void) -> (bytes: Int64, errors: [String]) {
        var bytes: Int64 = 0, errors: [String] = []
        for (a, p) in items {
            if let why = reason(a, in: p) { errors.append("\(p.name)/\(a.rel): \(why)"); continue }
            progress("\(p.name)/\(a.rel)")
            do { try FileManager.default.removeItem(at: a.url); bytes += a.size }
            catch { errors.append("\(p.name)/\(a.rel): \(error.localizedDescription)") }
        }
        return (bytes, errors)
    }
}

@MainActor @Observable
final class ProjectsModel {
    enum Phase { case idle, scanning, done, cleaning }
    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", idle = "Idle longest", name = "Name"
        var id: String { rawValue }
    }

    var phase: Phase = .idle
    var roots: [URL] = ProjectsModel.savedRoots {
        didSet { UserDefaults.standard.set(roots.map(\.path), forKey: "projectRoots") }
    }

    /// The folders the user picked on the Projects page (default: common project folders).
    nonisolated static var savedRoots: [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: "projectRoots") else { return ProjectEngine.defaultRoots }
        return paths.map { URL(fileURLWithPath: $0) }
    }
    var projects: [DevProject] = []
    var selected: Set<String> = []
    var expanded: Set<String> = []
    var minIdleMonths = 3
    var sort: Sort = .size
    var current = ""
    var confirming = false
    var message: (text: String, isError: Bool)?

    var visible: [DevProject] {
        var list = projects.filter { $0.idleMonths() >= minIdleMonths }
        switch sort {
        case .size: list.sort { $0.total > $1.total }
        case .idle: list.sort { ($0.lastTouched ?? .distantPast) < ($1.lastTouched ?? .distantPast) }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var allBytes: Int64 { projects.reduce(0) { $0 + $1.total } }
    var visibleBytes: Int64 { visible.reduce(0) { $0 + $1.total } }

    var selectedPairs: [(ProjectArtifact, DevProject)] {
        projects.flatMap { p in p.artifacts.filter { selected.contains($0.id) }.map { ($0, p) } }
    }
    var selectedBytes: Int64 { selectedPairs.reduce(0) { $0 + $1.0.size } }

    func scan() {
        guard phase != .scanning else { return }
        phase = .scanning
        message = nil
        let roots = self.roots
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ProjectEngine.scan(roots: roots) { p in Task { @MainActor [weak self] in self?.current = p } }
            }.value
            projects = found
            selected = []
            phase = .done
        }
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls where !roots.contains(u) { roots.append(u) }
    }

    func isSelectable(_ a: ProjectArtifact, _ p: DevProject) -> Bool { ProjectEngine.reason(a, in: p) == nil }

    func toggle(_ a: ProjectArtifact, _ p: DevProject) {
        guard isSelectable(a, p) else { return }
        if selected.contains(a.id) { selected.remove(a.id) } else { selected.insert(a.id) }
    }

    /// Selects/deselects every non-review artifact of a project.
    func toggleProject(_ p: DevProject) {
        let ids = p.artifacts.filter { !$0.review && isSelectable($0, p) }.map(\.id)
        if ids.allSatisfy(selected.contains) { ids.forEach { selected.remove($0) } } else { ids.forEach { selected.insert($0) } }
    }

    /// Selects build output (not review items) of every project shown by the idle filter.
    func selectVisible() {
        for p in visible { for a in p.artifacts where !a.review && isSelectable(a, p) { selected.insert(a.id) } }
    }

    func clean() async {
        let items = selectedPairs
        guard !items.isEmpty else { return }
        phase = .cleaning
        let freeBefore = Scanner.freeBytes()
        let r = await Task.detached(priority: .userInitiated) {
            ProjectEngine.clean(items) { p in Task { @MainActor [weak self] in self?.current = p } }
        }.value
        let gone = Set(items.map(\.0.id)).subtracting(items.filter { FileManager.default.fileExists(atPath: $0.0.url.path) }.map(\.0.id))
        for i in projects.indices { projects[i].artifacts.removeAll { gone.contains($0.id) } }
        projects.removeAll { $0.artifacts.isEmpty }
        selected.subtract(gone)
        HistoryStore.shared.add("Project Build Files Cleaned", bytes: r.bytes, symbol: "hammer",
                                outcome: .deleted, measuredFreeChange: max(0, Scanner.freeBytes() - freeBefore))
        message = r.errors.isEmpty
            ? ("Deleted \(ByteText.string(r.bytes)) of build files from \(Set(items.map(\.1.id)).count) project(s). Rebuild or reinstall packages when you open them again.", false)
            : ("Deleted \(ByteText.string(r.bytes)). \(r.errors.count) problem(s): \(r.errors.prefix(2).joined(separator: "; "))", true)
        phase = .done
    }
}
