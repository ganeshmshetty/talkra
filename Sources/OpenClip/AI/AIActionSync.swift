// AIActionSync.swift
// OpenClip
//
// Mirrors AIServiceManager presets as individual `AIAction`s in the ActionCoordinator, so each
// preset is a voice-matchable action and a Preferences → Actions row. Standalone placement survives
// reconciliation; the rest stay under `builtin.aiTools`.
import Foundation
import Core

@MainActor
public final class AIActionSync {
    public static let shared = AIActionSync()

    private let coordinator = ActionCoordinator.shared
    /// Registered preset ids in registration order; sets the AI actions' catalog position.
    private var registeredOrder: [String] = []
    private var lastFingerprint: [String] = []
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .aiActionPresetsDidChange,
            object: AIServiceManager.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }
        sync()
    }

    /// No-op when nothing changed, so it is safe to call from any surface.
    public func sync() {
        let presets = AIServiceManager.shared.presets
        let fingerprint = presets.map { "\($0.id)|\($0.title)|\($0.prompt)|\($0.isEnabled)" }
        guard fingerprint != lastFingerprint else { return }

        let currentOrder = presets.map { AIAction(presetID: $0.id, title: $0.title).id }

        if currentOrder != registeredOrder {
            // Reordered or added/removed: replace atomically so the catalog follows without cascading notifications.
            let newAIActions = presets.map { AIAction(presetID: $0.id, title: $0.title) }
            coordinator.replaceActions(
                matching: { ActionIdentity.isAIPreset($0) },
                with: newAIActions
            )
        } else {
            // Same order: an in-place refresh leaves the catalog undisturbed.
            for preset in presets {
                coordinator.register(action: AIAction(presetID: preset.id, title: preset.title))
            }
        }

        registeredOrder = currentOrder
        lastFingerprint = fingerprint
    }
}
