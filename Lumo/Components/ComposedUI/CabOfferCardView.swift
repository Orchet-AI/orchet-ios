import SwiftUI

/// Card view for the `CabOfferCard` composed-UI component. Renders
/// provider header (with surge / GST chip when applicable),
/// pickup/dropoff addresses, tier list (selectable), and a Book
/// button. Mirrors the web `<CabOfferCard>` component shipped on
/// 2026-05-14.
struct CabOfferCardView: View {
    let payload: CabOfferPayload
    let onBook: (String) -> Void

    @State private var selectedTier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.md) {
            header
            if payload.pickup?.address != nil || payload.dropoff?.address != nil {
                addressBlock
            }
            tierList
            bookButton
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
        .accessibilityIdentifier("composed.cab.\(payload.provider)")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.provider.uppercased())
                    .font(LumoFonts.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(LumoColors.labelSecondary)
                if let eta = payload.eta_minutes {
                    Text("\(Int(eta.rounded())) min away")
                        .font(LumoFonts.bodyEmphasized)
                        .foregroundStyle(LumoColors.label)
                }
            }
            Spacer()
            if payload.region == "US",
               let surge = payload.surge_multiplier, surge > 1 {
                surgeBadge(surge)
            }
            if payload.region == "IN" {
                gstChip
            }
        }
    }

    private func surgeBadge(_ multiplier: Double) -> some View {
        Text(String(format: "%.1f× surge", multiplier))
            .font(LumoFonts.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(LumoColors.warning)
            .padding(.horizontal, LumoSpacing.sm)
            .padding(.vertical, 4)
            .background(Capsule().fill(LumoColors.warning.opacity(0.12)))
            .accessibilityIdentifier("composed.cab.surge")
    }

    private var gstChip: some View {
        Text("incl. GST")
            .font(LumoFonts.caption)
            .foregroundStyle(LumoColors.labelSecondary)
            .padding(.horizontal, LumoSpacing.sm)
            .padding(.vertical, 4)
            .background(Capsule().fill(LumoColors.surfaceElevated))
            .accessibilityIdentifier("composed.cab.gst")
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.xs) {
            if let pickup = payload.pickup?.address {
                addressRow(icon: "circle", label: pickup)
            }
            if let dropoff = payload.dropoff?.address {
                addressRow(icon: "mappin.and.ellipse", label: dropoff)
            }
        }
    }

    private func addressRow(icon: String, label: String) -> some View {
        HStack(alignment: .top, spacing: LumoSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(LumoColors.labelTertiary)
                .frame(width: 18)
            Text(label)
                .font(LumoFonts.callout)
                .foregroundStyle(LumoColors.label)
                .lineLimit(2)
        }
    }

    private var tierList: some View {
        VStack(spacing: LumoSpacing.xs) {
            ForEach(payload.options) { option in
                tierRow(option)
            }
        }
    }

    private func tierRow(_ option: CabOption) -> some View {
        let isSelected = selectedTier == option.tier_name
        return Button {
            selectedTier = option.tier_name
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.tier_name ?? "Tier")
                        .font(LumoFonts.bodyEmphasized)
                        .foregroundStyle(LumoColors.label)
                    if let capacity = option.capacity {
                        Text("Seats \(capacity)")
                            .font(LumoFonts.caption)
                            .foregroundStyle(LumoColors.labelSecondary)
                    }
                }
                Spacer()
                if let price = option.price {
                    Text(formatPrice(price))
                        .font(LumoFonts.bodyEmphasized)
                        .foregroundStyle(LumoColors.label)
                }
            }
            .padding(.horizontal, LumoSpacing.md)
            .padding(.vertical, LumoSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: LumoRadius.sm, style: .continuous)
                    .fill(isSelected ? LumoColors.cyan.opacity(0.12) : LumoColors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LumoRadius.sm, style: .continuous)
                    .stroke(isSelected ? LumoColors.cyan : LumoColors.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composed.cab.tier.\(option.tier_name ?? "unknown")")
    }

    private var bookButton: some View {
        Button {
            if let tier = effectiveTier {
                onBook(tier)
            }
        } label: {
            Text(effectiveTier.map { "Book \($0)" } ?? "Select a tier")
                .font(LumoFonts.bodyEmphasized)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LumoSpacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                        .fill(effectiveTier == nil ? LumoColors.labelTertiary : LumoColors.cyan)
                )
        }
        .disabled(effectiveTier == nil)
        .accessibilityIdentifier("composed.cab.book")
    }

    private var effectiveTier: String? {
        if let selected = selectedTier { return selected }
        return payload.options.first?.tier_name
    }

    private func formatPrice(_ price: Double) -> String {
        let symbol = currencySymbol(for: payload.currency ?? "")
        if price.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(symbol)\(Int(price))"
        }
        return String(format: "%@%.2f", symbol, price)
    }
}

func currencySymbol(for currency: String) -> String {
    switch currency.uppercased() {
    case "USD": return "$"
    case "INR": return "₹"
    case "GBP": return "£"
    case "EUR": return "€"
    case "AED": return "AED "
    default: return currency.isEmpty ? "" : "\(currency) "
    }
}
