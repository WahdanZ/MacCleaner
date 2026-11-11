import AppKit
import SwiftUI

/// Welcome tour: shown on first launch, and again from Help › "Take the tour".
/// Every feature card opens its page.
struct IntroView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("sidebarPage") private var page: SidebarPage = .overview
    @AppStorage("introSeen") private var introSeen = false
    @State private var step = 0
    @State private var forward = true

    private let steps = IntroStep.all

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(steps.indices, id: \.self) { i in
                    if i == step {
                        StepView(step: steps[i], index: i, open: open)
                            .transition(reduce ? .opacity : .asymmetric(
                                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack(spacing: 14) {
                Button("Skip tour") { finish() }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).font(.system(size: 13))
                    .opacity(step == steps.count - 1 ? 0 : 1)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Palette.accent : Palette.fg.opacity(0.18))
                            .frame(width: i == step ? 22 : 7, height: 7)
                            .onTapGesture { go(to: i) }
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
                Spacer()
                if step > 0 {
                    Button("Back") { go(to: step - 1) }.buttonStyle(GhostButtonStyle())
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(step == steps.count - 1 ? "Get started" : "Next") {
                    step == steps.count - 1 ? finish(scan: true) : go(to: step + 1)
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30).padding(.vertical, 18)
            .background(Palette.fg.opacity(0.03))
            .overlay(alignment: .top) { Rectangle().fill(Palette.stroke).frame(height: 1) }
        }
        .frame(width: 900, height: 620)
        .background(AppBackground())
        .onExitCommand { finish() }
    }

    private func go(to i: Int) {
        guard i != step, steps.indices.contains(i) else { return }
        forward = i > step
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = i }
    }

    private func open(_ p: SidebarPage) {
        page = p
        finish()
    }

    private func finish(scan: Bool = false) {
        introSeen = true
        if scan { page = .overview }
        dismiss()
    }
}

// MARK: - Content

struct IntroFeature: Identifiable {
    let id = UUID()
    let symbol: String
    let color: Color
    let title: String
    let text: String
    var page: SidebarPage?
}

struct IntroStep {
    let symbol: String
    let color: Color
    let kicker: String
    let title: String
    let text: String
    let features: [IntroFeature]
    /// Shows the animated terminal instead of the icon.
    var terminal = false

