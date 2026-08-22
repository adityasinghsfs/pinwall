import SwiftUI

/// PinWall's settings design language, ported from Josh Puckett's DialKit:
/// dark glass panel, collapsible folders, rubber sliders with mono readouts,
/// Off/On segmented toggles, animated tab pill. Tokens mirror dialkit's CSS
/// custom properties (--dial-surface, --dial-glass-bg, --dial-radius, …).
enum Dial {
    // surfaces
    static let surface        = Color.white.opacity(0.05)
    static let surfaceHover   = Color.white.opacity(0.09)
    static let surfaceActive  = Color.white.opacity(0.13)
    static let stroke         = Color.white.opacity(0.10)
    static let strokeStrong   = Color.white.opacity(0.18)
    static let inset          = Color.black.opacity(0.28)   // wells: tabs, fields, segments
    // text hierarchy
    static let textRoot       = Color(red: 0.957, green: 0.957, blue: 0.965)
    static let textLabel      = Color.white.opacity(0.84)
    static let textSection    = Color.white.opacity(0.42)
    static let textMuted      = Color.white.opacity(0.50)
    // accent — Pinterest's official red
    static let accent         = Color(red: 0.902, green: 0.0, blue: 0.137)          // #E60023
    static let accentDeep     = Color(red: 0.718, green: 0.0, blue: 0.110)          // #B7001C
    static let good           = Color(red: 0.204, green: 0.78, blue: 0.349)         // #34C759
    // metrics
    static let radius: CGFloat = 16
    static let rowHeight: CGFloat = 32
}

// MARK: - folder (collapsible section)

struct DialFolder<Content: View>: View {
    let label: String
    var icon: String = ""              // SF Symbol shown in a small surface chip
    var meta: String = ""
    var startCollapsed = false
    @ViewBuilder let content: () -> Content
    @State private var collapsed: Bool = false

    init(_ label: String, icon: String = "", meta: String = "", startCollapsed: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.icon = icon; self.meta = meta; self.startCollapsed = startCollapsed
        self.content = content
        _collapsed = State(initialValue: startCollapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 10) {
                    if !icon.isEmpty {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Dial.textMuted)
                            .frame(width: 22, height: 22)
                            .background(Dial.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Dial.stroke, lineWidth: 1))
                    }
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Dial.textSection)
                    Spacer()
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Dial.textSection)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Dial.textSection)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                VStack(alignment: .leading, spacing: 9) { content() }
                    .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - slider (label + mono value; track/fill/knob)

struct DialSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Dial.textLabel)
                Spacer()
                Text("\(Int(value))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Dial.textMuted)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let pct = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10)).frame(height: 5)
                    Capsule().fill(Dial.accent).frame(width: max(0, pct * w), height: 5)
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.5), radius: 3.5, y: 2)
                        .offset(x: pct * w - 7)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let p = min(max(0, g.location.x / w), 1)
                            var v = range.lowerBound + p * (range.upperBound - range.lowerBound)
                            v = (v / step).rounded() * step
                            value = min(max(v, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in onCommit() }
                )
            }
            .frame(height: 14)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Off/On segmented toggle

struct DialSegToggle: View {
    @Binding var isOn: Bool
    var onChange: () -> Void = {}

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isOn ? Dial.accent : Dial.surfaceActive)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isOn ? Color.clear : Dial.strokeStrong, lineWidth: 1))
                .frame(width: 36)
                .padding(2)
            HStack(spacing: 0) {
                Text("Off")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isOn ? Dial.textMuted : Dial.textRoot)
                    .frame(width: 38)
                Text("On")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isOn ? .white : Dial.textMuted)
                    .frame(width: 38)
            }
        }
        .frame(width: 80, height: 26)
        .background(Dial.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Dial.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { isOn.toggle() }
            onChange()
        }
    }
}

// MARK: - labelled rows

struct DialRow<Trailing: View>: View {
    let label: String
    var sub: String = ""
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Dial.textLabel)
                    .lineLimit(1).fixedSize()   // never wrap the label vertically
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 10.5)).foregroundStyle(Dial.textSection)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: Dial.rowHeight)
    }
}

// MARK: - buttons

struct DialButtonStyle: ButtonStyle {
    var accent = false
    var ghost = false
    var compact = false   // hugs its label at field height — for buttons beside inputs
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(ghost ? Dial.textMuted : Dial.textRoot)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 33 : nil)
            .padding(.horizontal, compact ? 14 : 0)
            .padding(.vertical, compact ? 0 : 9)
            .background(
                accent ? AnyShapeStyle(LinearGradient(
                              colors: [Color(red: 1.0, green: 0.10, blue: 0.20), Dial.accentDeep],
                              startPoint: .top, endPoint: .bottom))
                       : AnyShapeStyle(Dial.surface),
                in: RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                .stroke(accent ? Color.white.opacity(0.18) : Dial.stroke, lineWidth: 1))
            .shadow(color: accent && !compact ? Dial.accentDeep.opacity(0.3) : .clear, radius: 9, y: 3)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .foregroundStyle(accent ? .white : (ghost ? Dial.textMuted : Dial.textRoot))
    }
}

// MARK: - text field

struct DialFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Dial.textRoot)
            .padding(.horizontal, 10)
            .frame(height: 33)   // matches compact DialButtonStyle beside it
            .background(Dial.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Dial.stroke, lineWidth: 1))
    }
}

// MARK: - provider tabs (Pinterest / iCloud) with sliding pill

struct DialTabs: View {
    @Binding var tab: String            // "pinterest" | "icloud"
    var onChange: (String) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let half = (geo.size.width - 6) / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Dial.surfaceActive)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Dial.strokeStrong, lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .frame(width: half)
                    .offset(x: tab == "icloud" ? half + 0 : 0)
                    .padding(3)
                HStack(spacing: 0) {
                    tabButton("pinterest", label: "Pinterest") { PinterestGlyph() }
                    tabButton("icloud", label: "iCloud") { PhotosGlyph() }
                }
            }
        }
        .frame(height: 34)
        .background(Dial.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Dial.stroke, lineWidth: 1))
    }

    private func tabButton<G: View>(_ id: String, label: String, @ViewBuilder glyph: () -> G) -> some View {
        Button {
            guard tab != id else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = id }
            onChange(id)
        } label: {
            HStack(spacing: 6) {
                glyph().frame(width: 14, height: 14)
                Text(label).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(tab == id ? Dial.textRoot : Dial.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pinterest glyph — a pin, tinted by the tab's foreground style.
struct PinterestGlyph: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(45))
    }
}

/// Apple Photos pinwheel: six rotated petals in the Photos-app palette.
struct PhotosGlyph: View {
    private let petals: [(Color, Double)] = [
        (Color(red: 0.98, green: 0.78, blue: 0.15), 0),
        (Color(red: 0.55, green: 0.78, blue: 0.25), 60),
        (Color(red: 0.16, green: 0.71, blue: 0.96), 120),
        (Color(red: 0.56, green: 0.36, blue: 0.94), 180),
        (Color(red: 0.94, green: 0.31, blue: 0.55), 240),
        (Color(red: 0.95, green: 0.42, blue: 0.23), 300),
    ]
    var body: some View {
        ZStack {
            ForEach(0..<petals.count, id: \.self) { i in
                Ellipse()
                    .fill(petals[i].0.opacity(0.92))
                    .frame(width: 5.4, height: 8.2)
                    .offset(y: -3.4)
                    .rotationEffect(.degrees(petals[i].1))
            }
        }
        .frame(width: 14, height: 14)
    }
}
