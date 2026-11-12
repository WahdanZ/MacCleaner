import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

// Phase 5: low-disk alert (menu bar colour + notification) and an optional weekly safe clean.

enum AutoKeys {
    static let alerts = "auto.alerts"            // Bool, default true
    static let thresholdGB = "auto.thresholdGB"  // Int, default 20
    static let weekly = "auto.weeklyClean"       // Bool, default false
    static let lastRun = "auto.lastRun"          // Date
    static let lastBytes = "auto.lastBytes"      // Int64
    static let lastNotified = "auto.lastNotified"
}

/// Picks what the automatic clean may delete: recommended caches only. Never the Trash, Downloads,
/// anything protected, or anything outside the allowed cache folders.
enum AutoClean {
    static func select(_ targets: [CleanTarget]) -> [CleanTarget] {
        let downloads = SafetyGuard.home.appendingPathComponent("Downloads").path
        return targets.filter { t in
            guard t.recommended, t.isCleanable, t.category != .trash else { return false }
            return urls(t).allSatisfy { u in
                !SafetyGuard.isInside(u.path, downloads) && !ProtectedPaths.isBlocked(u)
                    && SafetyGuard.isAllowed(u, allowContainer: { if case .removeContents = t.action { return true }; return false }())
            }
        }
    }

    static func urls(_ t: CleanTarget) -> [URL] {
        switch t.action {
        case .removeItem(let u), .removeContents(let u), .webCachesIn(let u): return [u]
        case .removeItems(let us): return us
        case .deleteUnavailableSimulators, .deleteSimRuntime: return []
        }
    }

    /// Full scan + clean, off the main thread. Returns bytes freed and the errors.
    static func run() -> (bytes: Int64, count: Int, errors: [String]) {
        let plan = Scanner.plan()
        let box = Box([CleanTarget?](repeating: nil, count: plan.count))
        DispatchQueue.concurrentPerform(iterations: plan.count) { i in
            let t = Scanner.measure(plan[i])
            box.mutate { $0[i] = t }
        }
        let chosen = select(Scanner.finalize(box.value.compactMap { $0 }))
        var bytes: Int64 = 0, errors: [String] = []
        for t in chosen {
            let e = Cleaner.run([t])
            if e.isEmpty { bytes += t.sizeBytes } else { errors += e }
        }
        return (bytes, chosen.count, errors)
    }
}

@MainActor @Observable
final class AutomationModel {
    enum Level: Int { case ok, low, critical }

    var level: Level = .ok
    var freeBytes: Int64 = Scanner.freeBytes()
    var running = false
    var lastRun: Date? = UserDefaults.standard.object(forKey: AutoKeys.lastRun) as? Date
    var lastBytes: Int64 = Int64(UserDefaults.standard.integer(forKey: AutoKeys.lastBytes))
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    private var timer: Timer?
    private static var started = false

    static var thresholdBytes: Int64 {
        let gb = UserDefaults.standard.object(forKey: AutoKeys.thresholdGB) as? Int ?? 20
        return Int64(gb) * 1_000_000_000
    }
    static var alertsOn: Bool { UserDefaults.standard.object(forKey: AutoKeys.alerts) as? Bool ?? true }
    static var weeklyOn: Bool { UserDefaults.standard.bool(forKey: AutoKeys.weekly) }

    init() {
        guard !Self.started else { return }
        Self.started = true
        // First check shortly after launch, then every 30 minutes.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if Self.alertsOn || Self.weeklyOn { Notifier.requestPermission() }
            self?.tick()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        check()
        if Self.weeklyOn, !running, (lastRun.map { Date().timeIntervalSince($0) > 7 * 86_400 } ?? true) {
            Task { await runClean(automatic: true) }
        }
    }

    /// Updates the level; posts one notification when it gets worse (and again at most every 12 h).
    func check() {
        freeBytes = Scanner.freeBytes()
        FreeSpaceLog.shared.record(free: freeBytes, total: Scanner.totalBytes())
        let limit = Self.thresholdBytes
        let new: Level = freeBytes < limit / 2 ? .critical : freeBytes < limit ? .low : .ok
        let worse = new.rawValue > level.rawValue
        level = new
        guard Self.alertsOn, new != .ok else { return }
        let last = UserDefaults.standard.object(forKey: AutoKeys.lastNotified) as? Date ?? .distantPast
        if worse || Date().timeIntervalSince(last) > 12 * 3600 {
            UserDefaults.standard.set(Date(), forKey: AutoKeys.lastNotified)
            Notifier.post(title: new == .critical ? "Your disk is almost full" : "Disk space is getting low",
                          body: "\(ByteText.string(freeBytes)) free. Open Mac Cleaner to free some space.")
        }
    }

