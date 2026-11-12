import Foundation

/// `mac-cleaner` command line. Every command runs the same code as the MCP tools,
/// so the same guards apply (protected paths, preview before delete).
/// Started as: "Mac Cleaner" --cli <command> [args]  (the installed `mac-cleaner` script does this).
enum CLI {
    private struct Command {
        let name: String
        let usage: String
        let help: String
        let tool: String
        var destructive = false
        var prepare: String? = nil                 // tool to run first in this process (scan before clean)
        let args: (Parsed) throws -> [String: Any]
    }

    struct Parsed {
        var positional: [String] = []
        var flags: [String: String] = [:]          // --key value  or  --flag → "true"
        func flag(_ k: String) -> Bool { flags[k] != nil }
        func int(_ k: String) -> Int? { flags[k].flatMap(Int.init) }
        func double(_ k: String) -> Double? { flags[k].flatMap(Double.init) }
    }

    struct UsageError: Error, CustomStringConvertible { let description: String }

    private static let valueFlags: Set<String> = ["limit", "min-mb", "idle", "sort", "group"]

    private static let commands: [Command] = [
        Command(name: "status", usage: "status", help: "Free, used and total disk space.", tool: "disk_status") { _ in [:] },
        Command(name: "scan", usage: "scan [--min-mb N]", help: "Scan 340+ cache locations (read-only).", tool: "scan_caches") { p in
            p.double("min-mb").map { ["min_size_mb": $0] } ?? [:] },
        Command(name: "clean", usage: "clean (--recommended | ID…)", help: "Delete caches (they rebuild). Previews first.",
                tool: "clean_caches", destructive: true, prepare: "scan_caches") { p in
            if p.flag("recommended") { return ["recommended": true] }
            guard !p.positional.isEmpty else { throw UsageError(description: "Pass --recommended or item ids from `mac-cleaner scan`.") }
            return ["ids": p.positional] },
        Command(name: "usage", usage: "usage [PATH] [--limit N]", help: "Largest folders and files inside PATH (default ~).", tool: "disk_usage") { p in
            var a: [String: Any] = ["path": p.positional.first ?? "~"]
            if let l = p.int("limit") { a["limit"] = l }
            return a },
        Command(name: "dupes", usage: "dupes [PATH…] [--min-mb N]", help: "Find duplicate files by content.", tool: "find_duplicates") { p in
            var a: [String: Any] = [:]
            if !p.positional.isEmpty { a["paths"] = p.positional }
            if let m = p.double("min-mb") { a["min_size_mb"] = m }
            return a },
        Command(name: "apps", usage: "apps [QUERY] [--sort size|name|last_used|cache]", help: "Installed apps with sizes.", tool: "list_apps") { p in
            var a: [String: Any] = ["sort": p.flags["sort"] ?? "size"]
            if let q = p.positional.first { a["query"] = q }
            if let l = p.int("limit") { a["limit"] = l }
            return a },
        Command(name: "app", usage: "app NAME", help: "An app's data, helpers, drivers and caches.", tool: "app_details") { p in
            ["app": try one(p, "app name")] },
        Command(name: "app-cache", usage: "app-cache NAME", help: "Clear one app's cache. Previews first.", tool: "clear_app_cache", destructive: true) { p in
            ["app": try one(p, "app name")] },
        Command(name: "uninstall", usage: "uninstall NAME [--shared]", help: "Uninstall an app with its leftovers (to Trash). Previews first.",
                tool: "uninstall_app", destructive: true) { p in
            ["app": try one(p, "app name"), "include_shared": p.flag("shared")] },
        Command(name: "projects", usage: "projects [PATH…] [--idle MONTHS]", help: "Build files in code projects (node_modules, build…).", tool: "scan_projects") { p in
            projectArgs(p) },
        Command(name: "clean-projects", usage: "clean-projects (--all | ID…) [--idle MONTHS]",
                help: "Delete project build files. --all takes every project shown by `projects` with the same --idle.",
                tool: "clean_projects", destructive: true, prepare: "scan_projects") { p in
            if p.flag("all") { return ["__all_projects": true] }
            guard !p.positional.isEmpty else { throw UsageError(description: "Pass --all or project/artifact ids from `mac-cleaner projects`.") }
            return ["project_ids": p.positional, "artifact_ids": p.positional] },
        Command(name: "sdks", usage: "sdks [--group Xcode|Android|Languages|Homebrew|Docker]", help: "Simulators, Android SDK, language versions, Homebrew, Docker.", tool: "list_sdks") { p in
            p.flags["group"].map { ["group": $0] } ?? [:] },
        Command(name: "remove-sdks", usage: "remove-sdks ID…", help: "Remove SDK items by id. Previews first.", tool: "remove_sdks", destructive: true) { p in
            ["ids": try many(p, "ids from `mac-cleaner sdks`")] },
        Command(name: "system-data", usage: "system-data", help: "Snapshots, device backups, Mail and Messages attachments.", tool: "system_data") { _ in [:] },
        Command(name: "remove-system-data", usage: "remove-system-data ID…", help: "Remove System Data items by id. Previews first.",
                tool: "remove_system_data", destructive: true) { p in
            ["ids": try many(p, "ids from `mac-cleaner system-data`")] },
        Command(name: "trash", usage: "trash", help: "Trash size and items Mac Cleaner put there.", tool: "trash_status") { _ in [:] },
        Command(name: "empty-trash", usage: "empty-trash", help: "Empty the Trash (permanent). Previews first.", tool: "empty_trash", destructive: true) { _ in [:] },
        Command(name: "put-back", usage: "put-back (--all | ID…)", help: "Restore items Mac Cleaner trashed.", tool: "restore_from_trash", destructive: true) { p in
            p.flag("all") ? ["all": true] : ["ids": try many(p, "ids from `mac-cleaner trash`")] },
        Command(name: "protected", usage: "protected", help: "Folders and files nothing may touch.", tool: "list_protected") { _ in [:] },
        Command(name: "protect", usage: "protect PATH…", help: "Protect folders or files.", tool: "protect_paths") { p in
            ["paths": try many(p, "paths")] },
        Command(name: "trash-files", usage: "trash-files PATH…", help: "Move files to the Trash. Previews first.", tool: "move_to_trash", destructive: true) { p in
            ["paths": try many(p, "paths")] },
    ]

