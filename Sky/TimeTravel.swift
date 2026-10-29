import SwiftUI

/// What the edge ruler moves.
enum TimeUnit: CaseIterable {
    case day, hour, minute

    var seconds: TimeInterval {
        switch self {
        case .day: 86400
        case .hour: 3600
        case .minute: 60
        }
    }
}

/// Time travel, Star Walk style: tap a field to pick the unit, drag the ruler on
/// the right edge (up = later). The sky keeps running from wherever you leave it.
struct TimeBar: View {
    let model: SkyModel
    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            let d = model.date(at: t.date)
            HStack(spacing: 4) {
                if model.timeTraveling {
                    Button { model.resetTime() } label: {
                        Text("Now").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Self.amber.opacity(0.18)))
                            .foregroundStyle(Self.amber)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
                field(format(d, "EEE MMM d"), .day)
                field(format(d, "h"), .hour)
                Text(":").foregroundStyle(.white.opacity(0.6))
                field(format(d, "mm"), .minute)
                Text(format(d, "a")).foregroundStyle(.white.opacity(0.75)).padding(.leading, 2)
                if model.timeTraveling {
                    Text(offsetText(d.timeIntervalSince(t.date)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Self.amber.opacity(0.85)).padding(.leading, 6)
                }
                Button { model.timeBarOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .font(.system(size: 17, weight: .medium).monospacedDigit())
            .padding(.horizontal, 12).padding(.vertical, -2)
            .background(Capsule().fill(Color(red: 0.05, green: 0.09, blue: 0.20).opacity(0.82)))
            .overlay(Capsule().stroke(.white.opacity(0.18)))
        }
    }

    private func field(_ text: String, _ unit: TimeUnit) -> some View {
        Button { model.timeUnit = unit } label: {
            Text(text)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(model.timeUnit == unit ? Color(red: 0.35, green: 0.45, blue: 0.75).opacity(0.7) : .clear))
                .foregroundStyle(.white)
                .padding(.vertical, 8)              // a fingertip-sized target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// "+8 h 37 m", "−2 d 3 h"
    private func offsetText(_ s: TimeInterval) -> String {
        let m = Int((abs(s) / 60).rounded())
        let (d, h, mm) = (m / 1440, m % 1440 / 60, m % 60)
        let body = d > 0 ? "\(d) d \(h) h" : h > 0 ? "\(h) h \(mm) m" : "\(mm) m"
        return (s < 0 ? "−" : "+") + body
    }
}

/// The tick strip on the right edge. Ticks slide with the finger; every 20 pt
/// is one unit (Star Walk's is about 19). Minutes and hours scrub smoothly,
/// days step whole days so the hour of night stays put.
struct TimeRuler: View {
    let model: SkyModel
    static let spacing: CGFloat = 20
    @State private var last: CGFloat = 0
    @State private var travelled: CGFloat = 0
    @State private var pendingDays: Double = 0

    var body: some View {
        Canvas { gc, size in
            let first = Int(floor(-travelled / Self.spacing)) - 1
            let count = Int(size.height / Self.spacing) + 3
            for k in first..<(first + count) {
                let y = CGFloat(k) * Self.spacing + travelled
                guard y >= 0, y <= size.height else { continue }
                // fade toward the ends
                let fade = 1 - abs(y - size.height / 2) / (size.height / 2)
                let long = k % 5 == 0
                var p = Path()
                p.move(to: CGPoint(x: size.width - (long ? 22 : 12), y: y))
                p.addLine(to: CGPoint(x: size.width - 2, y: y))
                gc.stroke(p, with: .color(.white.opacity(0.75 * fade)), lineWidth: long ? 1.5 : 1)
            }
            // the reading line
            var mid = Path()
            mid.move(to: CGPoint(x: size.width - 30, y: size.height / 2))
            mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            gc.stroke(mid, with: .color(Color(red: 1.0, green: 0.72, blue: 0.25)), lineWidth: 2)
        }
        .frame(width: 48)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let dy = g.translation.height - last
                    last = g.translation.height
                    travelled += dy
                    let units = -Double(dy / Self.spacing)        // up = later
                    if model.timeUnit == .day {
                        pendingDays += units
                        let whole = pendingDays.rounded(.towardZero)
                        if whole != 0 {
                            model.shiftDays(Int(whole))
                            pendingDays -= whole
                        }
                    } else {
                        model.shiftTime(by: units * model.timeUnit.seconds)
                    }
                }
                .onEnded { _ in
                    last = 0
                    pendingDays = 0
                }
        )
    }
}
