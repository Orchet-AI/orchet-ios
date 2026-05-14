import SwiftUI

/// iOS /cost surface. Mirrors `apps/web/app/settings/cost/page.tsx` —
/// budget caps + today + month totals + per-agent breakdown +
/// recent events. Pushed from Settings via DrawerDestination.
struct CostView: View {
    @StateObject private var viewModel: CostScreenViewModel

    init(viewModel: CostScreenViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, LumoSpacing.md)
                .padding(.vertical, LumoSpacing.md)
        }
        .background(LumoColors.background.ignoresSafeArea())
        .navigationTitle("Cost")
        .navigationBarTitleDisplayMode(.large)
        .task { await viewModel.loadIfNeeded() }
        .refreshable { await viewModel.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            skeleton
        case .loaded(let dashboard):
            VStack(alignment: .leading, spacing: LumoSpacing.lg) {
                metricsRow(dashboard)
                budgetCapsSection(dashboard)
                if !dashboard.agents.isEmpty {
                    topAgentsSection(dashboard)
                }
                if !dashboard.recent.isEmpty {
                    recentSection(dashboard)
                }
            }
        case .error(let message):
            errorState(message)
        }
    }

    // MARK: - Sections

    private func metricsRow(_ dashboard: UserCostDashboard) -> some View {
        HStack(alignment: .top, spacing: LumoSpacing.md) {
            metricCard("TODAY", value: formatUSD(dashboard.today.costUsdTotal), sub: capLabel(dashboard.budget.dailyCapUsd, soft: dashboard.budget.softCap))
            metricCard("THIS MONTH", value: formatUSD(dashboard.month.costUsdTotal), sub: capLabel(dashboard.budget.monthlyCapUsd, soft: dashboard.budget.softCap))
            metricCard("TIER", value: dashboard.budget.tier.capitalized, sub: dashboard.budget.softCap ? "Soft cap" : "Hard cap")
        }
    }

    private func metricCard(_ label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(LumoFonts.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(LumoColors.labelTertiary)
            Text(value)
                .font(LumoFonts.title)
                .foregroundStyle(LumoColors.label)
            Text(sub)
                .font(LumoFonts.caption)
                .foregroundStyle(LumoColors.labelSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LumoSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                .fill(LumoColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                .stroke(LumoColors.separator, lineWidth: 1)
        )
    }

    private func budgetCapsSection(_ dashboard: UserCostDashboard) -> some View {
        VStack(alignment: .leading, spacing: LumoSpacing.md) {
            HStack {
                Text("BUDGET CAPS")
                    .font(LumoFonts.caption.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(LumoColors.labelTertiary)
                Spacer()
                Text("Source: \(dashboard.today.source)")
                    .font(LumoFonts.caption)
                    .foregroundStyle(LumoColors.labelTertiary)
            }
            usageBar(label: "Daily", spent: dashboard.today.costUsdTotal, cap: dashboard.budget.dailyCapUsd)
            usageBar(label: "Monthly", spent: dashboard.month.costUsdTotal, cap: dashboard.budget.monthlyCapUsd)
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
    }

    private func usageBar(label: String, spent: Double, cap: Double?) -> some View {
        let pct = usagePercent(spent: spent, cap: cap)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(LumoFonts.callout)
                    .foregroundStyle(LumoColors.label)
                Spacer()
                Text("\(formatUSD(spent))\(cap.map { " / \(formatUSD($0))" } ?? "")")
                    .font(LumoFonts.callout)
                    .foregroundStyle(LumoColors.labelSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LumoColors.surfaceElevated)
                        .frame(height: 8)
                    Capsule()
                        .fill(barColor(pct: pct))
                        .frame(width: max(0, min(1, pct)) * proxy.size.width, height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private func topAgentsSection(_ dashboard: UserCostDashboard) -> some View {
        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
            Text("TOP AGENTS")
                .font(LumoFonts.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(LumoColors.labelTertiary)
            VStack(spacing: LumoSpacing.xs) {
                ForEach(dashboard.agents.prefix(8)) { agent in
                    HStack {
                        Text(agent.agentId)
                            .font(LumoFonts.callout)
                            .foregroundStyle(LumoColors.label)
                        Spacer()
                        Text("\(agent.invocations) call\(agent.invocations == 1 ? "" : "s")")
                            .font(LumoFonts.caption)
                            .foregroundStyle(LumoColors.labelSecondary)
                        Text(formatUSD(agent.totalUsd))
                            .font(LumoFonts.bodyEmphasized)
                            .foregroundStyle(LumoColors.label)
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                    .padding(.vertical, LumoSpacing.xs)
                    if agent.id != dashboard.agents.prefix(8).last?.id {
                        Divider().background(LumoColors.separator)
                    }
                }
            }
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
    }

    private func recentSection(_ dashboard: UserCostDashboard) -> some View {
        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
            Text("RECENT")
                .font(LumoFonts.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(LumoColors.labelTertiary)
            VStack(spacing: LumoSpacing.xs) {
                ForEach(dashboard.recent.prefix(15)) { row in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.agentId)
                                .font(LumoFonts.callout)
                                .foregroundStyle(LumoColors.label)
                            HStack(spacing: 4) {
                                Text(relativeTime(row.createdAt))
                                Text("·")
                                Text(row.status)
                                    .foregroundStyle(statusColor(row.status))
                                if let cap = row.capabilityId {
                                    Text("·")
                                    Text(cap)
                                }
                            }
                            .font(LumoFonts.caption)
                            .foregroundStyle(LumoColors.labelSecondary)
                        }
                        Spacer()
                        Text(formatUSD(row.totalUsd))
                            .font(LumoFonts.callout)
                            .foregroundStyle(LumoColors.label)
                    }
                    .padding(.vertical, LumoSpacing.xs)
                    if row.id != dashboard.recent.prefix(15).last?.id {
                        Divider().background(LumoColors.separator)
                    }
                }
            }
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
    }

    // MARK: - States

    private var skeleton: some View {
        VStack(spacing: LumoSpacing.md) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: LumoRadius.md)
                    .fill(LumoColors.surfaceElevated)
                    .frame(height: 100)
            }
        }
        .accessibilityIdentifier("cost.loading")
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: LumoSpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(LumoColors.warning)
            Text(message)
                .font(LumoFonts.body)
                .foregroundStyle(LumoColors.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(LumoSpacing.lg)
        .accessibilityIdentifier("cost.error")
    }

    // MARK: - Format helpers

    private func formatUSD(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }

    private func capLabel(_ cap: Double?, soft: Bool) -> String {
        guard let cap else { return "No cap" }
        let suffix = soft ? " soft cap" : " cap"
        return "\(formatUSD(cap))\(suffix)"
    }

    private func usagePercent(spent: Double, cap: Double?) -> Double {
        guard let cap, cap > 0 else { return 0 }
        return spent / cap
    }

    private func barColor(pct: Double) -> Color {
        switch pct {
        case ..<0.5: return LumoColors.success
        case ..<0.85: return LumoColors.cyan
        case ..<1.0: return LumoColors.warning
        default: return LumoColors.warning
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "success", "ok": return LumoColors.success
        case "error", "failed", "aborted_budget": return LumoColors.warning
        default: return LumoColors.labelSecondary
        }
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: iso)
        }()
        guard let date else { return iso }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