    func runClean(automatic: Bool) async {
        guard !running else { return }
        running = true
        let before = Scanner.freeBytes()
        let r = await Task.detached(priority: automatic ? .utility : .userInitiated) { AutoClean.run() }.value
        let measured = max(0, Scanner.freeBytes() - before)
        running = false
        lastRun = Date()
        lastBytes = r.bytes
        UserDefaults.standard.set(lastRun, forKey: AutoKeys.lastRun)
        UserDefaults.standard.set(Int(r.bytes), forKey: AutoKeys.lastBytes)
        HistoryStore.shared.add(automatic ? "Weekly Safe Clean" : "Safe Clean", bytes: r.bytes, symbol: "calendar.badge.clock",
                                outcome: .deleted, measuredFreeChange: measured)
        if automatic && r.bytes > 0 {
            Notifier.post(title: "Weekly clean: \(ByteText.string(r.bytes)) of caches deleted",
                          body: "\(r.count) cache location(s) cleaned. Nothing in your folders was touched.")
        }
        check()
    }

    func setLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Mac Cleaner login item: \(error.localizedDescription)") }
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    /// Menu bar icon: the app symbol normally, a coloured warning when space is low.
    var menuBarImage: NSImage {
        let (name, color): (String, NSColor?) = switch level {
        case .ok: ("square.grid.2x2.fill", nil)
        case .low: ("externaldrive.fill.badge.exclamationmark", .systemOrange)
        case .critical: ("externaldrive.fill.badge.xmark", .systemRed)
        }
        var cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Mac Cleaner")?.withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = color == nil
        return img
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Settings › Automation.
struct AutomationSettings: View {
    @Environment(AutomationModel.self) private var auto
    @AppStorage(AutoKeys.alerts) private var alerts = true
    @AppStorage(AutoKeys.thresholdGB) private var threshold = 20
    @AppStorage(AutoKeys.weekly) private var weekly = false
    @State private var confirmRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Low disk alerts", isOn: $alerts)
                Spacer()
                Text("Warn below").foregroundStyle(alerts ? Palette.fg : Palette.faint)
                Stepper(value: $threshold, in: 5...200, step: 5) {
                    Text("\(threshold) GB").monospacedDigit().font(.system(size: 13, weight: .semibold))
                        .contentTransition(.numericText(value: Double(threshold)))
                        .animation(.snappy, value: threshold)
                }
                .fixedSize()
                .disabled(!alerts)
            }
            .onChange(of: alerts) { _, on in if on { Notifier.requestPermission() }; auto.check() }
            .onChange(of: threshold) { auto.check() }
            HStack(spacing: 6) {
                Circle().fill(levelColor).frame(width: 8, height: 8)
                Text("Now: \(ByteText.string(auto.freeBytes)) free · checked every 30 minutes · the menu bar icon turns orange, then red")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint)
            }
            Divider().opacity(0.5)
            Toggle("Weekly safe clean", isOn: $weekly)
                .onChange(of: weekly) { _, on in if on { Notifier.requestPermission() } }
            Text("Recommended caches only (the same ones pre-selected in Junk Files). Never the Trash, Downloads, your folders or anything protected. A notification shows what was freed.")
                .font(.system(size: 11)).foregroundStyle(Palette.faint).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(lastText).font(.system(size: 12)).foregroundStyle(Palette.dim)
                Spacer()
                if auto.running { ProgressView().controlSize(.small) }
                Button("Run safe clean now") { confirmRun = true }.buttonStyle(.bordered).disabled(auto.running)
            }
        }
        .font(.system(size: 13))
        .alert("Run a safe clean now?", isPresented: $confirmRun) {
            Button("Clean") { Task { await auto.runClean(automatic: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the recommended caches (they rebuild): developer caches, app caches, logs and browser caches. The Trash, Downloads, your folders and protected items are not touched. For an item-by-item list, use Junk Files instead.")
        }
    }

    private var levelColor: Color {
        switch auto.level { case .ok: Palette.success; case .low: Palette.warn; case .critical: Palette.danger }
    }

    private var lastText: String {
        guard let d = auto.lastRun else { return "Never run yet." }
        return "Last run \(d.formatted(.relative(presentation: .named))) · freed \(ByteText.string(auto.lastBytes))"
    }
}
