import SwiftUI

/// Squarified treemap layout (Bruls, Huizing & van Wijk).
/// `values` must be sorted largest first.
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var r = rect
        var i = 0

        func worst(_ row: [Int], _ side: Double) -> Double {
            let s = row.reduce(0) { $0 + areas[$1] }
            let mx = row.map { areas[$0] }.max() ?? 0
            let mn = row.map { areas[$0] }.min() ?? 0
            guard s > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }

        while i < areas.count {
            let side = Double(min(r.width, r.height))
            var row = [i]
            var j = i + 1
            while j < areas.count && worst(row + [j], side) <= worst(row, side) {
                row.append(j)
                j += 1
            }
            let s = row.reduce(0) { $0 + areas[$1] }
            if r.width >= r.height {
                // Column on the left, full height.
                let w = CGFloat(s / Double(r.height))
                var y = r.minY
                for k in row {
                    let h = CGFloat(areas[k]) / w
                    result[k] = CGRect(x: r.minX, y: y, width: w, height: h)
                    y += h
                }
                r = CGRect(x: r.minX + w, y: r.minY, width: max(0, r.width - w), height: r.height)
            } else {
                // Row on top, full width.
                let h = CGFloat(s / Double(r.width))
                var x = r.minX
                for k in row {
                    let w = CGFloat(areas[k]) / h
                    result[k] = CGRect(x: x, y: r.minY, width: w, height: h)
                    x += w
                }
                r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: max(0, r.height - h))
            }
            i = j
        }
        return result
    }

    static func inset(_ r: CGRect, _ d: CGFloat) -> CGRect {
        r.width > d * 2 + 1 && r.height > d * 2 + 1 ? r.insetBy(dx: d, dy: d) : r
    }
}

/// The interactive space map: one block per item, area = size. Click to include/exclude.
/// Items under 0.4% of the total are grouped into one "N smaller items" block, so sizes stay honest.
struct TreemapView: View {
    @Environment(CleanerModel.self) private var model
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            let items = model.targets.sorted { $0.sizeBytes > $1.sizeBytes }
            let total = Double(items.reduce(0) { $0 + $1.sizeBytes })
            let big = Array(items.filter { Double($0.sizeBytes) >= total * 0.004 }.prefix(80))
            let bigIDs = Set(big.map(\.id))
            let small = items.filter { !bigIDs.contains($0.id) }
            let smallBytes = small.reduce(Int64(0)) { $0 + $1.sizeBytes }
            // The group block gets its true area, but at least 3% so it stays clickable.
            let values = big.map { Double($0.sizeBytes) } + (small.isEmpty ? [] : [max(Double(smallBytes), total * 0.03)])
            let order = values.indices.sorted { values[$0] > values[$1] }
            let rects = Treemap.layout(order.map { values[$0] }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(order.enumerated()), id: \.element) { slot, idx in
                    let r = Treemap.inset(rects[slot], 2)
                    if idx < big.count {
                        let t = big[idx]
                        TreemapBlock(target: t, size: r.size, hovered: hovered == t.id)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture { model.toggle(t.id) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(t.name), \(ByteText.string(t.sizeBytes))")
                            .accessibilityValue(t.selected ? "Included" : "Excluded")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.toggle(t.id) }
                            .onHover { inside in
                                if inside { hovered = t.id } else if hovered == t.id { hovered = nil }
                            }
                            .help("\(t.name) — \(ByteText.string(t.sizeBytes))\n\(t.path)\n\(t.note)")
                    } else {
                        SmallItemsBlock(items: small, bytes: smallBytes, size: r.size, hovered: hovered == "small")
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture { model.toggleAll(ids: Set(small.map(\.id))) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(small.count) smaller items, \(ByteText.string(smallBytes))")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.toggleAll(ids: Set(small.map(\.id))) }
                            .onHover { inside in
                                if inside { hovered = "small" } else if hovered == "small" { hovered = nil }
                            }
                            .help("\(small.count) smaller items, \(ByteText.string(smallBytes)) in total. Click to include or exclude them all; pick single ones in the list.")
                    }
                }
            }
        }
    }
}

private struct SmallItemsBlock: View {
    let items: [CleanTarget]
    let bytes: Int64
    let size: CGSize
    let hovered: Bool

    var body: some View {
        let on = items.allSatisfy(\.selected)
        let mixed = !on && items.contains(where: \.selected)
        let c = Color(hex: 0x8A94A6)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(c.opacity(on ? 0.55 : mixed ? 0.3 : (hovered ? 0.2 : 0.1)))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(c.opacity(hovered ? 0.9 : 0.5), style: StrokeStyle(lineWidth: 1, dash: on ? [] : [4, 3]))
            if size.width > 70 && size.height > 36 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(items.count) smaller items").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(ByteText.string(bytes)).font(.mono(10, .medium)).opacity(0.85)
                }
                .foregroundStyle(on ? Color.black.opacity(0.75) : Palette.fg.opacity(0.8))
                .padding(8)
                .padding(.trailing, 18)
            }
            if size.width > 34 && size.height > 26 {
                Image(systemName: on ? "checkmark.circle.fill" : mixed ? "minus.circle.fill" : "circle.dashed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on || mixed ? Color.black.opacity(0.5) : c)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

private struct TreemapBlock: View {
    let target: CleanTarget
    let size: CGSize
    let hovered: Bool

    var body: some View {
        let c = target.category.color
        let on = target.selected
        let big = size.width > 160 && size.height > 60
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(on
                      ? AnyShapeStyle(LinearGradient(colors: [c, c.opacity(0.7)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(c.opacity(hovered ? 0.2 : 0.09)))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(on ? Palette.fg.opacity(hovered ? 0.7 : 0.12) : c.opacity(hovered ? 0.9 : 0.5),
                              style: StrokeStyle(lineWidth: on ? 1 : 1.2, dash: on ? [] : [4, 3]))

            // Room for text = width minus padding and the check mark; below ~60 pt the name would wrap per letter.
            if size.width > 96 && size.height > 36 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(.system(size: big ? 13 : 11, weight: .semibold))
                        .lineLimit(size.width > 140 && size.height > 70 ? 2 : 1)
                        .truncationMode(.tail)
                    Text(ByteText.string(target.sizeBytes))
                        .font(.mono(big ? 12 : 10, .medium))
                        .opacity(0.85)
                    if big && size.height > 96 {
                        Spacer(minLength: 0)
                        Text(target.category.rawValue.uppercased())
                            .font(.mono(9, .semibold))
                            .opacity(0.65)
                    }
                }
                .foregroundStyle(on ? Color.black.opacity(0.82) : c)
                .padding(8)
                .padding(.trailing, 18)   // room for the check mark
            }

            if size.width > 34 && size.height > 26 {
                Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color.black.opacity(0.5) : c.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
        .brightness(hovered && on ? 0.07 : 0)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: on)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
