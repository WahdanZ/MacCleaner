import AppKit
import SwiftUI

/// Overview card: Trash size, Empty Trash, Put Back.
struct TrashCard: View {
    @Environment(TrashModel.self) private var trash

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trash").font(.system(size: 20, weight: .bold))
                Spacer()
                if !trash.isExact {
                    Button("Measure all") { Task { await trash.refresh(askFinder: true) } }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 13, weight: .medium))
                        .help("Asks Finder for the full Trash contents (macOS asks once to allow this).")
                }
            }
            HStack(spacing: 14) {
                IconTile(symbol: trash.displayBytes > 0 ? "trash.fill" : "trash", color: Color(hex: 0x8A94A6), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trash.isExact ? ByteText.string(trash.displayBytes)
                                       : (trash.displayBytes > 0 ? "≥ \(ByteText.string(trash.displayBytes))" : "—"))
                        .font(.system(size: 22, weight: .bold)).monospacedDigit()
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.dim).lineLimit(2)
                }
                Spacer()
            }
            if let m = trash.message {
                MessageBar(text: m.text, isError: m.isError) { trash.message = nil }
            }
            HStack(spacing: 8) {
                Button { trash.showPutBack = true } label: { Label("Put Back…", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(trash.status.appItems.isEmpty)
                Spacer()
                Button { trash.confirmingEmpty = true } label: { Label("Empty Trash", systemImage: "trash.slash") }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(trash.busy || (trash.isExact && trash.status.itemCount == 0))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 22)
        .task { await trash.refresh() }
    }

    private var subtitle: String {
        let app = trash.status.appItems.count
        if let n = trash.status.itemCount {
            return "\(n) item(s) in the Trash" + (app > 0 ? " · \(app) from Mac Cleaner" : "")
        }
        return app > 0 ? "\(app) item(s) moved by Mac Cleaner. Click Measure all for the full size."
                       : "Click Measure all to see the full Trash."
    }
}

/// Alerts + Put Back sheet, attached once at the window root.
struct TrashAlerts: ViewModifier {
    @Environment(TrashModel.self) private var trash

    func body(content: Content) -> some View {
        @Bindable var trash = trash
        content
            .alert("Empty the Trash?", isPresented: $trash.confirmingEmpty) {
                Button("Empty Trash", role: .destructive) { Task { await trash.empty() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text((trash.isExact
                      ? "\(trash.status.itemCount ?? 0) item(s), \(ByteText.string(trash.displayBytes)).\n\n"
                      : "")
                     + "This permanently deletes everything in the Trash, including items Mac Cleaner didn't put there. It can't be undone.")
            }
            .sheet(isPresented: $trash.showPutBack) { PutBackSheet() }
    }
}

struct PutBackSheet: View {
    @Environment(TrashModel.self) private var trash
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Put Back").font(.system(size: 22, weight: .bold))
                    Text("Items Mac Cleaner moved to the Trash that are still there.")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
            if let m = trash.message { MessageBar(text: m.text, isError: m.isError) { trash.message = nil } }
            if trash.status.appItems.isEmpty {
                EmptyState(symbol: "arrow.uturn.backward", title: "Nothing to put back",
                           text: "Items you trash with Mac Cleaner appear here until the Trash is emptied.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(trash.status.appItems) { item in
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.trashed)).resizable().frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text("\(Scanner.tilde(URL(fileURLWithPath: item.original).deletingLastPathComponent())) · \(item.source) · \(item.date.formatted(.relative(presentation: .named)))")
                                        .font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteText.string(item.size)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.dim)
                                Button("Put Back") { Task { await trash.putBack(item) } }
                                    .buttonStyle(GhostButtonStyle())
                                    .disabled(!item.restorable || trash.busy)
                                    .help(item.restorable ? "Move back to \(item.original)" : "System files: drag them out of the Trash in Finder")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 640, height: 520)
        .background(AppBackground())
        .task { await trash.refresh() }
    }
}
