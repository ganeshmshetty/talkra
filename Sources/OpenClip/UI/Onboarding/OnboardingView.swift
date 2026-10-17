// OnboardingView.swift
// OpenClip
//
// Native macOS onboarding flow following System Settings conventions: solid window background,
// hierarchical SF Symbols, flat system inset cards, no web drop-shadows.
import SwiftUI
import AppKit
import Core

public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome = 0
    case permission = 1
    case ai = 2
    case done = 3

    public var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permission: return "Access"
        case .ai: return "AI"
        case .done: return "Try It"
        }
    }
}

// MARK: - Tactile Button Styles

public struct MacPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6.5)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(
                color: Color.accentColor.opacity(configuration.isPressed ? 0.05 : 0.2),
                radius: configuration.isPressed ? 1.5 : 3,
                x: 0,
                y: configuration.isPressed ? 0.5 : 1.5
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

public struct MacSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(.primary.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0.01 : 0.04), radius: 1.5, x: 0, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Onboarding View

@MainActor
public struct OnboardingView: View {
    @ObservedObject private var permissionManager = PermissionManager.shared
    public var onComplete: @MainActor () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var slideEdge: Edge = .trailing
    @State private var hasDetectedSelection = false
    @State private var isSkipHovered = false

    public init(onComplete: @escaping @MainActor () -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            // ── Top Header: Step Indicator ─────────────────────────────
            topBar
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // ── Center Content Area ────────────────────────────────────
            VStack {
                Spacer(minLength: 0)

                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .permission: permissionStep
                    case .ai: aiStep
                    case .done: doneStep
                    }
                }
                .transition(.push(from: slideEdge))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)

            // ── Bottom Navigation Bar ──────────────────────────────────
            bottomBar
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .padding(.top, 12)
        }
        .frame(width: 520, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { permissionManager.startMonitoring() }
        .onDisappear {
            permissionManager.stopMonitoring()
            HotkeyManager.allowsOwnApp = false
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            // Compact Apple-style Progress Track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 3)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: max(8, geo.size.width * CGFloat(step.rawValue + 1) / CGFloat(OnboardingStep.allCases.count)),
                            height: 3
                        )
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 72, height: 8)

            if step != .done {
                Button {
                    completeOnboarding()
                } label: {
                    Text("Skip")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(isSkipHovered ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isSkipHovered = $0 }
            }
        }
    }

    // MARK: - Bottom Navigation Bar

    private var bottomBar: some View {
        HStack {
            if step != .welcome {
                Button {
                    slideEdge = .leading
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("Back")
                    }
                }
                .buttonStyle(MacSecondaryButtonStyle())
            }

            Spacer()

            Button {
                if step == .done {
                    completeOnboarding()
                } else {
                    slideEdge = .trailing
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .done
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(step == .done ? String(localized: "Get Started") : String(localized: "Continue"))
                    Image(systemName: step == .done ? "arrow.right.circle.fill" : "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                }
            }
            .buttonStyle(MacPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func completeOnboarding() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        DefaultSettingsStore.shared.set(.lastRunVersion, value: currentVersion)
        DefaultSettingsStore.shared.set(.lastRunBuild, value: currentBuild)
        DefaultSettingsStore.shared.set(.hasCompletedOnboarding, value: true)
        onComplete()
    }

    // MARK: - Screen 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 42))
                    .foregroundStyle(Color.accentColor)

                Text("Welcome to Talkra")
                    .font(.title2.weight(.bold))

                Text("Select text anywhere, hold ⌥Space, say what you want, then let go.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                examplePhrase("“Make this shorter”", icon: "text.alignleft")
                examplePhrase("“Translate to French”", icon: "character.book.closed.fill")
                examplePhrase("“What is 1250 plus 340?”", icon: "equal.circle.fill")
                examplePhrase("“Count the words”", icon: "number")
            }
            .frame(maxWidth: 320)

            Text("Results replace your selection in place, or appear in a small card you can follow up on.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func examplePhrase(_ text: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Screen 2: Permissions

    private var permissionStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: allPermissionsGranted ? "checkmark.shield.fill" : "hand.raised.square.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 42))
                    .foregroundStyle(allPermissionsGranted ? Color.green : Color.accentColor)

                Text("Three Permissions")
                    .font(.title2.weight(.bold))

                Text("Speech is recognized on your Mac. The microphone is open only while you hold the shortcut.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                permissionRow(
                    icon: "lock.shield", title: "Accessibility",
                    detail: "Read the text you've selected.",
                    granted: permissionManager.isAccessibilityGranted,
                    action: { permissionManager.requestAccessibilityPermission() }
                )
                Divider().padding(.leading, 44)
                permissionRow(
                    icon: "mic", title: "Microphone",
                    detail: "Hear your command.",
                    granted: permissionManager.isMicrophoneGranted,
                    action: { permissionManager.requestMicrophone() }
                )
                Divider().padding(.leading, 44)
                permissionRow(
                    icon: "waveform", title: "Speech Recognition",
                    detail: "Turn your voice into text, on device.",
                    granted: permissionManager.isSpeechGranted,
                    action: { permissionManager.requestSpeech() }
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: allPermissionsGranted)
    }

    private var allPermissionsGranted: Bool {
        permissionManager.isAccessibilityGranted && permissionManager.isMicrophoneGranted && permissionManager.isSpeechGranted
    }

    private func permissionRow(
        icon: String, title: LocalizedStringKey, detail: LocalizedStringKey,
        granted: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel(String(localized: "Granted"))
            } else {
                Button("Allow", action: action)
                    .buttonStyle(MacSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Screen 3: AI

    private var aiStep: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 38))
                    .foregroundStyle(Color.accentColor)

                Text("Pick an AI")
                    .font(.title2.weight(.bold))

                Text("Matching an installed action needs no AI. Anything else is understood by the model you choose.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                providerRow(icon: "cloud", title: "Cloud model", detail: "Best accuracy and speed. Needs an API key.")
                Divider().padding(.leading, 44)
                providerRow(icon: "terminal", title: "AI command line", detail: "Uses a CLI you're already signed into. A few seconds slower.")
                Divider().padding(.leading, 44)
                providerRow(icon: "apple.logo", title: "Apple Intelligence", detail: "Free and offline. Simple commands only; no scripts.")
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Button("Choose in Settings…") {
                SettingsWindowController.show(tab: .ai)
            }
            .buttonStyle(MacSecondaryButtonStyle())
        }
    }

    private func providerRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Screen 4: Try it

    /// Talkra is normally excluded as a voice target; the playground is the one place it isn't.
    private var doneStep: some View {
        doneStepContent
            .onAppear { HotkeyManager.allowsOwnApp = true }
            .onDisappear { HotkeyManager.allowsOwnApp = false }
    }

    private var doneStepContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: "mic.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 38))
                    .foregroundStyle(Color.green)

                Text("Try It Right Now")
                    .font(.title2.weight(.bold))

                Text("Select some of the text below, hold ⌥Space and say “make this uppercase”.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text("Playground — select text:")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }

                SandboxTextView(
                    text: "Our team sync is Friday at 2:30pm. The project budget is 1250 + 340 dollars for the redesign.",
                    onSelection: {
                        if !hasDetectedSelection {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                hasDetectedSelection = true
                            }
                        }
                    }
                )
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hasDetectedSelection ? Color.green.opacity(0.5) : Color.accentColor.opacity(0.35), lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            if hasDetectedSelection {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Selection detected. Now hold ⌥Space and speak.")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.green)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("You can change the push-to-talk shortcut in Settings › General.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
