import SwiftUI

/// One binary, two modes: the window app, or an MCP server for AI assistants ("Mac Cleaner" --mcp).
@main
enum Entry {
    static func main() {
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
                .frame(minWidth: 1240, minHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1460, height: 940)

        MenuBarExtra {
            MenuBarContent().environment(model).environment(automation)
        } label: {
            Image(nsImage: automation.menuBarImage)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(CleanerModel.self) private var model
    @Environment(AutomationModel.self) private var auto
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Free: \(ByteText.string(Scanner.freeBytes()))")
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
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
