import SwiftUI

/// One binary, two modes: the window app, or an MCP server for AI assistants ("Mac Cleaner" --mcp).
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        #if MACCLEANER_TEST_HOOKS
        // Only in the test-hooks build (scripts/build-test-hooks.sh), never in Release. First, before any dispatch or
        // anything that can move a file: a process the self-test starts gets the self-test's isolated Trash folder.
        if let dir = ProcessInfo.processInfo.environment["MACCLEANER_TEST_TRASH_DIR"] {
            SelfTest.isolateTrash(in: URL(fileURLWithPath: dir))
        }
        // The self-test asks a process where its Trash moves would go before it lets one move anything.
        if ProcessInfo.processInfo.environment["MACCLEANER_TEST_TRASH_PROBE"] == "1" {
            print("trash-destination: " + (SelfTest.trashIsIsolated ? SelfTest.isolatedTrash.path : "system"))
            exit(0)
        }
        if args.count > 1 && args[1] == "--selftest-child" {
            exit(SelfTest.child(Array(args.dropFirst(2))))
        }
        #endif
        SettingsMigration.migrate()
        if args.count > 1 && args[1] == "--cli" {
            exit(CLI.run(Array(args.dropFirst(2))))
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.installTestApprover()   // never show a real confirmation window during the self-test
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
            MenuBarPopover().environment(model).environment(automation)
        } label: {
            MenuBarLabel().environment(automation)
        }
        .menuBarExtraStyle(.window)
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

/// Version 1.0.0 used the app ID "local.maccleaner". Settings live per app ID, so on the first launch
/// under the new ID this copies them over once. Protected paths are merged, never dropped.
enum SettingsMigration {
    static let oldDomain = "local.maccleaner"
    static let doneKey = "settingsMigratedFromLocalDomain"

    /// Returns how many settings were copied.
    @discardableResult
    static func migrate(fromDomain: String = oldDomain, to new: SettingsStore = UserDefaults.standard) -> Int {
        migrate(old: { UserDefaults.standard.persistentDomain(forName: fromDomain) }, to: new)
    }

    /// `old` is read only if the migration hasn't run yet.
    @discardableResult
    static func migrate(old readOld: () -> [String: Any]?, to new: SettingsStore) -> Int {
        guard !new.bool(forKey: doneKey) else { return 0 }
        new.set(true, forKey: doneKey)
        guard let old = readOld(), !old.isEmpty else { return 0 }
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
