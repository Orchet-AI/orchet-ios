import SwiftUI

/// Streaming-voice mic affordance for the chat composer. Mirrors the
/// 36 pt round shape used by `ChatComposerTrailingButton` so the
/// composer chrome looks identical regardless of which voice backend
/// is mounted.
///
/// Semantics:
/// - Tap when `.idle`  → start streaming session (`viewModel.start()`).
/// - Tap when `.connected` → end session (`viewModel.stop()`).
/// - Tap when `.starting` → ignored (debounced; the spinner already
///                          conveys progress).
struct StreamingVoiceButton: View {
    @ObservedObject var viewModel: StreamingVoiceViewModel

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                Circle()
                    .fill(fillColor)
                    .frame(width: 36, height: 36)
                Group {
                    switch viewModel.uiState {
                    case .starting, .ending:
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    default:
                        Image(systemName: glyph)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private func handleTap() {
        switch viewModel.uiState {
        case .idle, .error:
            Task { await viewModel.start() }
        case .connected:
            Task { await viewModel.stop() }
        case .starting, .ending:
            break
        }
    }

    private var fillColor: Color {
        switch viewModel.uiState {
        case .connected: return LumoColors.cyanDeep
        case .error: return LumoColors.warning
        default: return LumoColors.cyan
        }
    }

    private var glyph: String {
        switch viewModel.uiState {
        case .connected: return "stop.fill"
        case .error: return "exclamationmark.triangle.fill"
        default: return "waveform.circle.fill"
        }
    }

    private var accessibilityID: String {
        switch viewModel.uiState {
        case .idle, .error: return "chat.composer.streamingMic"
        case .connected: return "chat.composer.streamingActive"
        case .starting: return "chat.composer.streamingConnecting"
        case .ending: return "chat.composer.streamingEnding"
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.uiState {
        case .idle: return "Start streaming voice"
        case .starting: return "Connecting to streaming voice"
        case .connected: return "Streaming voice connected — tap to end"
        case .ending: return "Ending streaming voice"
        case .error: return "Streaming voice error — tap to retry"
        }
    }
}
