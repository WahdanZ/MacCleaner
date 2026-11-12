import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

// Phase 5: low-disk alert (menu bar colour + notification) and an optional scheduled safe clean.

enum AutoKeys {
    static let alerts = "auto.alerts"            // Bool, default true
    static let thresholdGB = "auto.thresholdGB"  // Int, default 20
    static let weekly = "auto.weeklyClean"       // Bool, default false: the scheduled clean is on (daily or weekly)
    static let frequency = "auto.frequency"      // String AutoSchedule.Frequency, default weekly
    static let weekday = "auto.weekday"          // Int 1...7 (1 = Sunday), default 2 (Monday)
    static let hour = "auto.hour"                // Int, default 10
    static let minute = "auto.minute"            // Int, default 0
    static let armedAt = "auto.armedAt"          // Date the schedule was last turned on or changed
    static let lastRun = "auto.lastRun"          // Date
    static let lastBytes = "auto.lastBytes"      // Int64
    static let lastNotified = "auto.lastNotified"
    static let menuBarText = "menubar.text"      // String MenuBarText, default none
}

/// When the scheduled safe clean runs. Pure, so the self-test can check it.
struct AutoSchedule: Equatable {
    enum Frequency: String, CaseIterable, Identifiable {
        case daily, weekly
        var id: String { rawValue }
        var title: String { self == .daily ? "Every day" : "Every week" }
    }

    var frequency: Frequency = .weekly
    /// Calendar weekday, 1 = Sunday … 7 = Saturday. Only used when weekly.
    var weekday = 2
    var hour = 10
    var minute = 0

    static var current: AutoSchedule {
        let d = UserDefaults.standard
        return AutoSchedule(frequency: Frequency(rawValue: d.string(forKey: AutoKeys.frequency) ?? "") ?? .weekly,
                            weekday: (d.object(forKey: AutoKeys.weekday) as? Int).map { min(max($0, 1), 7) } ?? 2,
                            hour: (d.object(forKey: AutoKeys.hour) as? Int).map { min(max($0, 0), 23) } ?? 10,
                            minute: (d.object(forKey: AutoKeys.minute) as? Int).map { min(max($0, 0), 59) } ?? 0)
    }

    private var components: DateComponents {
        var c = DateComponents(hour: hour, minute: minute, second: 0)
        if frequency == .weekly { c.weekday = weekday }
        return c
    }

    /// The latest scheduled time at or before `now`.
    func lastSlot(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: now.addingTimeInterval(1), matching: components,
                          matchingPolicy: .nextTime, direction: .backward)
    }

    /// The first scheduled time after `now`.
    func nextSlot(after now: Date, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    /// Due once the latest scheduled time has passed and nothing happened since it: no run, and the
    /// schedule wasn't turned on or changed after it. So a Mac that slept through the time catches up
    /// when it wakes, it never runs twice for one scheduled time, and turning the schedule on or
    /// changing it never starts a clean straight away.
    func isDue(now: Date, lastRun: Date?, armedAt: Date, calendar: Calendar = .current) -> Bool {
        guard let slot = lastSlot(atOrBefore: now, calendar: calendar) else { return false }
        return max(lastRun ?? .distantPast, armedAt) < slot
    }

    /// "Every Monday at 10:00", "Every day at 10:00".
    var summary: String {
        let time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute))
            .map { $0.formatted(date: .omitted, time: .shortened) } ?? "\(hour):\(minute)"
        guard frequency == .weekly else { return "Every day at \(time)" }
        let names = Calendar.current.weekdaySymbols
        return "Every \(names[(weekday - 1) % names.count]) at \(time)"
    }
}

/// What the menu bar shows next to its icon.
enum MenuBarText: String, CaseIterable, Identifiable {
    case none, free, lastClean
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Icon only"
        case .free: return "Free space"
        case .lastClean: return "Last clean"
        }
    }
}

