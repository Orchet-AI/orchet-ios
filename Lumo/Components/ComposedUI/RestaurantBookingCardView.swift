import SwiftUI

/// Card view for the `RestaurantBookingCard` composed-UI component.
/// Renders restaurant name + rating, slot + party size, optional
/// special-request field (when the provider supports it), and a
/// Confirm button. Mirrors the web `<RestaurantBookingCard>`.
struct RestaurantBookingCardView: View {
    let payload: RestaurantBookingPayload
    let onConfirm: (String?) -> Void

    @State private var specialRequest: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.md) {
            header
            metaRow
            if let address = payload.address {
                Text(address)
                    .font(LumoFonts.callout)
                    .foregroundStyle(LumoColors.labelSecondary)
                    .lineLimit(2)
            }
            if payload.special_request_supported == true {
                specialRequestField
            }
            confirmButton
        }
        .padding(LumoSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                .fill(LumoColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                .stroke(LumoColors.separator, lineWidth: 1)
        )
        .accessibilityIdentifier("composed.restaurant.\(payload.restaurant_id ?? payload.restaurant_name)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(payload.restaurant_name)
                    .font(LumoFonts.bodyEmphasized)
                    .foregroundStyle(LumoColors.label)
                Spacer()
                if let rating = payload.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LumoColors.cyan)
                        Text(String(format: "%.1f", rating))
                            .font(LumoFonts.callout)
                            .foregroundStyle(LumoColors.label)
                    }
                }
            }
            if let cuisine = payload.cuisine {
                Text(cuisine)
                    .font(LumoFonts.caption)
                    .foregroundStyle(LumoColors.labelSecondary)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: LumoSpacing.md) {
            metaItem(icon: "clock", text: formatSlot())
            metaItem(icon: "person.2", text: "Party of \(payload.party_size)")
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(LumoColors.labelTertiary)
            Text(text)
                .font(LumoFonts.callout)
                .foregroundStyle(LumoColors.label)
        }
    }

    private var specialRequestField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Special request")
                .font(LumoFonts.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(LumoColors.labelTertiary)
            TextField("Window seat, allergies, …", text: $specialRequest)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("composed.restaurant.specialRequest")
        }
    }

    private var confirmButton: some View {
        Button {
            let trimmed = specialRequest.trimmingCharacters(in: .whitespaces)
            onConfirm(trimmed.isEmpty ? nil : trimmed)
        } label: {
            Text("Confirm reservation")
                .font(LumoFonts.bodyEmphasized)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LumoSpacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                        .fill(LumoColors.cyan)
                )
        }
        .accessibilityIdentifier("composed.restaurant.confirm")
    }

    private func formatSlot() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: payload.slot_start) ?? {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: payload.slot_start)
        }()
        guard let date else { return payload.slot_start }
        let label = DateFormatter()
        label.dateFormat = "EEE h:mm a"
        return label.string(from: date)
    }
}
