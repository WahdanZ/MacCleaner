import Foundation

// Languages (version managers) and Homebrew for the Developer Tools › SDKs list.

extension SDKEngine {
    private static var fm: FileManager { .default }

    // MARK: Project version files

    static let versionFiles: Set<String> = [".nvmrc", ".node-version", ".python-version", ".ruby-version",
                                             "rust-toolchain", "rust-toolchain.toml", ".tool-versions", ".sdkmanrc"]

    /// (tool, version) pairs a project's version file asks for.
    static func runtimeVersions(file: String, text: String) -> [(String, String)] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        func clean(_ v: String) -> String { v.hasPrefix("v") ? String(v.dropFirst()) : v }
        switch file {
        case ".nvmrc", ".node-version": return lines.prefix(1).map { ("node", clean($0)) }
        case ".python-version": return lines.map { ("python", $0) }
        case ".ruby-version": return lines.prefix(1).map { ("ruby", $0.replacingOccurrences(of: "ruby-", with: "")) }
        case "rust-toolchain": return lines.prefix(1).map { ("rust", $0) }
        case "rust-toolchain.toml": return matches(#"channel\s*=\s*"([^"]+)""#, in: text).map { ("rust", $0) }
        case ".sdkmanrc":
            return lines.compactMap { l in
                let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            }
        case ".tool-versions":
            let names = ["nodejs": "node", "python": "python", "ruby": "ruby", "rust": "rust", "java": "java"]
            return lines.flatMap { l -> [(String, String)] in
                let parts = l.split(separator: " ").map(String.init)
                guard parts.count >= 2, let tool = names[parts[0]] else { return [] }
                return parts.dropFirst().map { (tool, clean($0)) }
            }
        default: return []
        }
    }

    /// "18" matches "18.19.0"; "3.11" matches "3.11.6"; exact names match too.
    static func versionMatches(_ installed: String, _ requested: String) -> Bool {
        let i = installed.hasPrefix("v") ? String(installed.dropFirst()) : installed
        let r = requested.hasPrefix("v") ? String(requested.dropFirst()) : requested
        return i == r || i.hasPrefix(r + ".") || i.hasPrefix(r + "-")
    }

    // MARK: Languages

    struct VersionManager {
        let tool: String            // key in AndroidUsage.runtimes
        let label: String           // "Node.js"
        let manager: String         // "nvm"
        let dir: String             // relative to home
        let defaultFile: String?    // file holding the default/global version
        let install: String         // "nvm install"
    }

    static let managers: [VersionManager] = [
        VersionManager(tool: "node", label: "Node.js", manager: "nvm", dir: ".nvm/versions/node",
                       defaultFile: ".nvm/alias/default", install: "nvm install"),
        VersionManager(tool: "node", label: "Node.js", manager: "fnm", dir: "Library/Application Support/fnm/node-versions",
                       defaultFile: nil, install: "fnm install"),
        VersionManager(tool: "node", label: "Node.js", manager: "Volta", dir: ".volta/tools/image/node",
                       defaultFile: nil, install: "volta install node@"),
        VersionManager(tool: "python", label: "Python", manager: "pyenv", dir: ".pyenv/versions",
                       defaultFile: ".pyenv/version", install: "pyenv install"),
        VersionManager(tool: "ruby", label: "Ruby", manager: "rbenv", dir: ".rbenv/versions",
                       defaultFile: ".rbenv/version", install: "rbenv install"),
        VersionManager(tool: "rust", label: "Rust", manager: "rustup", dir: ".rustup/toolchains",
                       defaultFile: nil, install: "rustup toolchain install"),
    ]

