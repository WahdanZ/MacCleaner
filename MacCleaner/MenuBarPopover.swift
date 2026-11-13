import AppKit
import SwiftUI

/// The menu bar item's label: the status icon, plus optional text chosen in Settings › General.
struct MenuBarLabel: View {
    @Environment(AutomationModel.self) private var auto
    @AppStorage(AutoKeys.menuBarText) private var textChoice = MenuBarText.none

    var body: some View {
        Image(nsImage: auto.menuBarImage)
        if let text = auto.menuBarText(textChoice) {
            Text(text).monospacedDigit()
        }
    }
}

/// The panel that opens from the menu bar: disk status, Clean Now, last and next clean, recent history.
struct MenuBarPopover: View {
    @Environment(CleanerModel.self) private var model
    @Environment(AutomationModel.self) private var auto
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirming = false
    @State private var history = HistoryStore.shared
    @State private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            disk
            if auto.level != .ok { lowSpaceBanner }
            cleanBox
            facts
            if !history.records.isEmpty { recent }
            if updater.updateAvailable, let r = updater.release { updateRow(r.version) }
            Divider()
            footer
        }
        .padding(Space.l)
        .frame(width: 320)
        .animation(Motion.standard(reduceMotion), value: confirming)
        .animation(Motion.standard(reduceMotion), value: auto.running)
        .onAppear {
            confirming = false
            auto.check()
            auto.refreshNextRun()
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("Mac Cleaner").font(.headline)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
            .simultaneousGesture(TapGesture().onEnded { Self.closePanel(); NSApp.activate(ignoringOtherApps: true) })
        }
    }

    private var disk: some View {
        let total = max(Scanner.totalBytes(), 1)
        let used = max(0, total - auto.freeBytes)
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(ByteText.string(auto.freeBytes)) free")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: Double(auto.freeBytes)))
                Spacer()
                Text("of \(ByteText.string(total))").font(.caption).foregroundStyle(Palette.dim).monospacedDigit()
            }
            ProgressView(value: Double(used), total: Double(total))
                .progressViewStyle(.linear)
                .tint(levelColor)
            Label(forecast, systemImage: "chart.line.downtrend.xyaxis")
                .font(.caption).foregroundStyle(Palette.dim)
        }
        .accessibilityElement(children: .combine)
    }

    private var lowSpaceBanner: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(levelColor)
            Text(auto.level == .critical ? "Your disk is almost full." : "Disk space is getting low.")
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(Space.s)
        .background(levelColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.small))
    }

    @ViewBuilder private var cleanBox: some View {
        if auto.running {
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text(auto.status ?? "Cleaning…")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity)
            .background(Palette.tile, in: RoundedRectangle(cornerRadius: Radius.medium))
        } else if confirming {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Run a safe clean?").font(.callout.weight(.semibold))
                Text(SafeCleanText.confirm)
                    .font(.caption).foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { confirming = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Clean") {
                        confirming = false
                        Task { await auto.runClean(automatic: false) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Space.m)
            .background(Palette.tile, in: RoundedRectangle(cornerRadius: Radius.medium))
        } else {
            VStack(spacing: Space.xs) {
                Button { confirming = true } label: {
                    Label("Clean Now", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Delete the recommended caches. Asks first.")
                if model.hasScanned, model.reclaimableBytes > 0 {
                    HStack(spacing: Space.xs) {
                        Text("Junk Files found \(ByteText.string(model.reclaimableBytes)).")
                            .font(.caption).foregroundStyle(Palette.dim)
                        Button("Review…") { open(page: .junk) }
                            .buttonStyle(.link).font(.caption)
                        Spacer()
                    }
                }
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
            GridRow {
                Text("Last clean").foregroundStyle(Palette.dim)
                Text(lastCleanText).monospacedDigit()
            }
            GridRow {
                Text("Next clean").foregroundStyle(Palette.dim)
                if let next = auto.nextRun {
                    Text(next.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()))
                } else {
                    HStack(spacing: Space.xs) {
                        Text("Off")
                        SettingsLink { Text("Schedule…") }
                            .buttonStyle(.link)
                            .simultaneousGesture(TapGesture().onEnded { Self.closePanel(); NSApp.activate(ignoringOtherApps: true) })
                    }
                }
            }
            GridRow {
                Text("Deleted so far").foregroundStyle(Palette.dim)
                Text(ByteText.string(history.totalDeleted)).monospacedDigit()
            }
        }
        .font(.caption)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(Palette.dim)
            ForEach(history.records.prefix(3)) { r in
                HStack(spacing: Space.s) {
                    Image(systemName: r.symbol).frame(width: 16).foregroundStyle(Palette.dim)
                    Text(r.title).lineLimit(1)
                    Spacer()
                    Text(ByteText.string(r.bytes)).monospacedDigit()
                    Text(r.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                        .foregroundStyle(Palette.faint)
                }
                .font(.caption)
            }
        }
    }

    private func updateRow(_ version: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.accent)
            Text("Version \(version) is available.").font(.caption)
            Spacer()
            Button("Update…") { Self.closePanel(); updater.show() }
                .buttonStyle(.link).font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Mac Cleaner") { open(page: nil) }
            Spacer()
            Menu {
                Button("Scan Junk Files") { Task { await model.scan() } }
                    .disabled(model.phase == .scanning)
                Toggle("Open at Login", isOn: Binding(get: { auto.loginEnabled }, set: { auto.setLogin($0) }))
                Button("Check for Updates…") {
                    Self.closePanel()
                    Task { await updater.check(userInitiated: true) }
                }
                Divider()
                Button("Quit Mac Cleaner") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .controlSize(.small)
    }

    // MARK: Helpers

    private func open(page: SidebarPage?) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: "sidebarPage") }
        Self.closePanel()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// SwiftUI has no dismiss for a menu bar window, so close it directly.
    static func closePanel() {
        for w in NSApp.windows where w.className.contains("MenuBarExtra") && w.isVisible { w.close() }
    }

    private var levelColor: Color {
        switch auto.level { case .ok: Palette.accent; case .low: Palette.warn; case .critical: Palette.danger }
    }

    private var lastCleanText: String {
        guard let d = auto.lastRun else { return "Never" }
        return "\(d.formatted(.relative(presentation: .named))) · \(ByteText.string(auto.lastBytes))"
    }

    /// Same straight-line forecast as the Insights card, in one short line.
    private var forecast: String {
        let samples = FreeSpaceLog.shared.samples
        let limit = AutomationModel.thresholdBytes
        return InsightMath.shortForecast(days: FreeSpaceLog.daysUntil(limit, samples: samples),
                                         limit: limit, sampleCount: samples.count)
    }
}
