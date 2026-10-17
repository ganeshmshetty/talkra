// ResultSurfaceView.swift
// OpenClip
//
// Root view of the result panel: the themed ResultCardView for the current session's payload,
// inside the transparent ring that hosts the panel's drop shadow.
import SwiftUI
import Core

@MainActor
struct ResultSurfaceView: View {
    @ObservedObject var modeStore: PopupModeStore
    let onDismiss: @MainActor () -> Void
    let onCardDrag: @MainActor (ResultCardDragPhase) -> Void
    let onResize: @MainActor (PopupResizeEdge, ResultCardDragPhase) -> Void
    let onPinCard: @MainActor () -> Void
    let onCardEffect: @MainActor (ActionResult) -> Void
    let onFollowUp: @MainActor (String) -> Void
    let onCancelFollowUp: @MainActor () -> Void
    let onContentSizeChange: @MainActor (CGSize) -> Void

    @Setting(SettingKey.popupThemeColor) private var themeColor
    @Environment(\.colorScheme) private var colorScheme

    init(
        modeStore: PopupModeStore,
        settingsStore: SettingsStore = DefaultSettingsStore.shared,
        onDismiss: @escaping @MainActor () -> Void,
        onCardDrag: @escaping @MainActor (ResultCardDragPhase) -> Void,
        onResize: @escaping @MainActor (PopupResizeEdge, ResultCardDragPhase) -> Void,
        onPinCard: @escaping @MainActor () -> Void,
        onCardEffect: @escaping @MainActor (ActionResult) -> Void,
        onFollowUp: @escaping @MainActor (String) -> Void,
        onCancelFollowUp: @escaping @MainActor () -> Void,
        onContentSizeChange: @escaping @MainActor (CGSize) -> Void
    ) {
        self.modeStore = modeStore
        self.onDismiss = onDismiss
        self.onCardDrag = onCardDrag
        self.onResize = onResize
        self.onPinCard = onPinCard
        self.onCardEffect = onCardEffect
        self.onFollowUp = onFollowUp
        self.onCancelFollowUp = onCancelFollowUp
        self.onContentSizeChange = onContentSizeChange
        _themeColor = Setting(SettingKey.popupThemeColor, store: settingsStore)
    }

    private var effectiveColorScheme: ColorScheme {
        PopupThemeModel.effectiveScheme(appearance: themeColor, systemIsDark: colorScheme == .dark)
    }

    private var effectiveTheme: String { PopupThemeModel.glass }

    var body: some View {
        card
            // Must equal PopupMetrics.popupShadowInset, which PopupPanel excludes from hit-testing.
            .padding(PopupMetrics.popupShadowInset)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ResultSurfaceSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(ResultSurfaceSizeKey.self) { size in
                MainActor.assumeIsolated {
                    guard size.width > 0, size.height > 0 else { return }
                    onContentSizeChange(size)
                }
            }
    }

    @ViewBuilder
    private var card: some View {
        if let payload = modeStore.resultCard {
            ResultCardView(
                payload: payload,
                canPaste: modeStore.canPaste,
                maxSize: modeStore.resultCardSize,
                isUserSized: modeStore.isSurfaceUserSized,
                isPinned: modeStore.isCardPinned,
                onExit: onDismiss,
                onPaste: {
                    onCardEffect(payload.file.map { .saveFile($0.url) } ?? .paste(payload.text))
                },
                onCopy: {
                    onCardEffect(payload.file.map { .copyFile($0.url) } ?? .copy(payload.text))
                },
                onSave: {
                    if let file = payload.file { onCardEffect(.saveFile(file.url)) }
                },
                onDrag: onCardDrag,
                onResize: onResize,
                onPin: onPinCard,
                onFollowUp: { instruction in onFollowUp(instruction) },
                onCancelFollowUp: onCancelFollowUp
            )
            .environment(\.colorScheme, effectiveColorScheme)
            .environment(\.popupEffectiveTheme, effectiveTheme)
        }
    }
}

private struct ResultSurfaceSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