    static let all: [IntroStep] = [
        IntroStep(symbol: "sparkles", color: Color(hex: 0x1A7CFF), kicker: "WELCOME",
                  title: "Free up space on your Mac,\nwithout the worry.",
                  text: "Mac Cleaner finds what's safe to remove, shows you every item with its size, and removes nothing until you say so.",
                  features: [
                    IntroFeature(symbol: "eye", color: Color(hex: 0x1A7CFF), title: "You see everything",
                                 text: "Every item, its size and where it lives, before anything happens."),
                    IntroFeature(symbol: "hand.raised", color: Color(hex: 0x22A54A), title: "You decide",
                                 text: "A confirm dialog lists every item. Personal files go to the Trash, so you can put them back."),
                    IntroFeature(symbol: "lock.shield", color: Color(hex: 0xF97316), title: "Your folders are safe",
                                 text: "Add any folder to Protected and no feature, command or AI tool can touch it."),
                  ]),
        IntroStep(symbol: "trash", color: Color(hex: 0xF0559C), kicker: "FIND SPACE",
                  title: "Clear what rebuilds itself.",
                  text: "Caches and build files come back automatically when an app or build tool needs them. These pages find them.",
                  features: [
                    IntroFeature(symbol: "trash", color: Color(hex: 0xF43F5E), title: "Junk Files",
                                 text: "340+ cache, log and temp locations, on a map sized by space.", page: .junk),
                    IntroFeature(symbol: "hammer", color: Color(hex: 0x8B5CF6), title: "Projects",
                                 text: "node_modules, build, .dart_tool, Pods… in your code projects, with how long since you touched them.", page: .projects),
                    IntroFeature(symbol: "shippingbox", color: Color(hex: 0x3A8DFF), title: "Developer SDKs",
                                 text: "Simulator runtimes, Android images, NDKs and Docker data. In-use items are flagged.", page: .sdks),
                  ]),
        IntroStep(symbol: "magnifyingglass", color: Color(hex: 0x14B8C8), kicker: "YOUR FILES",
                  title: "Find the big and the forgotten.",
                  text: "Your own files are never deleted outright: they go to the Trash, and Put Back returns them.",
                  features: [
                    IntroFeature(symbol: "laptopcomputer", color: Color(hex: 0x14B8C8), title: "Large & Old Files",
                                 text: "Big files and files you haven't opened in months.", page: .large),
                    IntroFeature(symbol: "plus.square.on.square", color: Color(hex: 0x1A7CFF), title: "Duplicates",
                                 text: "Identical files compared by content. One copy always stays.", page: .duplicates),
                    IntroFeature(symbol: "chart.bar.xaxis", color: Color(hex: 0xF7B731), title: "Storage Analysis",
                                 text: "Browse every folder by size to see exactly where the space goes.", page: .storage),
                  ]),
        IntroStep(symbol: "square.grid.2x2", color: Color(hex: 0x22A54A), kicker: "APPS & SYSTEM",
                  title: "Uninstall completely. Understand System Data.",
                  text: "Dragging an app to the Trash leaves its data behind. Mac Cleaner finds the leftovers too.",
                  features: [
                    IntroFeature(symbol: "square.grid.2x2", color: Color(hex: 0x22A54A), title: "Apps",
                                 text: "Clear an app's cache, or uninstall it with its data, helpers and drivers.", page: .apps),
                    IntroFeature(symbol: "internaldrive", color: Color(hex: 0xF0559C), title: "System Data",
                                 text: "Time Machine snapshots, iPhone backups, Mail and Messages attachments.", page: .systemData),
                    IntroFeature(symbol: "power", color: Color(hex: 0xF97316), title: "Startup & Extensions",
                                 text: "What starts with your Mac, plus plug-ins and drivers from other developers.", page: .startup),
                  ]),
        IntroStep(symbol: "bell.badge", color: Color(hex: 0xF97316), kicker: "ON AUTOPILOT",
                  title: "Never run out of space by surprise.",
                  text: "Turn these on in Settings. They run quietly from the menu bar.",
                  features: [
                    IntroFeature(symbol: "externaldrive.badge.exclamationmark", color: Color(hex: 0xF97316), title: "Low-disk alert",
                                 text: "The menu bar icon turns orange, then red, and you get a notification below your limit."),
                    IntroFeature(symbol: "calendar.badge.clock", color: Color(hex: 0x8B5CF6), title: "Weekly safe clean",
                                 text: "Optional. Recommended caches only; never the Trash, Downloads or your folders."),
                    IntroFeature(symbol: "menubar.rectangle", color: Color(hex: 0x1A7CFF), title: "Menu bar",
                                 text: "Free space at a glance, a rescan, and the app one click away."),
                  ]),
        IntroStep(symbol: "terminal", color: Color(hex: 0x8B5CF6), kicker: "TERMINAL & AI",
                  title: "Use it from Terminal,\nor let your AI do it.",
                  text: "Everything the app does is also a command and an MCP tool, with the same safety rules: a preview first, then your yes.",
                  features: [
                    IntroFeature(symbol: "terminal", color: Color(hex: 0x8B5CF6), title: "mac-cleaner command",
                                 text: "Commands for everything: status, scan, clean, projects, sdks, uninstall… Run mac-cleaner help to see them all. Add --json for scripts."),
                    IntroFeature(symbol: "point.3.connected.trianglepath.dotted", color: Color(hex: 0x1A7CFF), title: "MCP server",
                                 text: "21 tools for Claude Code, Claude Desktop, Cursor, Codex, VS Code, Windsurf and Gemini. Set up in Settings › Connect AI."),
                    IntroFeature(symbol: "sparkles", color: Color(hex: 0x22A54A), title: "AI skill",
                                 text: "Teaches your assistant the rules: show every item, never confirm on its own, never touch protected folders."),
                  ], terminal: true),
        IntroStep(symbol: "checkmark.seal", color: Color(hex: 0x22A54A), kicker: "READY",
                  title: "One last thing: Full Disk Access.",
                  text: "Without it, macOS hides some folders (Trash, Mail, Messages, other apps' data), so totals come out low. It's optional, and you can grant it later in Settings.",
                  features: [
                    IntroFeature(symbol: "lock.open", color: Color(hex: 0x22A54A), title: "Grant access",
                                 text: "System Settings › Privacy & Security › Full Disk Access › turn on Mac Cleaner."),
                    IntroFeature(symbol: "house", color: Color(hex: 0x1A7CFF), title: "Start on Overview",
                                 text: "Scan for junk, review the recommendations, then clean.", page: .overview),
                    IntroFeature(symbol: "questionmark.circle", color: Color(hex: 0x8A94A6), title: "Tour again",
                                 text: "Click ? at the top right, then Take the tour."),
                  ]),
    ]
}

// MARK: - Pieces