    private static func one(_ p: Parsed, _ what: String) throws -> String {
        guard !p.positional.isEmpty else { throw UsageError(description: "Pass the \(what).") }
        return p.positional.joined(separator: " ")
    }
    private static func many(_ p: Parsed, _ what: String) throws -> [String] {
        guard !p.positional.isEmpty else { throw UsageError(description: "Pass \(what).") }
        return p.positional
    }
    private static func projectArgs(_ p: Parsed) -> [String: Any] {
        var a: [String: Any] = ["limit": p.int("limit") ?? 50]
        if !p.positional.isEmpty { a["roots"] = p.positional }
        if let i = p.int("idle") { a["min_idle_months"] = i }
        return a
    }

    // MARK: Run

    static func run(_ argv: [String]) -> Int32 {
        var args = argv
        let json = args.contains("--json"); args.removeAll { $0 == "--json" }
        let yes = args.contains("--yes") || args.contains("-y"); args.removeAll { $0 == "--yes" || $0 == "-y" }
        guard let name = args.first, !["help", "-h", "--help"].contains(name) else { printHelp(); return 0 }

        switch name {
        case "mcp": MCPServer.run(); return 0
        case "bench": return MainActor.assumeIsolated { Bench.run(Array(args.dropFirst())) }
        case "install":
            switch CLIInstaller.install() {
            case .success(let u):
                print("Installed \(u.path)")
                if u.path.contains("/.local/bin") { print(dim("If `mac-cleaner` isn't found, add ~/.local/bin to your PATH.")) }
                return 0
            case .failure(let e): err(e.localizedDescription); return 1
            }
        case "uninstall-command":
            if let u = CLIInstaller.installedAt { CLIInstaller.uninstall(); print("Removed \(u.path)") } else { print("Not installed.") }
            return 0
        case "tools":
            for t in MCPServer.tools { print("\(bold(t["name"] as? String ?? ""))  \(dim(t["description"] as? String ?? ""))") }
            return 0
        case "tool":
            guard args.count >= 2 else { err("Usage: mac-cleaner tool NAME ['{\"json\":\"args\"}']"); return 64 }
            let raw = args.count > 2 ? args[2] : "{}"
            guard var a = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { err("Arguments must be a JSON object."); return 64 }
            if (a["confirm"] as? Bool) == true {
                guard yes else { err("For safety, `tool` with confirm: true also needs --yes."); return 64 }
                // --yes is the person at the keyboard approving: preview the same arguments, then confirm that preview.
                if a["preview_id"] == nil {
                    var p = a; p["confirm"] = false
                    do { a["preview_id"] = (try MCPServer.call(args[1], p) as? [String: Any])?["preview_id"] }
                    catch { err("\(error)"); return 1 }
                }
            }
            return call(args[1], a, json: json)
        default: break
        }

        guard let cmd = commands.first(where: { $0.name == name }) else {
            err("Unknown command “\(name)”. Run `mac-cleaner help`."); return 64
        }
        let parsed = parse(Array(args.dropFirst()))
        do {
            var a = try cmd.args(parsed)
            if let prep = cmd.prepare {
                if !json { FileHandle.standardError.write(Data(dim("Scanning first…\n").utf8)) }
                var prepArgs: [String: Any] = [:]
                if prep == "scan_projects" { prepArgs = projectArgs(parsed); prepArgs["limit"] = 100_000 }
                let scan = try MCPServer.call(prep, prepArgs)
                if a.removeValue(forKey: "__all_projects") != nil {
                    let ids = ((scan as? [String: Any])?["projects"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                    guard !ids.isEmpty else { print("No projects match."); return 0 }
                    a["project_ids"] = ids
                }
            }
            guard cmd.destructive else { return output(try MCPServer.call(cmd.tool, a), json: json) }

            // Destructive: preview → explicit yes → confirm.
            let preview = try MCPServer.call(cmd.tool, a)
            _ = output(preview, json: json, hideNext: true)
            guard (preview as? [String: Any])?["preview"] as? Bool == true else { return 0 }
            if yes {
                if !json { print("\n\(bold("Going ahead")) (--yes)…") }
            } else {
                guard isatty(0) != 0 else { err("\nNothing was changed. Re-run with --yes to go ahead."); return 2 }
                print("\n\(bold("Go ahead?")) Type yes to continue: ", terminator: "")
                guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else { print("Cancelled. Nothing was changed."); return 1 }
            }
            a["confirm"] = true
            a["preview_id"] = (preview as? [String: Any])?["preview_id"]
            return output(try MCPServer.call(cmd.tool, a), json: json)
        } catch {
            err("\(error)"); return 1
        }
    }

    private static func call(_ tool: String, _ a: [String: Any], json: Bool) -> Int32 {
        do { return output(try MCPServer.call(tool, a), json: json) } catch { err("\(error)"); return 1 }
    }

    static func parse(_ args: [String]) -> Parsed {
        var p = Parsed()
        var i = 0
        while i < args.count {
            let s = args[i]
            if s.hasPrefix("--") {
                let k = String(s.dropFirst(2))
                if let eq = k.firstIndex(of: "=") { p.flags[String(k[..<eq])] = String(k[k.index(after: eq)...]) }
                else if valueFlags.contains(k), i + 1 < args.count { p.flags[k] = args[i + 1]; i += 1 }
                else { p.flags[k] = "true" }
            } else {
                p.positional.append(s)
            }
            i += 1
        }
        return p
    }

    // MARK: Output

    @discardableResult
    private static func output(_ v: Any, json: Bool, hideNext: Bool = false) -> Int32 {
        if json {
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            print(String(decoding: d, as: UTF8.self))
        } else {
            render(v, indent: 0, hideNext: hideNext)
        }
        return 0
    }

    private static let leadKeys = ["name", "app", "project", "section", "group", "kind", "path", "size", "total", "freed"]

    private static func render(_ v: Any, indent: Int, hideNext: Bool = false) {
        let pad = String(repeating: "  ", count: indent)
        if let d = v as? [String: Any] {
            let scalars = d.filter { !($0.value is [Any]) && !($0.value is [String: Any]) && !($0.value is NSNull) }
            for k in scalars.keys.sorted() where k != "next" && k != "preview" {
                print("\(pad)\(dim(k.replacingOccurrences(of: "_", with: " "))): \(text(scalars[k]!))")
            }
            for k in d.keys.sorted() {
                if let list = d[k] as? [Any] {
                    print("\(pad)\(bold(k.replacingOccurrences(of: "_", with: " "))) (\(list.count))")
                    for item in list { renderItem(item, indent: indent + 1) }
                } else if let sub = d[k] as? [String: Any] {
                    print("\(pad)\(bold(k))"); render(sub, indent: indent + 1)
                }
            }
            if d["preview"] as? Bool == true { print("\n\(pad)\(bold("Preview only: nothing has been changed yet."))") }
            if !hideNext, let n = d["next"] as? String, d["preview"] as? Bool != true { print("\(pad)\(dim(n))") }
        } else if let list = v as? [Any] {
            for item in list { renderItem(item, indent: indent) }
        } else {
            print(pad + text(v))
        }
    }

    private static func renderItem(_ item: Any, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        guard let d = item as? [String: Any] else { print("\(pad)• \(text(item))"); return }
        var parts = leadKeys.compactMap { k in d[k].flatMap { $0 is NSNull ? nil : text($0) } }
        var tags: [String] = []
        for (k, v) in d.sorted(by: { $0.key < $1.key }) where !leadKeys.contains(k) && k != "id" {
            if let b = v as? Bool { if b && ["review", "protected", "needs_admin", "needs_password", "running", "shared"].contains(k) {
                                         tags.append(k.replacingOccurrences(of: "_", with: " ").uppercased()) }
                                     if !b && ["allowed", "removable"].contains(k) { tags.append("NOT ALLOWED") } }
            else if v is NSNull || v is [Any] || v is [String: Any] { continue }
            else if ["in_use", "reason", "note", "last_edited", "idle_months", "stack", "detail", "how", "comes_back_with"].contains(k) {
                parts.append("\(k.replacingOccurrences(of: "_", with: " ")): \(text(v))")
            }
        }
        if parts.isEmpty { parts = d.filter { !($0.value is [Any]) && $0.key != "id" }.map { "\($0.key): \(text($0.value))" } }
        var line = "\(pad)• " + parts.joined(separator: "  ·  ")
        if !tags.isEmpty { line += "  " + yellow(tags.joined(separator: " ")) }
        if let id = d["id"] { line += "  " + dim("id: \(text(id))") }
        print(line)
        for (k, v) in d.sorted(by: { $0.key < $1.key }) {
            if let sub = v as? [Any], !sub.isEmpty {
                print("\(pad)    \(dim(k))")
                for s in sub { renderItem(s, indent: indent + 2) }
            }
        }
    }

    private static func text(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "yes" : "no" }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [Any] { return a.map(text).joined(separator: ", ") }
        return "\(v)"
    }

    private static let tty = isatty(1) != 0
    private static func bold(_ s: String) -> String { tty ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    private static func dim(_ s: String) -> String { tty ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
    private static func yellow(_ s: String) -> String { tty ? "\u{1B}[33m\(s)\u{1B}[0m" : s }
    private static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func printHelp() {
        print("""
        \(bold("mac-cleaner")) — free disk space from the terminal. Same engine and safety rules as the Mac Cleaner app.

        \(bold("Usage:")) mac-cleaner COMMAND [ARGS] [--json] [--yes]

        """)
        for c in commands { print("  " + c.usage.padding(toLength: 50, withPad: " ", startingAt: 0) + dim(c.help)) }
        print("""

          \("tools".padding(toLength: 50, withPad: " ", startingAt: 0))\(dim("List the MCP tools."))
          \("tool NAME '{JSON}'".padding(toLength: 50, withPad: " ", startingAt: 0))\(dim("Call any MCP tool directly."))
          \("mcp".padding(toLength: 50, withPad: " ", startingAt: 0))\(dim("Run the MCP server on stdio (for AI apps)."))
          \("install / uninstall-command".padding(toLength: 50, withPad: " ", startingAt: 0))\(dim("Add or remove the mac-cleaner command on your PATH."))

        \(bold("Safety:")) commands that delete or move show a preview and ask you to type yes.
        --yes skips the question (for scripts). Protected folders are always refused.

        \(bold("Examples:"))
          mac-cleaner status
          mac-cleaner scan
          mac-cleaner clean --recommended
          mac-cleaner projects --idle 6
          mac-cleaner usage ~/Library --limit 15
          mac-cleaner uninstall "Some App"
        """)
    }
}

/// Puts a small `mac-cleaner` script on the PATH that runs this app with --cli.
enum CLIInstaller {
    static let marker = "# mac-cleaner launcher (installed by Mac Cleaner)"

    static var candidates: [URL] {
        ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
            + [SafetyGuard.home.appendingPathComponent(".local/bin")]
    }

    /// Where it is installed now, if anywhere.
    static var installedAt: URL? {
        candidates.map { $0.appendingPathComponent("mac-cleaner") }.first { isOurs($0) }
    }

    static func isOurs(_ u: URL) -> Bool {
        (try? String(contentsOf: u, encoding: .utf8))?.contains(marker) == true
    }

    static func install() -> Result<URL, Error> {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? "/Applications/Mac Cleaner.app/Contents/MacOS/Mac Cleaner"
        let fm = FileManager.default
        let dir = candidates.first { fm.isWritableFile(atPath: $0.path) } ?? candidates.last!
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("mac-cleaner")
            if fm.fileExists(atPath: target.path) && !isOurs(target) {
                throw NSError(domain: "MacCleaner", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(target.path) already exists and wasn't made by Mac Cleaner. Left it alone."])
            }
            let script = "#!/bin/sh\n\(marker)\nexec '\(exe.replacingOccurrences(of: "'", with: "'\\''"))' --cli \"$@\"\n"
            try script.write(to: target, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return .success(target)
        } catch { return .failure(error) }
    }

    static func uninstall() {
        if let u = installedAt { try? FileManager.default.removeItem(at: u) }
    }
}
