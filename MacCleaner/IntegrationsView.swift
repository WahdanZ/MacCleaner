import SwiftUI

struct IntegrationsView: View {
    @Environment(IntegrationsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Inside the Settings window: no title or Done button.
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if embedded {
                Text("Let AI assistants use Mac Cleaner through its MCP server. They can scan and show sizes, and clean only after you say yes.")
                    .font(.callout).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            } else {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect AI").font(.system(size: 22, weight: .bold))
                    Text("Let AI assistants use Mac Cleaner through its MCP server. They can scan, show sizes and, only after you say yes, clean, uninstall or move to Trash.")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            }
            }

            VStack(spacing: 6) {
                ForEach(model.clients) { c in ClientRow(client: c) }
            }

            if let m = model.message {
                HStack(spacing: 8) {
                    Image(systemName: m.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(m.isError ? Palette.warn : Palette.accent)
                    Text(m.text).font(.callout).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }
                .padding(10)
                .background((m.isError ? Palette.warn : Palette.accent).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ANY OTHER AI APP").font(.mono(10, .semibold)).foregroundStyle(Palette.faint)
                HStack(spacing: 8) {
                    Button { model.copySnippet() } label: { Label("Copy MCP config", systemImage: "doc.on.clipboard") }
                    Button { model.copySkill() } label: { Label("Copy skill text", systemImage: "text.badge.plus") }
                    Button { model.saveSkillFolder() } label: { Label("Save skill folder…", systemImage: "folder.badge.plus") }
                }
                .buttonStyle(.bordered)
                Text("Server command: \(SkillText.serverCommand) --mcp")
                    .font(.mono(10.5)).foregroundStyle(Palette.faint).textSelection(.enabled)
                Text("Each config file is backed up as <file>.maccleaner-backup before it is changed.")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.faint)
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 640)
        .background(embedded ? Color.clear : Palette.bgBottom)
        .foregroundStyle(Palette.fg)
        
        .onAppear { model.refresh() }
    }
}

private struct ClientRow: View {
    @Environment(IntegrationsModel.self) private var model
    let client: AIClient

    var body: some View {
        let connected = model.status[client.id] ?? false
        let installed = model.isInstalled(client)
        HStack(spacing: 12) {
            Circle().fill(connected ? Palette.accent : installed ? Palette.fg.opacity(0.25) : Palette.fg.opacity(0.08))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name).font(.system(size: 13, weight: .semibold))
                Text(installed ? client.detail : "Not found on this Mac (you can still add it)")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.faint)
            }
            Spacer()
            if connected {
                Text("CONNECTED").font(.mono(9, .bold)).foregroundStyle(Palette.accent)
                Button("Remove") { model.disconnect(client) }.buttonStyle(.bordered)
            } else {
                Button("Connect") { model.connect(client) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.fg.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(installed || connected ? 1 : 0.6)
    }
}
