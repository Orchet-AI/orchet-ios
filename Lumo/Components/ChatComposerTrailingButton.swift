import SwiftUI

/// Single-button trailing affordance for the chat composer.
///
/// Mirrors the web `VoiceControlPanel` (orchet-web PR #23) — one
/// round button whose face encodes the entire voice subsystem
/// state. Six modes total (web's five voice states + a send-mode
/// when the composer has text):
///
///   • `.send`            — composer has text; tap = submit. The
///                          one non-voice mode; preserved from the
///                          prior 4-mode design.
///   • `.idle`            — voice ready, mic icon. Tap = start.
///   • `.listening`       — mic open, accent fill + ping ring.
///                          Tap = stop. Long-press release also
///                          stops (push-to-talk).
///   • `.thinking`        — STT done, waiting on the assistant.
///                          Spinner, disabled (no tap target).
///   • `.speaking`        — TTS playing back, emerald fill + speaker
///                          icon. Tap = barge-in. The web parity
///                          contract: never let a user be locked
///                          out of interrupting Orchet.
///   • `.error`           — voice error surfaced, red border. Tap =
///                          retry.
///
/// State derivation (in `Mode.from`) is a pure helper so the
/// truth table is directly unit-testable without rendering the
/// view. Composer text wins over voice state ONLY when no voice
/// activity is in flight — once the mic is open or Orchet is
/// speaking, the user can't accidentally hit "send".
struct ChatComposerTrailingButton: View {
    enum Mode: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case error
        case send

        /// Pure mode-pick from the three inputs that matter:
        /// composer text, mic state, and the assistant-voice phase.
        ///
        /// Precedence (highest wins):
        ///   1. agent-speaking phase → `.speaking` (barge-in stays
        ///      reachable even if the user starts typing)
        ///   2. thinking phase → `.thinking` (disabled)
        ///   3. error state → `.error`
        ///   4. listening → `.listening`
        ///   5. non-empty composer → `.send`
        ///   6. default → `.idle`
        static func from(
            input: String,
            isListening: Bool,
            phase: VoiceModeMachinePhase = .listening,
            isVoiceError: Bool = false,
            isThinking: Bool = false
        ) -> Mode {
            if phase == .agentSpeaking || phase == .postSpeakingGuard {
                return .speaking
            }
            if isThinking || phase == .agentThinking {
                return .thinking
            }
            if isVoiceError {
                return .error
            }
            if isListening { return .listening }
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? .idle : .send
        }

        enum TapAction: Equatable {
            case startVoice
            case stopVoice
            case sendMessage
            case stopSpeaking
            case retryVoice
            case noop
        }

        /// Canonical tap intent for the parent view. Keeping this
        /// beside the mode-pick prevents the visual state and tap
        /// wiring from drifting.
        var tapAction: TapAction {
            switch self {
            case .idle: return .startVoice
            case .listening: return .stopVoice
            case .send: return .sendMessage
            case .speaking: return .stopSpeaking
            case .error: return .retryVoice
            case .thinking: return .noop
            }
        }

        var systemImage: String {
            switch self {
            case .idle: return "mic.fill"
            case .listening: return "waveform"
            case .send: return "paperplane.fill"
            case .speaking: return "speaker.wave.2.fill"
            case .error: return "exclamationmark.triangle.fill"
            case .thinking: return "ellipsis"  // placeholder; the
                // render path swaps in a ProgressView spinner
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: return "Tap to talk"
            case .listening: return "Listening — tap to stop"
            case .send: return "Send message"
            case .speaking: return "Speaking — tap to interrupt"
            case .error: return "Something broke — tap to retry"
            case .thinking: return "Thinking…"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .idle: return "chat.composer.mic"
            case .listening: return "chat.composer.listening"
            case .send: return "chat.send"
            case .speaking: return "chat.composer.bargeIn"
            case .error: return "chat.composer.error"
            case .thinking: return "chat.composer.thinking"
            }
        }

