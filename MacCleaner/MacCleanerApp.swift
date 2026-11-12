import SwiftUI

/// One binary, two modes: the window app, or an MCP server for AI assistants ("Mac Cleaner" --mcp).
@main
enum Entry {
    static func main() {
        SettingsMigration.migrate()
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "--cli" {
            exit(CLI.run(Array(args.dropFirst(2))))
        }
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
            exit(0)
        }
        MacCleanerApp.main()
    }
}

struct MacCleanerApp: App {
    @State private var model = CleanerModel()
    @State private var diskMap = DiskMapModel()
    @State private var dups = DupFinder()
    @State private var appsModel = AppsModel()
    @State private var integrations = IntegrationsModel()
    @State private var overview = OverviewModel()
    @State private var largeFiles = LargeFilesModel()
    @State private var extensions = ExtensionsModel()
    @State private var startup = StartupModel()
    @State private var shredder = ShredderModel()
    @State private var trash = TrashModel()
    @State private var projects = ProjectsModel()
    @State private var sdks = SDKModel()
    @State private var systemData = SystemDataModel()
    @State private var automation = AutomationModel()
    @State private var review = ReviewCenter()
    var body: some Scene {
        Window("Mac Cleaner", id: "main") {
            ContentView()
                .environment(model)
                .environment(diskMap)
                .environment(dups)
                .environment(appsModel)
                .environment(integrations)
                .environment(overview)
                .environment(largeFiles)
                .environment(extensions)
                .environment(startup)
                .environment(shredder)
                .environment(trash)
                .environment(projects)
                .environment(sdks)
                .environment(systemData)
                .environment(automation)
                .environment(review)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 840)
        .commands {
            SidebarCommands()
            NavigationCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .help) {
                Button("Welcome Tour") { UserDefaults.standard.set(false, forKey: "introSeen") }
                Link("Mac Cleaner on GitHub", destination: URL(string: "https://github.com/WahdanZ/MacCleaner")!)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(automation)
                .environment(integrations)
        }

        MenuBarExtra {
            MenuBarContent().environment(model).environment(automation)
        } label: {
            Image(nsImage: automation.menuBarImage)
        }
    }
}

/// Go menu: ⌘1…⌘0 jump to each sidebar destination.
struct NavigationCommands: Commands {
    @AppStorage("sidebarPage") private var page: SidebarPage = .overview

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(SidebarPage.allCases.enumerated()), id: \.1) { i, p in
                Button(p.title) { page = p }
                    .keyboardShortcut(KeyEquivalent(Character(String((i + 1) % 10))), modifiers: .command)
            }
        }
    }
}

private struct MenuBarContent: View {
    @Environment(CleanerModel.self) private var model
    @Environment(AutomationModel.self) private var auto
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Free: \(ByteText.string(Scanner.freeBytes()))")
        Label(forecast, systemImage: "chart.line.downtrend.xyaxis")
        if auto.level != .ok {
            Text(auto.level == .critical ? "⚠︎ Disk almost full" : "⚠︎ Disk space low")
        }
        if model.hasScanned {
            Text("Can free: \(ByteText.string(model.reclaimableBytes))")
        }
        Divider()
        Button("Open Mac Cleaner") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Rescan") { Task { await model.scan() } }
        Divider()
        if Updater.shared.updateAvailable, let r = Updater.shared.release {
            Button("Update to \(r.version)…") { Updater.shared.show() }
        } else {
            Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    /// Same straight-line forecast as the Insights card, in one short line.
    private var forecast: String {
        let samples = FreeSpaceLog.shared.samples
        let limit = AutomationModel.thresholdBytes
        return InsightMath.shortForecast(days: FreeSpaceLog.daysUntil(limit, samples: samples),
                                         limit: limit, sampleCount: samples.count)
    }
}

/// Version 1.0.0 used the app ID "local.maccleaner". Settings live per app ID, so on the first launch
/// under the new ID this copies them over once. Protected paths are merged, never dropped.
enum SettingsMigration {
    static let oldDomain = "local.maccleaner"
    static let doneKey = "settingsMigratedFromLocalDomain"

    /// Returns how many settings were copied.
    @discardableResult
    static func migrate(fromDomain: String = oldDomain, to new: UserDefaults = .standard) -> Int {
        guard !new.bool(forKey: doneKey) else { return 0 }
        new.set(true, forKey: doneKey)
        guard let old = UserDefaults.standard.persistentDomain(forName: fromDomain), !old.isEmpty else { return 0 }
        var copied = 0
        for (k, v) in old where !k.hasPrefix("NS") && k != ProtectedPaths.key && new.object(forKey: k) == nil {
            new.set(v, forKey: k)
            copied += 1
        }
        if let oldPaths = old[ProtectedPaths.key] as? [String], !oldPaths.isEmpty {
            let current = new.stringArray(forKey: ProtectedPaths.key) ?? []
            new.set(Array(Set(current + oldPaths)).sorted(), forKey: ProtectedPaths.key)
            copied += 1
        }
        return copied
    }
}
