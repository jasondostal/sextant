import SwiftUI

/// The few choices worth having. Opened by the gear, closed by its X.
struct SettingsPanel: View {
    @Bindable var model: SkyModel
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { open = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Constellation lines").font(.system(size: 13, weight: .medium))
                Picker("Constellation lines", selection: $model.lineMode) {
                    ForEach(SkyModel.LineMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(lineHint).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Faintest stars").font(.system(size: 13, weight: .medium))
                HStack(spacing: 10) {
                    Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    Slider(value: $model.magOffset, in: SkyModel.magOffsetRange, step: 0.25)
                    Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
                }
                Text(magHint).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Toggle("Ecliptic (the Sun's and planets' path)", isOn: $model.showEcliptic).font(.system(size: 13, weight: .medium))
            Toggle("Night mode (red)", isOn: $model.nightMode).font(.system(size: 13, weight: .medium))
            DisclosureGroup("Credits") { credits }
                .font(.system(size: 13, weight: .medium))
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: 400)
        .background(Color(red: 0.01, green: 0.02, blue: 0.14).opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    /// What the licences ask for (NOTICE.md has the full texts' sources).
    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.notices, id: \.0) { name, line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .semibold))
                    Text(line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.top, 6)
    }

    static let notices: [(String, String)] = [
        ("Astronomy Engine", "Don Cross · MIT License · positions of the Sun, Moon and planets"),
        ("HYG star database v4.4", "David Nash (astronexus.com) · CC BY-SA 4.0 · the stars; Sextant's star file is shared under the same licence"),
        ("Milky Way panorama", "ESO/S. Brunier (eso.org) · CC BY 4.0 · stars removed and reprojected"),
        ("d3-celestial", "Olaf Frohn · BSD 3-Clause · constellation figures and names"),
        ("SatelliteKit", "Gavin Eadie · MIT License · SGP4 orbit propagation"),
        ("CelesTrak", "Dr. T.S. Kelso (celestrak.org) · satellite orbits and catalog"),
    ]

    private var magHint: String {
        let limit = min(8.0, 6.3 + model.magOffset)
        let base = String(format: "Down to magnitude %.1f at full width, deeper as you zoom.", limit)
        return switch model.magOffset {
        case ..<(-0.9): base + " A city sky."
        case ..<0.4: base + " A dark rural sky."
        default: base + " Binocular faint."
        }
    }

    private var lineHint: String {
        switch model.lineMode {
        case .auto: "The constellation you're looking at, or the one around what you've selected."
        case .always: "All figures, faint; the one you're looking at brighter."
        case .never: "No figures, just the stars."
        }
    }
}

/// The gear, top right.
struct SettingsButton: View {
    @Binding var open: Bool

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "gearshape").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
