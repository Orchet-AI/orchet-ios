import SwiftUI

/// Card view for the `GroceryCartCard` composed-UI component.
/// Renders an editable item list (stepper +/− with auto-remove at
/// quantity 0), live-computed subtotal/taxes/delivery/total, and a
/// Place-order button. Mirrors the web `<GroceryCartCard>`.
struct GroceryCartCardView: View {
    let payload: GroceryCartPayload
    let onPlaceOrder: ([GroceryOrderItem]) -> Void

    @State private var quantities: [String: Double]

    init(payload: GroceryCartPayload, onPlaceOrder: @escaping ([GroceryOrderItem]) -> Void) {
        self.payload = payload
        self.onPlaceOrder = onPlaceOrder
        var seeded: [String: Double] = [:]
        for item in payload.items {
            seeded[item.id] = item.quantity ?? 1
        }
        self._quantities = State(initialValue: seeded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.md) {
            header
            itemList
            Divider()
            totalsBlock
            if payload.delivery_window_start != nil || payload.delivery_window_end != nil {
                deliveryWindowRow
            }
            placeOrderButton
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
        .accessibilityIdentifier("composed.grocery.\(payload.provider)")
    }

    private var header: some View {
        HStack {
            Text(payload.provider.uppercased())
                .font(LumoFonts.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(LumoColors.labelSecondary)
            Spacer()
        }
    }

    private var itemList: some View {
        VStack(spacing: LumoSpacing.xs) {
            ForEach(visibleItems, id: \.id) { item in
                itemRow(item)
            }
        }
    }

    private var visibleItems: [GroceryItem] {
        payload.items.filter { (quantities[$0.id] ?? 0) > 0 }
    }

    private func itemRow(_ item: GroceryItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? item.id)
                    .font(LumoFonts.callout)
                    .foregroundStyle(LumoColors.label)
                    .lineLimit(2)
                if let price = item.price {
                    Text("\(currencySymbol(for: payload.currency))\(formatNumber(price))")
                        .font(LumoFonts.caption)
                        .foregroundStyle(LumoColors.labelSecondary)
                }
            }
            Spacer()
            stepper(for: item)
        }
    }

    private func stepper(for item: GroceryItem) -> some View {
        let qty = quantities[item.id] ?? 0
        return HStack(spacing: LumoSpacing.xs) {
            Button {
                let next = max(0, qty - 1)
                if next == 0 {
                    quantities.removeValue(forKey: item.id)
                } else {
                    quantities[item.id] = next
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumoColors.label)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(LumoColors.surfaceElevated))
            }
            .accessibilityIdentifier("composed.grocery.minus.\(item.id)")

            Text(formatNumber(qty))
                .font(LumoFonts.callout)
                .foregroundStyle(LumoColors.label)
                .frame(minWidth: 18)

            Button {
                quantities[item.id] = qty + 1
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumoColors.label)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(LumoColors.surfaceElevated))
            }
            .accessibilityIdentifier("composed.grocery.plus.\(item.id)")
        }
    }

    private var totalsBlock: some View {
        VStack(spacing: 4) {
            if let subtotal = computedSubtotal {
                totalsLine("Subtotal", value: subtotal)
            }
            if let taxes = payload.taxes, taxes > 0 {
                totalsLine("Taxes", value: taxes)
            }
            if let fee = payload.delivery_fee, fee > 0 {
                totalsLine("Delivery", value: fee)
            }
            totalsLine("Total", value: computedTotal, emphasised: true)
        }
    }

    private func totalsLine(_ label: String, value: Double, emphasised: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasised ? LumoFonts.bodyEmphasized : LumoFonts.callout)
                .foregroundStyle(emphasised ? LumoColors.label : LumoColors.labelSecondary)
            Spacer()
            Text("\(currencySymbol(for: payload.currency))\(formatNumber(value))")
                .font(emphasised ? LumoFonts.bodyEmphasized : LumoFonts.callout)
                .foregroundStyle(LumoColors.label)
        }
    }

    private var deliveryWindowRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundStyle(LumoColors.labelTertiary)
            Text(deliveryWindowLabel())
                .font(LumoFonts.callout)
                .foregroundStyle(LumoColors.labelSecondary)
        }
    }

    private var placeOrderButton: some View {
        let total = computedTotal
        let label = "Place order · \(currencySymbol(for: payload.currency))\(formatNumber(total))"
        return Button {
            let mutated = visibleItems.map { GroceryOrderItem(id: $0.id, quantity: quantities[$0.id] ?? 0) }
            onPlaceOrder(mutated)
        } label: {
            Text(label)
                .font(LumoFonts.bodyEmphasized)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LumoSpacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                        .fill(visibleItems.isEmpty ? LumoColors.labelTertiary : LumoColors.cyan)
                )
        }
        .disabled(visibleItems.isEmpty)
        .accessibilityIdentifier("composed.grocery.placeOrder")
    }

    private var computedSubtotal: Double? {
        let sum = payload.items.reduce(0.0) { acc, item in
            let qty = quantities[item.id] ?? 0
            let price = item.price ?? 0
            return acc + (qty * price)
        }
        return sum > 0 ? sum : payload.subtotal
    }

    private var computedTotal: Double {
        let sub = computedSubtotal ?? payload.subtotal ?? 0
        let tax = payload.taxes ?? 0
        let fee = payload.delivery_fee ?? 0
        let derived = sub + tax + fee
        return derived > 0 ? derived : payload.total
    }

    private func deliveryWindowLabel() -> String {
        switch (payload.delivery_window_start, payload.delivery_window_end) {
        case (let s?, let e?):
            return "Delivery \(formatTime(s)) – \(formatTime(e))"
        case (let s?, nil):
            return "Delivery from \(formatTime(s))"
        case (nil, let e?):
            return "Delivery by \(formatTime(e))"
        default:
            return ""
        }
    }

    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: iso)
        }()
        guard let date else { return iso }
        let display = DateFormatter()
        display.dateFormat = "h:mm a"
        return display.string(from: date)
    }

    private func formatNumber(_ n: Double) -> String {
        if n.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(n))
        }
        return String(format: "%.2f", n)
    }
}
