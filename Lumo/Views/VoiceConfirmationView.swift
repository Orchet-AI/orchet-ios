import SwiftUI

/// Native confirmation sheet rendered when the streaming voice
/// service emits a `voice_show_confirmation` Daily app-message.
/// Mirrors the web modal — title + summary + label/value detail
/// rows + Confirm/Cancel buttons + auto-expire on `expires_at`.
struct VoiceConfirmationView: View {
    let confirmation: VoiceShowConfirmationMessage
    let onAccept: () -> Void
    let onCancel: () -> Void

    @State private var expireTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.lg) {
            VStack(alignment: .leading, spacing: LumoSpacing.xs) {
                Text(confirmation.title)
                    .font(LumoFonts.title)
                    .foregroundStyle(LumoColors.label)
                    .accessibilityIdentifier("voice.confirm.title")
                if let summary = confirmation.summary, !summary.isEmpty {
                    Text(summary)
                        .font(LumoFonts.body)
                        .foregroundStyle(LumoColors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice.confirm.summary")
                }
            }

            if let details = confirmation.details, !details.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(details.enumerated()), id: \.offset) { index, row in
                        HStack {
                            Text(row.label)
                                .font(LumoFonts.callout)
                                .foregroundStyle(LumoColors.labelSecondary)
                            Spacer()
                            Text(row.value)
                                .font(LumoFonts.callout)
                                .foregroundStyle(LumoColors.label)
                        }
                        .padding(.vertical, LumoSpacing.sm)
                        .padding(.horizontal, LumoSpacing.md)
                        if index < details.count - 1 {
                            Divider()
                                .background(LumoColors.separator)
                                .padding(.leading, LumoSpacing.md)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                        .fill(LumoColors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                        .stroke(LumoColors.separator, lineWidth: 1)
                )
            }

            HStack(spacing: LumoSpacing.md) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(LumoFonts.bodyEmphasized)
                        .foregroundStyle(LumoColors.label)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LumoSpacing.sm + 2)
                        .background(
                            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                                .fill(LumoColors.surfaceElevated)
                        )
                }
                .accessibilityIdentifier("voice.confirm.cancel")

                Button(action: onAccept) {
                    Text("Confirm")
                        .font(LumoFonts.bodyEmphasized)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LumoSpacing.sm + 2)
                        .background(
                            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                                .fill(LumoColors.cyan)
                        )
                }
                .accessibilityIdentifier("voice.confirm.confirm")
            }
        }
        .padding(LumoSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LumoColors.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .onAppear {
            scheduleAutoCancel()
        }
        .onDisappear {
            expireTask?.cancel()
            expireTask = nil
        }
    }

    private func scheduleAutoCancel() {
        guard let raw = confirmation.expires_at,
              let expiresAt = parseISO(raw) else { return }
        let interval = expiresAt.timeIntervalSinceNow
        guard interval > 0 else {
            onCancel()
            return
        }
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if !Task.isCancelled {
                onCancel()
            }
        }
        expireTask = task
    }

    private func parseISO(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}
