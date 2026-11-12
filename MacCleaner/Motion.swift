import SwiftUI

// Motion is used only where it explains something: content appearing, progress, and a short note when a
// cleanup finishes. Everything respects System Settings › Accessibility › Reduce motion.

/// Content fades in and rises a few points when it first appears; items in a group follow each other
/// by 40 ms (capped), so a dashboard settles in under half a second. Off under Reduce Motion.
struct AppearIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduce ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 8)
            .onAppear {
                guard !reduce else { shown = true; return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86).delay(Double(min(index, 8)) * 0.04)) { shown = true }
            }
    }
}

extension View {
    func appearIn(_ index: Int = 0) -> some View { modifier(AppearIn(index: index)) }

    /// Hover feedback for clickable cards: a subtle tint, no scaling.
    func hoverLift(_ amount: CGFloat = 1) -> some View { modifier(HoverHighlight()) }
}

struct HoverHighlight: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Palette.fg.opacity(hover ? 0.035 : 0)).allowsHitTesting(false))
            .onHover { hover = $0 }
    }
}

/// System progress indicator (kept under its old name for existing call sites).
struct ScanPulse: View {
    var symbol = "magnifyingglass"
    var size: CGFloat = 96
    var body: some View { ProgressView().controlSize(.large) }
}

/// Full-page "working on it" state: system spinner, a title and the current item.
struct WorkingState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Space.m) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            Text(detail).font(.callout.monospaced()).foregroundStyle(Palette.dim)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(detail)")
    }
}

// MARK: - Completion note

/// When a cleanup is recorded, a short note says what really happened ("Deleted 2.1 GB" or
/// "Moved 1.4 GB to Trash") and VoiceOver announces it. It disappears on its own.
struct CompletionToast: View {
    @State private var shown: CleanupRecord?
    @State private var lastID: UUID? = HistoryStore.shared.records.first?.id
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            if let r = shown {
                HStack(spacing: Space.m) {
                    Image(systemName: r.outcome == .trashed ? "trash.circle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(r.outcome == .trashed ? Palette.dim : Palette.success)
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduce ? nil : r.id)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(r.resultText).font(.headline).monospacedDigit()
                        Text(detail(r)).font(.caption).foregroundStyle(Palette.dim)
                    }
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss")
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
                .floatingBar()
                .padding(.bottom, Space.xxl)
                .transition(reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: HistoryStore.shared.records.first?.id) { _, id in
            guard let id, id != lastID, let r = HistoryStore.shared.records.first else { return }
            lastID = id
            withAnimation(reduce ? nil : .spring(response: 0.45, dampingFraction: 0.8)) { shown = r }
            AccessibilityNotification.Announcement("\(r.resultText). \(detail(r))").post()
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { dismiss() }
            }
        }
    }

    private func detail(_ r: CleanupRecord) -> String {
        if r.outcome == .trashed { return "\(r.title). Empty the Trash to free the space." }
        if let m = r.measuredFreeChange, m > 0 { return "\(r.title). Free space went up by \(ByteText.string(m))." }
        return r.title
    }

    private func dismiss() { withAnimation(Motion.quick(reduce)) { shown = nil } }
}

/// Number that rolls to its new value (content transition only; no motion under Reduce Motion).
struct RollingBytes: View {
    let bytes: Int64
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold

    var body: some View {
        Text(ByteText.string(bytes))
            .font(.system(size: size, weight: weight)).monospacedDigit()
            .contentTransition(.numericText(value: Double(bytes)))
            .animation(.snappy, value: bytes)
    }
}
