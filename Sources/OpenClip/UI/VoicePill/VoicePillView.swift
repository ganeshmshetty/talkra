// VoicePillView.swift
// OpenClip
//
// Compact liquid-glass pill for push-to-talk: waveform only while listening (no live text), a
// spinner and label while working, and 2–4 tappable chips when the agent needs clarification.
import SwiftUI

struct VoicePillView: View {
    @ObservedObject var model: VoicePillModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phaseAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }

    private var isClarify: Bool {
        if case .clarify = model.phase { return true }
        return false
    }

    private var cornerRadius: CGFloat { isClarify ? 16 : 18 }

    var body: some View {
        Group {
            if case .hidden = model.phase {
                EmptyView()
            } else {
                ZStack {
                    // Unanimated copy that reports the size the panel should animate to.
                    phaseContent
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transaction { $0.animation = nil }
                    surface
                }
            }
        }
        // Room for the shadow inside the borderless panel.
        .padding(12)
        // The panel never becomes the active window while it works; keep the glass in its active look.
        .environment(\.controlActiveState, .key)
    }

    @Namespace private var glassNamespace

    private var usesLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return LayeredGlassBackground.usesLiquidGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        return false
    }

    /// One persistent glass shape that fills whatever size the panel is animating through.
    @ViewBuilder
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), usesLiquidGlass {
            // Glass goes on the content itself after layout, inside a container, so the system owns one
            // sampling region and keeps the same glass across state changes.
            GlassEffectContainer {
                phaseContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular, in: shape)
                    .glassEffectID("pill", in: glassNamespace)
            }
            .contentShape(shape)
            .shadow(color: Color.black.opacity(0.18), radius: 8)
            .animation(phaseAnimation, value: VoicePillModel.animationKey(of: model.phase))
        } else {
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LayeredGlassBackground(cornerRadius: cornerRadius, colorScheme: colorScheme))
                .clipShape(shape)
                .overlay(LayeredGlassBorder(cornerRadius: cornerRadius, colorScheme: colorScheme))
                .contentShape(shape)
                .shadow(color: Color.black.opacity(0.18), radius: 8)
                .animation(phaseAnimation, value: VoicePillModel.animationKey(of: model.phase))
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(_, let levels):
            pillSized { listeningContent(levels: levels) }
                .transition(.opacity)
        case .working(let label):
            pillSized { workingContent(label: label) }
                .transition(.opacity)
        case .notice(let text, let symbol):
            pillSized { noticeContent(text: text, symbol: symbol) }
                .transition(.opacity)
        case .message(let text, let isError):
            pillSized { messageContent(text: text, isError: isError) }
                .transition(.opacity)
        case .clarify(let question, let options):
            clarifyContent(question: question, options: options)
                .padding(12)
                .padding(.trailing, 18)
                .frame(minWidth: 120, maxWidth: 420, alignment: .leading)
                .overlay(alignment: .topTrailing) { closeButton }
                .transition(.opacity)
        }
    }

    private func pillSized<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .frame(minWidth: 64, maxWidth: 420)
            .frame(height: 36)
    }

    private func listeningContent(levels: [Float]) -> some View {
        WaveformView(levels: levels)
            .frame(width: 44, height: 18)
    }

    private func workingContent(label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func noticeContent(text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func messageContent(text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isError ? .orange : .green)
            Text(text)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func clarifyContent(question: String, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            chipsView(options: options)
        }
    }

    private func chipsView(options: [String]) -> some View {
        ChipFlowLayout(spacing: 8, rowSpacing: 6, maxWidth: 420 - 24) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                chipButton(option: option)
            }
        }
    }

    private var closeButton: some View {
        Button {
            model.onClose?()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.secondary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close"))
        .keyboardShortcut(.cancelAction)
    }

    private func chipButton(option: String) -> some View {
        Button {
            model.onChipSelected?(option)
        } label: {
            Text(option)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps chips onto as many rows as fit in `maxWidth`. Its size depends only on its content and
/// that limit, so measuring the pill and laying it out later always agree.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat
    var maxWidth: CGFloat

    private func rows(_ subviews: Subviews, limit: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            let width = subviews[index].sizeThatFits(.unspecified).width
            let needed = rows[rows.count - 1].isEmpty ? width : used + spacing + width
            if needed > limit, !rows[rows.count - 1].isEmpty {
                rows.append([index])
                used = width
            } else {
                rows[rows.count - 1].append(index)
                used = needed
            }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        let laid = rows(subviews, limit: limit)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in laid {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            width = max(width, sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)))
            height += (sizes.map(\.height).max() ?? 0)
        }
        height += rowSpacing * CGFloat(max(0, laid.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, limit: min(bounds.width, maxWidth)) {
            var x = bounds.minX
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }
}

struct WaveformView: View {
    let levels: [Float]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayedLevels: [Float] {
        let maxBars = 12
        let recent = Array(levels.suffix(maxBars))
        if recent.count < maxBars {
            return Array(repeating: Float(0), count: maxBars - recent.count) + recent
        }
        return recent
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { index in
                let level = displayedLevels[index]
                let clamped = max(0, min(level, 1))
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 2.5, height: CGFloat(3 + clamped * 15))
            }
        }
        .frame(width: 44, height: 18)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: displayedLevels)
    }
}

#Preview {
    VStack(spacing: 20) {
        VoicePillView(model: previewModel(phase: .listening(
            transcript: "Translate this to French",
            levels: [0.2, 0.5, 0.8, 0.3, 0.7, 1.0, 0.6, 0.4, 0.9, 0.5, 0.2, 0.8]
        )))

        VoicePillView(model: previewModel(phase: .working(label: "Thinking…")))

        VoicePillView(model: previewModel(phase: .clarify(
            question: "Which language?",
            options: ["French", "Spanish", "German", "Japanese"]
        )))
    }
    .padding(40)
}

@MainActor
private func previewModel(phase: VoicePillModel.Phase) -> VoicePillModel {
    let model = VoicePillModel()
    model.phase = phase
    return model
}