private struct StepView: View {
    let step: IntroStep
    let index: Int
    let open: (SidebarPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(step.kicker).font(.mono(12, .bold)).foregroundStyle(step.color)
                    Text(step.title).font(.system(size: 32, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(step.text).font(.system(size: 15)).foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480, alignment: .leading)
                    if step.terminal { InstallCLIButton().padding(.top, 4) }
                    if index == IntroStep.all.count - 1 {
                        Button {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(u)
                            }
                        } label: { Label("Open Full Disk Access settings", systemImage: "lock.open") }
                            .buttonStyle(GhostButtonStyle())
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
                if step.terminal {
                    HeroTerminal()
                } else {
                    HeroIcon(symbol: index == 0 ? nil : step.symbol, color: step.color)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(step.features.enumerated()), id: \.1.id) { i, f in
                    FeatureCard(feature: f, open: open).appearIn(i + 1)
                }
            }
        }
        .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The big illustration: the app icon (first step) or a symbol, floating, with orbiting dots and a glow.
private struct HeroIcon: View {
    let symbol: String?
    let color: Color
    @State private var float = false
    @State private var orbit = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [color.opacity(0.35), color.opacity(0)], center: .center,
                                         startRadius: 10, endRadius: 120))
                .frame(width: 240, height: 240)
                .scaleEffect(float ? 1.06 : 0.94)
            Circle().stroke(color.opacity(0.18), lineWidth: 1).frame(width: 190, height: 190)
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(color.opacity(0.75 - Double(i) * 0.2)).frame(width: CGFloat(10 - i * 2))
                    .offset(x: 95)
                    .rotationEffect(.degrees(Double(i) * 120 + (orbit ? 360 : 0)))
            }
            Group {
                if let symbol {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 124, height: 124)
                        .overlay(Image(systemName: symbol).font(.system(size: 54, weight: .semibold)).foregroundStyle(.white))
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 150, height: 150)
                }
            }
            .shadow(color: color.opacity(0.45), radius: 24, y: 10)
            .offset(y: float ? -6 : 6)
        }
        .frame(width: 250, height: 230)
        .onAppear {
            guard !reduce else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { float = true }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { orbit = true }
        }
    }
}

private struct FeatureCard: View {
    let feature: IntroFeature
    let open: (SidebarPage) -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconTile(symbol: feature.symbol, color: feature.color, size: 42)
            Text(feature.title).font(.system(size: 15, weight: .semibold))
            Text(feature.text).font(.system(size: 12.5)).foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let p = feature.page {
                Button { open(p) } label: {
                    HStack(spacing: 4) {
                        Text("Open \(p.title)")
                        Image(systemName: "arrow.right").offset(x: hover ? 3 : 0)
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(feature.color)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(hover ? feature.color.opacity(0.08) : Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(hover ? feature.color.opacity(0.4) : Palette.stroke))
        .animation(.easeOut(duration: 0.18), value: hover)
        .onHover { hover = $0 }
    }
}


/// Install button for the tour's Terminal page.
private struct InstallCLIButton: View {
    @State private var installed = CLIInstaller.installedAt
    @State private var note: String?

    var body: some View {
        HStack(spacing: 10) {
            if let installed {
                Label("Installed: \(Scanner.tilde(installed))", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.success)
            } else {
                Button {
                    switch CLIInstaller.install() {
                    case .success(let u): installed = u
                        if u.path.contains("/.local/bin") { note = "Make sure ~/.local/bin is on your PATH." }
                    case .failure(let e): note = e.localizedDescription
                    }
                } label: { Label("Install the mac-cleaner command", systemImage: "terminal") }
                    .buttonStyle(GhostButtonStyle())
            }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Palette.faint) }
        }
        .animation(.snappy, value: installed)
    }
}

/// A small terminal window that types a session, line by line, on a loop.
private struct HeroTerminal: View {
    private static let script: [(String, Bool)] = [
        ("mac-cleaner status", true),
        ("free: 48.2 GB   used: 451.8 GB", false),
        ("mac-cleaner clean --recommended", true),
        ("• Xcode DerivedData  ·  2.1 GB", false),
        ("• npm cache  ·  1.4 GB", false),
        ("Go ahead? Type yes to continue: yes", false),
        ("freed: 3.5 GB", false),
    ]
    @State private var shown = 0
    @State private var typed = 0
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) {
                    Circle().fill($0).frame(width: 9, height: 9)
                }
                Spacer()
                Text("Terminal").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<min(shown + 1, Self.script.count), id: \.self) { i in
                    let (line, cmd) = Self.script[i]
                    let text = i < shown ? line : (cmd ? String(line.prefix(typed)) : "")
                    HStack(spacing: 5) {
                        if cmd { Text("$").foregroundStyle(Color(hex: 0x28C840)) }
                        Text(text).foregroundStyle(cmd ? .white : .white.opacity(line.hasPrefix("freed") ? 1 : 0.65))
                            .fontWeight(line.hasPrefix("freed") ? .bold : .regular)
                        if i == shown { Rectangle().fill(.white.opacity(0.8)).frame(width: 6, height: 12) }
                    }
                }
            }
            .font(.mono(10.5))
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 300, height: 196)
        .background(Color(hex: 0x15171C), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: Color(hex: 0x8B5CF6).opacity(0.35), radius: 26, y: 12)
        .onAppear(perform: start)
        .onDisappear { timer?.invalidate() }
    }

    private func start() {
        if reduce { shown = Self.script.count; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { _ in
            Task { @MainActor in
                guard shown < Self.script.count else {
                    // Hold the finished session for ~7 s, then start over.
                    typed += 1
                    if typed > 200 { shown = 0; typed = 0 }
                    return
                }
                let (line, cmd) = Self.script[shown]
                typed += 1
                // Commands type one letter per tick; output lines appear after a short pause.
                let done = cmd ? typed > line.count + 10 : typed > 9
                if done { typed = 0; shown += 1 }
            }
        }
    }
}
