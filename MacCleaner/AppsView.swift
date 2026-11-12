import AppKit
import SwiftUI

struct AppsView: View {
    @Environment(AppsModel.self) private var apps
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        switch apps.phase {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "square.grid.2x2").font(.system(size: 50, weight: .light))
                    .foregroundStyle(Palette.accent)
                Text("Your apps").font(.system(size: 30, weight: .bold))
                Text("See how much each app and its data take, clear an app's cache, or uninstall it with its leftovers.")
                    .multilineTextAlignment(.center).foregroundStyle(Palette.dim)
                Button {
                    Task { await apps.scan() }
                } label: {
                    Label("Scan apps", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
        case .scanning:
            VStack(alignment: .leading, spacing: 14) {
                Text("MEASURING APPS").font(.mono(11, .bold)).foregroundStyle(Palette.accent)
                Text("\(apps.progressDone) / \(apps.progressTotal)").font(.mono(44, .bold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: apps.progressDone)
                ProgressView(value: Double(apps.progressDone), total: Double(max(apps.progressTotal, 1)))
                    .tint(Palette.accent)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
        case .done, .working:
            HStack(spacing: 14) {
                AppList()
                    .frame(minWidth: 300, maxWidth: 430)
                    .frame(maxHeight: .infinity)
                    .panel()
                AppDetail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .panel()
            }
        }
    }
}

// MARK: - List

private struct AppList: View {
    @Environment(AppsModel.self) private var apps
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        @Bindable var apps = apps
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(apps.apps.count) APPS").font(.mono(10.5, .bold)).foregroundStyle(Palette.accent)
                    Spacer()
                    Text("caches \(ByteText.string(apps.totalCaches))").font(.mono(10.5)).foregroundStyle(Palette.faint)
                    Button { Task { await apps.scan() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .help("Rescan apps")
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.faint)
                    TextField("Search apps", text: $apps.search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Palette.fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Picker("", selection: $apps.sort) {
                    ForEach(AppsModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(14)
            Rectangle().fill(Palette.stroke).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(apps.visible) { a in AppRow(app: a) }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct AppRow: View {
    @Environment(AppsModel.self) private var apps
    @Environment(ReviewCenter.self) private var review
    let app: AppInfo
    @State private var hover = false

    var body: some View {
        let selected = apps.selectedID == app.id
        Button { apps.selectedID = app.id } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        if app.isApple {
                            Text("APPLE").font(.mono(8, .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Palette.fg.opacity(0.1), in: Capsule())
                                .foregroundStyle(Palette.faint)
                        }
                        if apps.caskToken(app) != nil {
                            Tag(text: "HOMEBREW", color: Color(nsColor: .systemOrange))
                                .help("Installed with Homebrew (brew install --cask)")
                        }
                    }
                    Text(lastUsedText(app.lastUsed)).font(.system(size: 10.5)).foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteText.string(app.total)).font(.mono(11.5, .semibold))
                    if app.cacheSize > 0 {
                        Text("cache \(ByteText.string(app.cacheSize))").font(.mono(9.5)).foregroundStyle(Palette.accent)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? Palette.accent.opacity(0.14) : hover ? Palette.fg.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Palette.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

func lastUsedText(_ d: Date?) -> String {
    guard let d else { return "Never opened (or unknown)" }
    return "Last used " + d.formatted(.relative(presentation: .named))
}

// MARK: - Detail

private struct AppDetail: View {
    @Environment(AppsModel.self) private var apps
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        if let a = apps.selected {
            let block = apps.uninstallBlock(a)
            let running = apps.isRunning(a)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path))
                        .resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.name).font(.system(size: 24, weight: .bold))
                        Text("\(a.bundleID)\(a.version.isEmpty ? "" : " · v\(a.version)")")
                            .font(.mono(11)).foregroundStyle(Palette.faint)
                        Text(Scanner.tilde(a.url)).font(.mono(11)).foregroundStyle(Palette.faint)
                        Text(lastUsedText(a.lastUsed) + (running ? " · running now" : ""))
                            .font(.system(size: 11.5)).foregroundStyle(running ? Palette.warn : Palette.dim)
                    }
                    Spacer()
                }

                if let token = apps.caskToken(a) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "mug").foregroundStyle(Color(nsColor: .systemOrange))
                        Text("Installed with Homebrew (\(token)). Uninstalling with Homebrew keeps brew's list correct.")
                            .font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Uninstall with Homebrew…") {
                            review.present(ReviewRequest(
                                title: "Uninstall \(a.name) with Homebrew",
                                explanation: "Runs brew uninstall --cask \(token). Homebrew deletes the app; it doesn't go to the Trash. Leftovers in your Library stay; use Uninstall afterwards to remove them too.",
                                items: [ReviewItem(id: a.url.path, name: "\(a.name).app", location: a.url.path, size: a.appSize,
                                                   action: .command, risk: .review, note: "brew uninstall --cask \(token)",
                                                   blocked: ProtectedPaths.reason(a.url))],
                                verb: "Uninstall", perform: { Task { await apps.uninstallWithBrew(a) } }))
                        }
                        .disabled(apps.phase == .working || a.isSelf)
                    }
                    .padding(Space.m)
                    .background(Color(nsColor: .systemOrange).opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                }

                HStack(spacing: 10) {
                    StatTile(label: "APP", value: a.appSize, color: Palette.fg)
                    StatTile(label: "DATA", value: a.dataSize, color: Color(hex: 0x4EA8FF))
                    StatTile(label: "CACHE", value: a.cacheSize, color: Palette.accent)
                    StatTile(label: "TOTAL", value: a.total, color: Palette.fg)
                }

                if let m = apps.message {
                    HStack(spacing: 8) {
                        Image(systemName: m.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(m.isError ? Palette.warn : Palette.accent)
                        Text(m.text).font(.callout).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                        Button { apps.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(10)
                    .background((m.isError ? Palette.warn : Palette.accent).opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack(spacing: 8) {
                    Button {
                        if let a = apps.selected { review.present(ReviewBuild.appCache(a) { Task { await apps.clearCaches(a) } }) }
                    } label: {
                        Label(a.cacheSize > 0 ? "Clear cache \(ByteText.string(a.cacheSize))" : "No cache to clear",
                              systemImage: "wind")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(a.cacheSize == 0 || apps.phase == .working)

                    Button {
                        if let a = apps.selected { review.present(ReviewBuild.uninstall(a, running: apps.isRunning(a)) { Task { await apps.uninstall() } }) }
                    } label: {
                        Label("Uninstall…", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(block != nil || apps.phase == .working)
                    .help(block ?? (running ? "Quits the app, then moves it and the checked leftovers to the Trash"
                                            : "Move the app and the checked leftovers to the Trash"))

                    if running && !a.isSelf && !a.isApple {
                        Button {
                            Task { await apps.quit(a) }
                        } label: {
                            Label(apps.quittingID == a.id ? "Quitting…" : "Quit app", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(apps.quittingID != nil)
                        .help("Asks the app to quit, then force-quits after 5 seconds if it doesn't respond")
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([a.url]) } label: {
                        Label("Reveal", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    if apps.phase == .working { ProgressView().controlSize(.small) }
                }
                if let block {
                    Label("Uninstall unavailable: \(block)", systemImage: "lock.fill")
                        .font(.system(size: 11)).foregroundStyle(Palette.faint)
                }

                Rectangle().fill(Palette.stroke).frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ItemSection(title: "CACHE · cleared by “Clear cache”",
                                    empty: a.caches.isEmpty ? "No caches found for this app." : nil) {
                            ForEach(a.caches) { c in ItemLine(item: c, checkable: false) }
                        }
                        ItemSection(title: "EVERYTHING THE APP LEFT · moved to Trash on uninstall (checked items)",
                                    empty: a.leftovers.isEmpty ? "No leftover data found." : nil) {
                            ForEach(a.leftovers) { l in ItemLine(item: l, checkable: true) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(22)
        } else {
            Text("Select an app").foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ItemSection<Content: View>: View {
    let title: String
    let empty: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.mono(10, .semibold)).foregroundStyle(Palette.faint)
            if let empty {
                Text(empty).font(.system(size: 11)).foregroundStyle(Palette.faint).padding(.vertical, 4)
            } else {
                content
            }
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: Int64
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.mono(9.5, .semibold)).foregroundStyle(Palette.faint)
            Text(ByteText.string(value)).font(.mono(17, .bold)).foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fg.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.stroke))
    }
}

private struct ItemLine: View {
    @Environment(AppsModel.self) private var apps
    @Environment(ReviewCenter.self) private var review
    let item: AppLeftover
    let checkable: Bool

    var body: some View {
        HStack(spacing: 10) {
            if checkable {
                Button { apps.toggleLeftover(item.id) } label: {
                    CheckSquare(on: item.include, color: Palette.danger)
                }
                .buttonStyle(.plain)
                .help(item.include ? "Will be moved to the Trash on uninstall" : "Will be kept")
            } else {
                Image(systemName: "wind").font(.system(size: 10)).foregroundStyle(Palette.accent).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label).font(.system(size: 12, weight: .medium))
                    if item.needsAdmin {
                        Text("PASSWORD").font(.mono(8, .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.warn.opacity(0.18), in: Capsule())
                            .foregroundStyle(Palette.warn)
                            .help("Outside your home folder: macOS asks for your password once during uninstall")
                    }
                    if item.launchLabel != nil {
                        Text("STOPS BACKGROUND JOB").font(.mono(8, .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.fg.opacity(0.1), in: Capsule())
                            .foregroundStyle(Palette.dim)
                    }
                    if let n = item.note {
                        Text(n).font(.system(size: 10)).foregroundStyle(Palette.warn).lineLimit(1)
                    }
                }
                Text(item.receipt != nil ? "pkgutil --forget \(item.receipt!)" : Scanner.tilde(item.url))
                    .font(.mono(10.5)).foregroundStyle(Palette.faint)
                    .lineLimit(1).truncationMode(.middle).help(item.url.path)
            }
            Spacer(minLength: 8)
            Text(ByteText.string(item.size)).font(.mono(11.5, .medium))
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.dim)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.fg.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
