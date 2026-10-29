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
            Toggle("Night mode (red)", isOn: $model.nightMode).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: 380)
        .background(Color(red: 0.01, green: 0.02, blue: 0.14).opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
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
    }
}
