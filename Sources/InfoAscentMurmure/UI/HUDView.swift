import SwiftUI

/// The pill that appears while you dictate.
///
/// Deliberately tiny and wordless. It appears next to the caret — over the document you're
/// typing into — so anything larger than a status light is in the way of the thing you're
/// looking at. The transcript is not shown here: it lands in the text field a moment later,
/// and showing it twice means reading it twice.
///
/// Always dark, never themed. It floats over other apps rather than sitting inside one, so
/// it needs to read as a system overlay in both appearances, the way the volume and
/// screenshot HUDs do.
struct HUDView: View {
    @Bindable var controller: DictationController

    /// The whole pill. Sized once here so the panel, the capsule and the bars can't drift
    /// apart.
    static let size = CGSize(width: 62, height: 26)

    var body: some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.82))
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)

            if isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 5) {
                    // Latched hands-free: the key isn't being held, so the pill is the only
                    // thing saying the mic is still open. Red, because it is recording —
                    // that is the one thing red means here.
                    if controller.isLocked {
                        Circle()
                            .fill(.red)
                            .frame(width: 5, height: 5)
                    }
                    Waveform(level: controller.level, isActive: controller.state == .listening)
                }
                .padding(.horizontal, controller.isLocked ? 8 : 12)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .help(helpText)
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    /// The only place the state is spelled out. A tooltip costs nothing when unread.
    private var helpText: String {
        switch controller.state {
        case .error(let message): message
        case .finishing: "Transcribing…"
        default: controller.isLocked ? "Listening — tap the key again to stop" : "Listening…"
        }
    }
}

/// Five bars that ride the input level. Each carries a fixed phase offset so the group
/// ripples instead of pumping in unison.
private struct Waveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = 5
    private static let phases: [Double] = (0..<barCount).map { index in
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(isActive ? 0.95 : 0.4))
                        .frame(width: 2.5, height: height(for: index, at: time))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        let floorHeight: CGFloat = 2.5
        guard isActive else { return floorHeight }

        let phase = Self.phases[index]
        let wave = sin(time * 6.0 + phase * .pi * 2)
        let amplitude = CGFloat(max(0.05, level))
        // The wave rides on top of the level so bars still breathe during quiet passages.
        let scaled = amplitude * (0.55 + 0.45 * CGFloat(wave))
        return floorHeight + max(0, scaled) * 12
    }
}