/// Picks what the automatic clean may delete: recommended caches only. Never the Trash, Downloads,
/// anything protected, or anything outside the allowed cache folders. Only folder and file
/// actions qualify: commands such as deleting simulators always need a review, and a target with
/// no paths is refused (an empty list would otherwise pass every check).
///
/// Narrower than a manual Junk clean, because nobody reviews it:
/// - in `~/.cache`, only tools whose caches are cheap to rebuild (`autoDotCache`); model caches such as
///   huggingface or torch can be many GB to download again, so they stay manual;
/// - crash reports (`~/Library/Logs/DiagnosticReports`) are kept;
/// - caches, sandbox caches and web caches of apps that are running are skipped.
enum AutoClean {
    /// `~/.cache/<name>` folders the weekly clean may empty.
    static let autoDotCache: Set<String> = [
        "pip", "pypoetry", "pre-commit", "go-build", "node-gyp", "yarn", "pnpm", "typescript",
        "black", "ruff", "mypy", "deno",
    ]

    static func select(_ targets: [CleanTarget], running: Set<String>? = nil) -> [CleanTarget] {
        let downloads = SafetyGuard.home.appendingPathComponent("Downloads").path
        let running = running ?? runningAppKeys()
        return targets.compactMap { t in
            guard t.recommended, t.isCleanable, t.category != .trash else { return nil }
            switch t.action {
            case .removeItem, .removeItems, .removeContents, .webCachesIn: break
            case .deleteUnavailableSimulators, .deleteSimRuntime: return nil
            }
            let paths = urls(t)
            guard !paths.isEmpty else { return nil }
            let allowed = paths.allSatisfy { u in
                !SafetyGuard.isInside(u.path, downloads) && !ProtectedPaths.isBlocked(u)
                    && SafetyGuard.isAllowed(u, allowContainer: { if case .removeContents = t.action { return true }; return false }())
            }
            guard allowed else { return nil }
            return narrowed(t, running: running)
        }
    }

    /// The part of a target the weekly clean may take, or nil if none.
    static func narrowed(_ t: CleanTarget, running: Set<String>) -> CleanTarget? {
        let dotCache = SafetyGuard.home.appendingPathComponent(".cache").path
        func keep(_ u: URL) -> Bool {
            if u.deletingLastPathComponent().path == dotCache, !autoDotCache.contains(u.lastPathComponent) { return false }
            if u.lastPathComponent == "DiagnosticReports" { return false }
            if let app = appKey(u), running.contains(app.lowercased()) { return false }
            return true
        }
        switch t.action {
        case .removeItems(let us):
            let kept = us.filter(keep)
            guard !kept.isEmpty else { return nil }
            guard kept.count != us.count else { return t }
            var n = t
            n.action = .removeItems(kept)
            n.sizeBytes = kept.reduce(0) { $0 + Scanner.allocatedSize($1) }
            return n.sizeBytes > 0 ? n : nil
        default:
            return urls(t).allSatisfy(keep) ? t : nil
        }
    }

    /// Bundle ids, names and executable names (lowercased) of the apps running now.
    static func runningAppKeys() -> Set<String> {
        var keys = Set<String>()
        for a in NSWorkspace.shared.runningApplications {
            for k in [a.bundleIdentifier, a.localizedName, a.executableURL?.lastPathComponent] { if let k { keys.insert(k.lowercased()) } }
        }
        return keys
    }

    /// The app a cache folder belongs to: `~/Library/Caches/<id>`, `~/Library/Containers/<id>/…` or
    /// `~/Library/Application Support/<name>/…`.
    static func appKey(_ u: URL) -> String? {
        let lib = SafetyGuard.home.appendingPathComponent("Library").path + "/"
        let p = u.standardizedFileURL.path
        guard p.hasPrefix(lib) else { return nil }
        let parts = p.dropFirst(lib.count).split(separator: "/").map(String.init)
        guard parts.count >= 2, ["Caches", "Containers", "Application Support"].contains(parts[0]) else { return nil }
        return parts[1]
    }

    static func urls(_ t: CleanTarget) -> [URL] {
        switch t.action {
        case .removeItem(let u), .removeContents(let u), .webCachesIn(let u): return [u]
        case .removeItems(let us): return us
        case .deleteUnavailableSimulators, .deleteSimRuntime: return []
        }
    }

