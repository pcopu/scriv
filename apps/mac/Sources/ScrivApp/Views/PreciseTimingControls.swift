import SwiftUI

/// Text entry keeps invalid drafts intact; the stepper is an explicit 100 ms adjustment.
/// Parsing is bounded before conversion to avoid trapping on nonfinite/oversized input.
enum PreciseTimingInput {
    static func milliseconds(_ text: String, maximum: Int) -> Int? {
        guard let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, seconds >= 0, seconds <= Double(maximum) / 1000 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.3f", Double(milliseconds) / 1000)
    }
}

struct PreciseSecondsField: View {
    var title: String? = nil
    let accessibilityName: String
    @Binding var text: String
    var maximumMs: Int
    var minimumMs = 0
    var identifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title).font(.system(size: 13)) }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    TextField("0.000", text: $text)
                        .font(.system(size: 14)).monospacedDigit()
                        .textFieldStyle(.plain)
                        .accessibilityLabel(accessibilityName + ", seconds")
                        .accessibilityIdentifier(identifier)
                    Stepper("Adjust " + accessibilityName, onIncrement: { adjust(by: 100) }, onDecrement: { adjust(by: -100) })
                        .labelsHidden().controlSize(.mini).fixedSize()
                        .help("Adjust by 0.100 seconds")
                }
                .padding(.horizontal, 10).frame(height: 35)
                .background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ScrivTheme.hairline))
                Text("s").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private func adjust(by amount: Int) {
        let current = PreciseTimingInput.milliseconds(text, maximum: maximumMs) ?? minimumMs
        text = PreciseTimingInput.seconds(min(maximumMs, max(minimumMs, current + amount)))
    }
}

/// Small, real-playhead marker shared by source trimming and manual word timing.
struct TimingPlayhead: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8))
            Rectangle().frame(width: 1)
        }.foregroundStyle(ScrivTheme.accent).accessibilityHidden(true)
    }
}

struct TimingValidationNotice: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text("Timing needs a small fix").font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Your changes are still in this editor. Nothing was applied from this draft.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
    }
}