    static func languages(_ use: AndroidUsage) -> [SDKItem] {
        var items: [SDKItem] = []
        for m in managers {
            let dir = home.appendingPathComponent(m.dir)
            let versions = children(dir)
            guard !versions.isEmpty else { continue }
            var defaults: [String] = []
            if let f = m.defaultFile, let t = try? String(contentsOf: home.appendingPathComponent(f), encoding: .utf8) {
                defaults = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if m.manager == "rustup",
               let t = try? String(contentsOf: home.appendingPathComponent(".rustup/settings.toml"), encoding: .utf8) {
                defaults = matches(#"default_toolchain\s*=\s*"([^"]+)""#, in: t)
            }
            let newest = versions.map(\.lastPathComponent).max(by: versionLess)
            for v in versions {
                let name = v.lastPathComponent
                var reasons: [String] = []
                if defaults.contains(where: { versionMatches(name, $0) || name == $0 }) { reasons.append("\(m.manager) default") }
                let projects = (use.runtimes[m.tool] ?? [:]).filter { versionMatches(name, $0.key) }.values.reduce(0, +)
                if projects > 0 { reasons.append("Used by \(projects) project\(projects == 1 ? "" : "s")") }
                items.append(SDKItem(id: v.path, group: .languages, kind: "\(m.label) versions (\(m.manager))",
                                     name: "\(m.label) \(name.hasPrefix("v") ? String(name.dropFirst()) : name)",
                                     detail: "Installed with \(m.manager)", size: Scanner.allocatedSize(v), reveal: v,
                                     action: .delete([v]), inUse: reasons.isEmpty ? nil : reasons.joined(separator: " · "),
                                     note: name == newest && reasons.isEmpty ? "Newest" : nil,
                                     regen: "\(m.install) \(name.hasPrefix("v") ? String(name.dropFirst()) : name)"))
            }
        }

        // SDKMAN and asdf: <root>/<tool>/<version>
        for (root, manager, current) in [(".sdkman/candidates", "SDKMAN", "current"), (".asdf/installs", "asdf", "")] {
            for toolDir in children(home.appendingPathComponent(root)) {
                let tool = toolDir.lastPathComponent
                let currentTarget = current.isEmpty ? nil
                    : (try? fm.destinationOfSymbolicLink(atPath: toolDir.appendingPathComponent(current).path))
                        .map { URL(fileURLWithPath: $0).lastPathComponent }
                for v in children(toolDir) where v.lastPathComponent != current {
                    let name = v.lastPathComponent
                    let key = tool == "nodejs" ? "node" : tool
                    var reasons: [String] = []
                    if name == currentTarget { reasons.append("\(manager) default") }
                    let projects = (use.runtimes[key] ?? [:]).filter { versionMatches(name, $0.key) }.values.reduce(0, +)
                    if projects > 0 { reasons.append("Used by \(projects) project\(projects == 1 ? "" : "s")") }
                    items.append(SDKItem(id: v.path, group: .languages, kind: "\(tool.capitalized) versions (\(manager))",
                                         name: "\(tool.capitalized) \(name)", detail: "Installed with \(manager)",
                                         size: Scanner.allocatedSize(v), reveal: v, action: .delete([v]),
                                         inUse: reasons.isEmpty ? nil : reasons.joined(separator: " · "),
                                         regen: manager == "SDKMAN" ? "sdk install \(tool) \(name)" : "asdf install \(tool) \(name)"))
                }
            }
        }

        // JDKs downloaded by IntelliJ / Android Studio
        for jdk in children(home.appendingPathComponent("Library/Java/JavaVirtualMachines")) {
            let info = NSDictionary(contentsOf: jdk.appendingPathComponent("Contents/Info.plist"))
            let display = (info?["CFBundleName"] as? String) ?? jdk.lastPathComponent
            items.append(SDKItem(id: jdk.path, group: .languages, kind: "Java JDKs", name: display,
                                 detail: "Downloaded by an IDE into ~/Library/Java", size: Scanner.allocatedSize(jdk),
                                 reveal: jdk, action: .delete([jdk]), review: true,
                                 regen: "your IDE's Download JDK option"))
        }
        return items
    }

    // MARK: Homebrew

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { fm.isExecutableFile(atPath: $0) }
    }

    /// No auto-update or auto-cleanup side effects when Mac Cleaner runs brew.
    static let brewEnv = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ENV_HINTS": "1"]

    static func runBrew(_ args: [String], timeout: TimeInterval) -> (status: Int32, output: String?) {
        guard let brew = brewPath else { return (-1, "Homebrew isn't installed") }
        return Shell.run(brew, args, timeout: timeout, env: brewEnv)
    }

    struct BrewIndex {
        var formulae: [[String: Any]] = []
        var casks: [[String: Any]] = []
    }

    static func brewIndex() -> BrewIndex? {
        guard let out = runBrew(["info", "--json=v2", "--installed"], timeout: 90).output,
              let start = out.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else { return nil }
        return BrewIndex(formulae: json["formulae"] as? [[String: Any]] ?? [], casks: json["casks"] as? [[String: Any]] ?? [])
    }

    /// App file names ("Visual Studio Code.app") installed by Homebrew casks → cask token.
    static func caskApps(_ index: BrewIndex? = nil) -> [String: String] {
        guard let idx = index ?? brewIndex() else { return [:] }
        var map: [String: String] = [:]
        for c in idx.casks {
            let token = c["full_token"] as? String ?? c["token"] as? String ?? ""
            for app in caskAppNames(c) { map[app] = token }
        }
        return map
    }

    static func caskAppNames(_ c: [String: Any]) -> [String] {
        let artifacts = c["artifacts"] as? [[String: Any]] ?? []
        return artifacts.compactMap { $0["app"] as? [Any] }.flatMap { $0 }.compactMap { a -> String? in
            if let s = a as? String { return URL(fileURLWithPath: s).lastPathComponent }
            if let d = a as? [String: Any], let target = d["target"] as? String { return URL(fileURLWithPath: target).lastPathComponent }
            return nil
        }
    }

    static func homebrew() -> (items: [SDKItem], status: String?) {
        guard let brew = brewPath else { return ([], "Homebrew isn't installed.") }
        let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent()
        // `brew cleanup --dry-run` only reads, and does not need the package list, so it runs alongside `brew info`.
        let cleanup = Box<String?>(nil)
        let cleanupDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = runBrew(["cleanup", "--dry-run"], timeout: 90).output
            cleanup.mutate { $0 = out }
            cleanupDone.signal()
        }
        guard let idx = brewIndex() else { return ([], "Couldn't read the Homebrew package list.") }
        var items: [SDKItem] = []

        // Who depends on whom, among installed formulae.
        var dependents: [String: [String]] = [:]
        for f in idx.formulae {
            let name = f["name"] as? String ?? ""
            for d in f["dependencies"] as? [String] ?? [] {
                // Tap formulae list dependencies as "user/tap/name"; index by the short name too.
                let short = d.split(separator: "/").last.map(String.init) ?? d
                dependents[short, default: []].append(name)
            }
        }
        for f in idx.formulae {
            let name = f["name"] as? String ?? ""
            let full = f["full_name"] as? String ?? name
            let installed = (f["installed"] as? [[String: Any]])?.first
            let version = installed?["version"] as? String ?? ""
            let onRequest = installed?["installed_on_request"] as? Bool ?? true
            let users = dependents[name] ?? []
            let cellar = prefix.appendingPathComponent("Cellar/\(name)")
            items.append(SDKItem(id: "brew.formula.\(full)", group: .homebrew, kind: "Homebrew formulae",
                                 name: name, detail: [version, f["desc"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
                                    .joined(separator: " · "),
                                 size: Scanner.allocatedSize(cellar), reveal: cellar, action: .brew(["uninstall", full]),
                                 inUse: users.isEmpty ? nil : "Needed by \(users.prefix(3).joined(separator: ", "))\(users.count > 3 ? "…" : "")",
                                 note: users.isEmpty && onRequest ? "Installed by you" : nil,
                                 regen: "brew install \(name)"))
        }
        for c in idx.casks {
            let token = c["token"] as? String ?? ""
            let full = c["full_token"] as? String ?? token
            let display = (c["name"] as? [String])?.first ?? token
            let version = c["installed"] as? String ?? ""
            let apps = caskAppNames(c).map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0.path) }
            let caskroom = prefix.appendingPathComponent("Caskroom/\(token)")
            let size = Scanner.allocatedSize(caskroom) + apps.reduce(0) { $0 + Scanner.allocatedSize($1) }
            items.append(SDKItem(id: "brew.cask.\(full)", group: .homebrew, kind: "Homebrew apps (casks)",
                                 name: display, detail: "\(token) \(version)" + (apps.isEmpty ? "" : " · \(apps.map(\.lastPathComponent).joined(separator: ", "))"),
                                 size: size, reveal: apps.first ?? caskroom, action: .brew(["uninstall", "--cask", full]),
                                 note: "Installed by you", review: true,
                                 regen: "brew install --cask \(token) (the app is deleted, not moved to the Trash)"))
        }

        // Old versions and downloads that `brew cleanup` would remove.
        cleanupDone.wait()
        if let out = cleanup.value,
           let line = out.split(separator: "\n").last(where: { $0.contains("would free approximately") }) {
            let size = parseBinarySize(String(line))
            if size > 0 {
                items.append(SDKItem(id: "brew.cleanup", group: .homebrew, kind: "Homebrew cleanup",
                                     name: "Old versions and downloads", detail: "What brew cleanup removes",
                                     size: size, reveal: nil, action: .brew(["cleanup"]),
                                     regen: "brew downloads them again if ever needed"))
            }
        }
        return (items, nil)
    }