    /// Full scan + clean, off the main thread. Returns bytes freed and the errors.
    /// `progress` gets a short status line ("Cleaning Xcode caches (3 of 12)") from a background thread.
    static func run(progress: @escaping @Sendable (String) -> Void = { _ in })
        -> (bytes: Int64, count: Int, errors: [String]) {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        progress("Measuring caches…")
        let plan = Scanner.plan()
        let box = Box([CleanTarget?](repeating: nil, count: plan.count))
        DispatchQueue.concurrentPerform(iterations: plan.count) { i in
            let t = Scanner.measure(plan[i])
            box.mutate { $0[i] = t }
        }
        let chosen = select(Scanner.finalize(box.value.compactMap { $0 }))
        var bytes: Int64 = 0, errors: [String] = []
        for (i, t) in chosen.enumerated() {
            progress("Cleaning \(t.name) (\(i + 1) of \(chosen.count))")
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
    /// Short status line while a clean runs ("Cleaning Xcode caches (3 of 12)").
    var status: String?
    var lastRun: Date? = UserDefaults.standard.object(forKey: AutoKeys.lastRun) as? Date
    var lastBytes: Int64 = Int64(UserDefaults.standard.integer(forKey: AutoKeys.lastBytes))
    /// When the scheduled clean runs next, nil when it's off.
    var nextRun: Date?
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private static var started = false

    static var thresholdBytes: Int64 {
        let gb = UserDefaults.standard.object(forKey: AutoKeys.thresholdGB) as? Int ?? 20
        return Int64(gb) * 1_000_000_000
    }
    static var alertsOn: Bool { UserDefaults.standard.object(forKey: AutoKeys.alerts) as? Bool ?? true }
    static var scheduleOn: Bool { UserDefaults.standard.bool(forKey: AutoKeys.weekly) }
    private static var armedAt: Date {
        UserDefaults.standard.object(forKey: AutoKeys.armedAt) as? Date ?? .distantPast
    }

    init() {
        guard !Self.started else { return }
        Self.started = true
        // Schedules turned on before armedAt existed start counting from now, so updating never
        // starts a clean straight away.
        if Self.scheduleOn, UserDefaults.standard.object(forKey: AutoKeys.armedAt) == nil {
            UserDefaults.standard.set(Date(), forKey: AutoKeys.armedAt)
        }
        refreshNextRun()
        // First check shortly after launch, then every 5 minutes (free space is cheap to read).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if Self.alertsOn || Self.scheduleOn { Notifier.requestPermission() }
            self?.tick()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 60
        // A Mac that slept through the scheduled time catches up shortly after it wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
    }

    func tick() {
        check()
        Updater.shared.checkIfDue()
        refreshNextRun()
        if Self.scheduleOn, !running,
           AutoSchedule.current.isDue(now: Date(), lastRun: lastRun, armedAt: Self.armedAt) {
            Task { await runClean(automatic: true) }
        }
    }

    /// Call when the schedule is turned on or changed: it then waits for the next scheduled time.
    func scheduleChanged() {
        UserDefaults.standard.set(Date(), forKey: AutoKeys.armedAt)
        if Self.scheduleOn { Notifier.requestPermission() }
        refreshNextRun()
    }

    func refreshNextRun() {
        nextRun = Self.scheduleOn ? AutoSchedule.current.nextSlot(after: Date()) : nil
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
        status = "Starting…"
        let before = Scanner.freeBytes()
        let r = await Task.detached(priority: automatic ? .utility : .userInitiated) {
            AutoClean.run { line in Task { @MainActor [weak self] in if self?.running == true { self?.status = line } } }
        }.value
        let measured = max(0, Scanner.freeBytes() - before)
        running = false
        status = nil
        lastRun = Date()
        lastBytes = r.bytes
        UserDefaults.standard.set(lastRun, forKey: AutoKeys.lastRun)
        UserDefaults.standard.set(Int(r.bytes), forKey: AutoKeys.lastBytes)
        HistoryStore.shared.add(automatic ? "Scheduled Safe Clean" : "Safe Clean", bytes: r.bytes, symbol: "calendar.badge.clock",
                                outcome: .deleted, measuredFreeChange: measured)
        if automatic && r.bytes > 0 {
            Notifier.post(title: "Scheduled clean: \(ByteText.string(r.bytes)) of caches deleted",
                          body: "\(r.count) cache location(s) cleaned. Nothing in your folders was touched.")
        }
        check()
        refreshNextRun()
    }

    func setLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Mac Cleaner login item: \(error.localizedDescription)") }
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    /// Text next to the menu bar icon, nil for none. Always "Cleaning…" while a clean runs.
    func menuBarText(_ choice: MenuBarText) -> String? {
        if running && choice != .none { return "Cleaning…" }
        switch choice {
        case .none: return nil
        case .free: return ByteText.string(freeBytes)
        case .lastClean: return lastRun == nil ? nil : "−" + ByteText.string(lastBytes)
        }
    }

    /// Menu bar icon: the app symbol normally, arrows while cleaning, a coloured warning when space is low.
    var menuBarImage: NSImage {
        let (name, color): (String, NSColor?) = switch (running, level) {
        case (true, _): ("arrow.triangle.2.circlepath", nil)
        case (false, .ok): ("square.grid.2x2.fill", nil)
        case (false, .low): ("externaldrive.fill.badge.exclamationmark", .systemOrange)
        case (false, .critical): ("externaldrive.fill.badge.xmark", .systemRed)
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
    @AppStorage(AutoKeys.weekly) private var scheduled = false
    @AppStorage(AutoKeys.frequency) private var frequency = AutoSchedule.Frequency.weekly
    @AppStorage(AutoKeys.weekday) private var weekday = 2
    @AppStorage(AutoKeys.hour) private var hour = 10
    @AppStorage(AutoKeys.minute) private var minute = 0
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
                Text("Now: \(ByteText.string(auto.freeBytes)) free · checked every 5 minutes · the menu bar icon turns orange, then red")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint)
            }
            Divider().opacity(0.5)
            Toggle("Scheduled safe clean", isOn: $scheduled)
            HStack(spacing: Space.s) {
                Picker("How often", selection: $frequency) {
                    ForEach(AutoSchedule.Frequency.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                if frequency == .weekly {
                    Picker("Day", selection: $weekday) {
                        ForEach(1...7, id: \.self) { d in
                            Text("on " + Calendar.current.weekdaySymbols[d - 1]).tag(d)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                DatePicker("at", selection: time, displayedComponents: .hourAndMinute)
                    .fixedSize()
                Spacer()
            }
            .disabled(!scheduled)
            .onChange(of: scheduled) { auto.scheduleChanged() }
            .onChange(of: frequency) { auto.scheduleChanged() }
            .onChange(of: weekday) { auto.scheduleChanged() }
            .onChange(of: hour) { auto.scheduleChanged() }
            .onChange(of: minute) { auto.scheduleChanged() }
            Text(scheduleText)
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
            Text(SafeCleanText.confirm)
        }
    }

    /// The schedule's hour and minute as a Date for the time picker.
    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                hour = c.hour ?? 10
                minute = c.minute ?? 0
            })
    }

    private var scheduleText: String {
        var s = "Recommended caches only (the same ones pre-selected in Junk Files). Never the Trash, Downloads, your folders or anything protected. A notification shows what was freed."
        if scheduled, let next = auto.nextRun {
            s += " Next: \(next.formatted(.dateTime.weekday(.wide).day().month().hour().minute())). If the Mac is asleep or off then, it runs soon after it wakes."
        }
        return s
    }

    private var levelColor: Color {
        switch auto.level { case .ok: Palette.success; case .low: Palette.warn; case .critical: Palette.danger }
    }

    private var lastText: String {
        guard let d = auto.lastRun else { return "Never run yet." }
        return "Last run \(d.formatted(.relative(presentation: .named))) · freed \(ByteText.string(auto.lastBytes))"
    }
}

/// Wording shared by every place that starts a safe clean.
enum SafeCleanText {
    static let confirm = "Deletes the recommended caches (they rebuild): developer caches, app caches, logs and browser caches. The Trash, Downloads, your folders and protected items are not touched. For an item-by-item list, use Junk Files instead."
}