        /// Disabled tap target. `.thinking` is the only mode where
        /// the button intentionally rejects input — a spinner is
        /// informational only and stealing the next tap would create
        /// a race with the assistant turn finishing.
        var blocksTap: Bool { self == .thinking }

        /// Long-press push-to-talk semantics apply to `.idle` only.
        /// Listening already has tap-to-stop. Speaking has tap-to-
        /// interrupt. Send / error / thinking explicitly don't
        /// support long-press.
        var allowsLongPressPTT: Bool { self == .idle }
    }

    let mode: Mode
    let isDisabled: Bool
    let onTap: () -> Void
    let onLongPressBegan: () -> Void
    let onLongPressEnded: () -> Void

    @State private var pulse = false
    @State private var isHolding = false

    var body: some View {
        ZStack {
            // Ping ring on listening — drawn behind the fill so it
            // expands outward without warping the button itself.
            if mode == .listening {
                Circle()
                    .stroke(LumoColors.cyan.opacity(0.4), lineWidth: 2)
                    .frame(width: 36, height: 36)
                    .scaleEffect(pulse ? 1.5 : 1.0)
                    .opacity(pulse ? 0.0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.1).repeatForever(autoreverses: false),
                        value: pulse
                    )
            }
            Circle()
                .fill(buttonFill)
                .frame(width: 36, height: 36)
                .overlay(buttonGlyph)
                .overlay(
                    Circle()
                        .stroke(borderColor, lineWidth: borderWidth)
                )
                .scaleEffect(isHolding ? 1.08 : 1.0)
                .animation(LumoAnimation.quick, value: isHolding)
        }
        .contentShape(Rectangle())
        .frame(width: 44, height: 44)
        .gesture(
            LongPressGesture(minimumDuration: 0.18)
                .onChanged { _ in
                    guard !isDisabled, !mode.blocksTap, mode.allowsLongPressPTT
                    else { return }
                    if !isHolding {
                        isHolding = true
                        onLongPressBegan()
                    }
                }
                .onEnded { _ in
                    if isHolding {
                        isHolding = false
                        onLongPressEnded()
                    }
                }
                .simultaneously(
                    with: TapGesture().onEnded {
                        guard !isDisabled, !mode.blocksTap, !isHolding else { return }
                        onTap()
                    }
                )
        )
        .opacity(isDisabled ? 0.5 : 1)
        .accessibilityLabel(Text(mode.accessibilityLabel))
        .accessibilityIdentifier(mode.accessibilityIdentifier)
        .accessibilityAddTraits(.isButton)
        .onAppear {
            if mode == .listening { pulse = true }
        }
        .onChange(of: mode) { _, newValue in
            pulse = newValue == .listening
        }
    }

    @ViewBuilder
    private var buttonGlyph: some View {
        if mode == .thinking {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(0.7)
        } else {
            Image(systemName: mode.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(glyphColor)
        }
    }

    private var buttonFill: Color {
        if isDisabled { return LumoColors.labelTertiary }
        switch mode {
        case .listening: return LumoColors.cyan
        case .send: return LumoColors.cyan
        case .speaking: return LumoColors.success
        case .thinking: return LumoColors.surfaceElevated
        case .error: return LumoColors.warning.opacity(0.15)
        case .idle: return LumoColors.surfaceElevated
        }
    }

    private var glyphColor: Color {
        switch mode {
        case .listening, .send, .speaking: return .white
        case .thinking: return LumoColors.labelSecondary
        case .error: return LumoColors.warning
        case .idle: return LumoColors.label
        }
    }

    private var borderColor: Color {
        switch mode {
        case .error: return LumoColors.warning.opacity(0.5)
        case .idle: return LumoColors.separator
        default: return .clear
        }
    }

    private var borderWidth: CGFloat {
        switch mode {
        case .error, .idle: return 1
        default: return 0
        }
    }
}
