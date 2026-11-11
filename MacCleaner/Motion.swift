import SwiftUI

// Animations used across the app. Every one respects System Settings › Accessibility › Reduce motion.

/// Rows fade and slide up one after another when a list appears.
struct AppearIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 10)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(Double(min(index, 14)) * 0.035)) { shown = true }
            }
    }
}

extension View {
    func appearIn(_ index: Int = 0) -> some View { modifier(AppearIn(index: index)) }

    /// Slight lift while the pointer is over a card.
    func hoverLift(_ amount: CGFloat = 1.012) -> some View { modifier(HoverLift(amount: amount)) }
}

struct HoverLift: ViewModifier {
    let amount: CGFloat
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .scaleEffect(hover && !reduce ? amount : 1)
            .shadow(color: .black.opacity(hover ? 0.08 : 0), radius: 14, y: 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hover)
            .onHover { hover = $0 }
    }
}

/// Scanning indicator: a sweeping gradient ring with pulses going out.
struct ScanPulse: View {
    var symbol = "magnifyingglass"
    var size: CGFloat = 96
    @State private var spin = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Palette.accent.opacity(0.35), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.7 : 0.8)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(reduce ? nil : .easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(i) * 0.7),
                               value: pulse)
            }
            Circle().fill(Palette.accent.opacity(0.1))
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(AngularGradient(colors: [Palette.accent.opacity(0), Palette.accent2, Palette.accent], center: .center),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(reduce ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                .padding(4)
            Image(systemName: symbol)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduce)
        }
        .frame(width: size, height: size)
        .onAppear { spin = true; pulse = true }
    }
}

/// Full-page "working on it" state with the pulse, a title and the current item.
struct WorkingState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 18) {
            ScanPulse(symbol: symbol)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(detail).font(.mono(11)).foregroundStyle(Palette.faint)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 600)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

// MARK: - Celebration after every cleanup

/// Watches the history: when a cleanup is recorded, a card with a drawn check mark and a burst of particles
/// shows how much was freed, then fades away.
struct CelebrationOverlay: View {
    @State private var shown: CleanupRecord?
    @State private var lastID: UUID? = HistoryStore.shared.records.first?.id
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let r = shown {
                CelebrationCard(record: r)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                            removal: .opacity.combined(with: .move(edge: .bottom))))
                    .onTapGesture { dismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 90)
        .allowsHitTesting(shown != nil)
        .onChange(of: HistoryStore.shared.records.first?.id) { _, id in
            guard let id, id != lastID, let r = HistoryStore.shared.records.first else { return }
            lastID = id
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { shown = r }
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(3.2))
                if !Task.isCancelled { dismiss() }
            }
        }
    }

    private func dismiss() { withAnimation(.easeIn(duration: 0.25)) { shown = nil } }
}

private struct CelebrationCard: View {
    let record: CleanupRecord
    @State private var drawn = false
    @State private var burst = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Palette.success.opacity(0.15))
                Circle().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Palette.success, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Palette.success, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .padding(15)
                if !reduce { Particles(burst: burst) }
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("Freed \(ByteText.string(record.bytes))")
                    .font(.system(size: 22, weight: .bold)).monospacedDigit()
                Text(record.title).font(.system(size: 13)).foregroundStyle(Palette.dim)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.success.opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55).delay(0.12)) { drawn = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.2)) { burst = true }
        }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - r.height * 0.08))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.12))
        return p
    }
}

/// 14 dots flying outward from the check mark.
private struct Particles: View {
    let burst: Bool
    private static let colors: [Color] = [Palette.success, Palette.accent, Palette.accent2, Color(hex: 0xF7B731), Color(hex: 0xF0559C)]

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) / 14 * 2 * .pi + 0.3
                let dist: CGFloat = burst ? CGFloat(46 + (i % 3) * 12) : 0
                Circle()
                    .fill(Self.colors[i % Self.colors.count])
                    .frame(width: CGFloat(4 + i % 3 * 2), height: CGFloat(4 + i % 3 * 2))
                    .offset(x: cos(angle) * dist, y: sin(angle) * dist)
                    .opacity(burst ? 0 : 1)
                    .scaleEffect(burst ? 0.4 : 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Number that rolls to its new value.
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