    /// "…approximately 1.2GB of disk space." → bytes (Homebrew uses powers of 1024).
    static func parseBinarySize(_ s: String) -> Int64 {
        guard let r = s.range(of: #"([\d.]+)\s*(B|KB|MB|GB|TB)"#, options: .regularExpression) else { return 0 }
        let part = String(s[r])
        let num = Double(part.filter { $0.isNumber || $0 == "." }) ?? 0
        let mult: Double = part.hasSuffix("TB") ? 1_099_511_627_776 : part.hasSuffix("GB") ? 1_073_741_824
            : part.hasSuffix("MB") ? 1_048_576 : part.hasSuffix("KB") ? 1024 : 1
        return Int64(num * mult)
    }

    /// Only these shapes run: uninstall <name>, uninstall --cask <token>, cleanup.
    static func brewArgsValid(_ args: [String]) -> Bool {
        let name = #"^[A-Za-z0-9@._+-]+(/[A-Za-z0-9@._+-]+){0,2}$"#
        func ok(_ s: String) -> Bool { s.range(of: name, options: .regularExpression) != nil && !s.hasPrefix("-") }
        switch args.count {
        case 1: return args == ["cleanup"]
        case 2: return args[0] == "uninstall" && ok(args[1])
        case 3: return args[0] == "uninstall" && args[1] == "--cask" && ok(args[2])
        default: return false
        }
    }
}
