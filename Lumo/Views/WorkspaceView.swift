import SwiftUI

/// iOS /workspace surface. Mirrors the web shell at
/// `apps/web/app/workspace/page.tsx` — five tabs (Today / Content /
/// Inbox / Co-pilot / Operations). v1.0 ships Today + Operations
/// against \`/workspace/today\` and \`/workspace/operations\`; the
/// other three render explicit "shipping in v1.x" placeholders
/// matching web's v1.0 posture so the user understands the roadmap
/// without anything hidden.
struct WorkspaceView: View {
    @StateObject private var viewModel: WorkspaceScreenViewModel

    init(viewModel: WorkspaceScreenViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            ScrollView {
                content
                    .padding(.horizontal, LumoSpacing.md)
                    .padding(.vertical, LumoSpacing.md)
            }
            .refreshable { await refreshActive() }
        }
        .background(LumoColors.background.ignoresSafeArea())
        .navigationTitle("Workspace")
        .navigationBarTitleDisplayMode(.large)
        .task { await loadActive() }
        .onChange(of: viewModel.selectedTab) { _, _ in
            Task { await loadActive() }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LumoSpacing.xs) {
                ForEach(WorkspaceScreenViewModel.TabID.allCases) { tab in
                    Button {
                        viewModel.selectedTab = tab
                    } label: {
                        Text(tab.label)
                            .font(LumoFonts.caption.weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(
                                viewModel.selectedTab == tab
                                    ? LumoColors.label
                                    : LumoColors.labelSecondary
                            )
                            .padding(.horizontal, LumoSpacing.md)
                            .padding(.vertical, LumoSpacing.sm)
                            .background(
                                Capsule().fill(
                                    viewModel.selectedTab == tab
                                        ? LumoColors.surfaceElevated
                                        : Color.clear
                                )
                            )
                    }
                    .accessibilityIdentifier("workspace.tab.\(tab.rawValue)")
                }
            }
            .padding(.horizontal, LumoSpacing.md)
            .padding(.vertical, LumoSpacing.sm)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selectedTab {
        case .today:
            todayContent
        case .operations:
            operationsContent
        case .content, .inbox, .copilot:
            comingSoon(viewModel.selectedTab)
        }
    }

    // MARK: - Today

    @ViewBuilder
    private var todayContent: some View {
        switch viewModel.today {
        case .idle, .loading:
            skeletonCards
        case .loaded(let env):
            VStack(alignment: .leading, spacing: LumoSpacing.lg) {
                WorkspaceCardSection(
                    title: "CALENDAR",
                    source: env.calendar.source,
                    ageMs: env.calendar.age_ms,
                    error: env.calendar.error
                ) {
                    if env.calendar.events.isEmpty {
                        emptyCardCopy("Nothing on your calendar in the next few hours.")
                    } else {
                        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
                            ForEach(env.calendar.events.prefix(4)) { event in
                                calendarRow(event)
                            }
                        }
                    }
                }
                WorkspaceCardSection(
                    title: "EMAIL",
                    source: env.email.source,
                    ageMs: env.email.age_ms,
                    error: env.email.error
                ) {
                    if env.email.messages.isEmpty {
                        emptyCardCopy("Inbox looks quiet.")
                    } else {
                        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
                            ForEach(env.email.messages.prefix(4)) { msg in
                                emailRow(msg)
                            }
                        }
                    }
                }
                WorkspaceCardSection(
                    title: "NOW PLAYING",
                    source: env.spotify.source,
                    ageMs: env.spotify.age_ms,
                    error: env.spotify.error
                ) {
                    if let np = env.spotify.now_playing, np.is_playing,
                       let track = np.track_name {
                        HStack(spacing: LumoSpacing.md) {
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(LumoColors.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track)
                                    .font(LumoFonts.bodyEmphasized)
                                    .foregroundStyle(LumoColors.label)
                                if let artist = np.artist {
                                    Text(artist)
                                        .font(LumoFonts.caption)
                                        .foregroundStyle(LumoColors.labelSecondary)
                                }
                            }
                            Spacer()
                        }
                    } else {
                        emptyCardCopy("Not playing right now.")
                    }
                }
                if !env.youtube.channels.isEmpty {
                    WorkspaceCardSection(
                        title: "YOUTUBE",
                        source: env.youtube.source,
                        ageMs: env.youtube.age_ms,
                        error: env.youtube.error
                    ) {
                        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
                            ForEach(env.youtube.channels.prefix(2)) { channel in
                                Text(channel.channel_title)
                                    .font(LumoFonts.bodyEmphasized)
                                    .foregroundStyle(LumoColors.label)
                                ForEach(channel.recent_videos.prefix(3)) { video in
                                    HStack(alignment: .top, spacing: LumoSpacing.sm) {
                                        Image(systemName: "play.rectangle.fill")
                                            .foregroundStyle(LumoColors.cyan.opacity(0.85))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(video.title)
                                                .font(LumoFonts.body)
                                                .foregroundStyle(LumoColors.label)
                                                .lineLimit(2)
                                            if let views = video.views {
                                                Text("\(views.formatted()) views")
                                                    .font(LumoFonts.caption)
                                                    .foregroundStyle(LumoColors.labelSecondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .error(let message):
            errorState(message)
        }
    }

    // MARK: - Operations

    @ViewBuilder
    private var operationsContent: some View {
        switch viewModel.operations {
        case .idle, .loading:
            skeletonCards
        case .loaded(let env):
            VStack(alignment: .leading, spacing: LumoSpacing.lg) {
                WorkspaceCardSection(
                    title: "CONNECTORS",
                    source: nil,
                    ageMs: nil,
                    error: nil
                ) {
                    if env.connectors.isEmpty {
                        emptyCardCopy("No connectors configured yet.")
                    } else {
                        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
                            ForEach(env.connectors) { row in
                                connectorRow(row)
                            }
                        }
                    }
                }
                if !env.audit.isEmpty {
                    WorkspaceCardSection(
                        title: "RECENT AUDIT",
                        source: nil,
                        ageMs: nil,
                        error: nil
                    ) {
                        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
                            ForEach(env.audit.prefix(8)) { row in
                                auditRow(row)
                            }
                        }
                    }
                }
            }
        case .error(let message):
            errorState(message)
        }
    }

    // MARK: - Components

    private func calendarRow(_ event: WorkspaceCalendarEvent) -> some View {
        HStack(alignment: .top, spacing: LumoSpacing.sm) {
            Image(systemName: "calendar")
                .foregroundStyle(LumoColors.cyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(LumoFonts.body)
                    .foregroundStyle(LumoColors.label)
                    .lineLimit(2)
                Text(WorkspaceFormat.timeRange(start: event.start_iso, end: event.end_iso))
                    .font(LumoFonts.caption)
                    .foregroundStyle(LumoColors.labelSecondary)
            }
            Spacer()
        }
    }

    private func emailRow(_ msg: WorkspaceEmailPreview) -> some View {
        HStack(alignment: .top, spacing: LumoSpacing.sm) {
            Image(systemName: msg.unread ? "envelope.badge" : "envelope")
                .foregroundStyle(msg.unread ? LumoColors.cyan : LumoColors.labelSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.subject)
                    .font(LumoFonts.body)
                    .foregroundStyle(LumoColors.label)
                    .lineLimit(1)
                Text(msg.from)
                    .font(LumoFonts.caption)
                    .foregroundStyle(LumoColors.labelSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func connectorRow(_ row: WorkspaceConnectorRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.display_name ?? row.agent_id)
                    .font(LumoFonts.bodyEmphasized)
                    .foregroundStyle(LumoColors.label)
                Text(row.source ?? "oauth")
                    .font(LumoFonts.caption)
                    .foregroundStyle(LumoColors.labelSecondary)
            }
            Spacer()
            Text(row.status.uppercased())
                .font(LumoFonts.caption.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(WorkspaceFormat.statusColor(row.status))
                .padding(.horizontal, LumoSpacing.sm)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(WorkspaceFormat.statusColor(row.status).opacity(0.12))
                )
        }
        .padding(.vertical, 2)
    }

    private func auditRow(_ row: WorkspaceAuditRow) -> some View {
        HStack(alignment: .top, spacing: LumoSpacing.sm) {
            Circle()
                .fill(row.ok ? LumoColors.success : LumoColors.warning)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.agent_id) · \(row.action_type)")
                    .font(LumoFonts.callout)
                    .foregroundStyle(LumoColors.label)
                if let excerpt = row.content_excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(LumoFonts.caption)
                        .foregroundStyle(LumoColors.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }

    private var skeletonCards: some View {
        VStack(spacing: LumoSpacing.md) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: LumoRadius.md)
                    .fill(LumoColors.surfaceElevated)
                    .frame(height: 100)
            }
        }
        .accessibilityIdentifier("workspace.loading")
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
        .accessibilityIdentifier("workspace.error")
    }

    private func emptyCardCopy(_ text: String) -> some View {
        Text(text)
            .font(LumoFonts.callout)
            .foregroundStyle(LumoColors.labelSecondary)
    }

    private func comingSoon(_ tab: WorkspaceScreenViewModel.TabID) -> some View {
        VStack(spacing: LumoSpacing.md) {
            Image(systemName: glyph(for: tab))
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(LumoColors.labelTertiary)
            Text(blurb(for: tab))
                .font(LumoFonts.body)
                .foregroundStyle(LumoColors.labelSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LumoSpacing.lg)
            Text("Shipping in v1.x")
                .font(LumoFonts.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(LumoColors.cyan)
                .padding(.horizontal, LumoSpacing.md)
                .padding(.vertical, 6)
                .background(Capsule().fill(LumoColors.cyan.opacity(0.12)))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LumoSpacing.xl)
        .accessibilityIdentifier("workspace.tab.placeholder.\(tab.rawValue)")
    }

    private func glyph(for tab: WorkspaceScreenViewModel.TabID) -> String {
        switch tab {
        case .content: return "square.stack.3d.up"
        case .inbox: return "tray.and.arrow.down"
        case .copilot: return "sparkle"
        default: return "square.grid.2x2"
        }
    }

    private func blurb(for tab: WorkspaceScreenViewModel.TabID) -> String {
        switch tab {
        case .content:
            return "What's working across your channels — outliers, repurpose cues, schedule."
        case .inbox:
            return "Comments, DMs, and replies — business leads pulled out of the noise."
        case .copilot:
            return "Chat with all your connected data. Ask anything; Orchet answers with numbers."
        default:
            return ""
        }
    }

    private func loadActive() async {
        switch viewModel.selectedTab {
        case .today:
            await viewModel.loadTodayIfNeeded()
        case .operations:
            await viewModel.loadOperationsIfNeeded()
        default:
            break
        }
    }

    private func refreshActive() async {
        switch viewModel.selectedTab {
        case .today:
            await viewModel.refreshToday()
        case .operations:
            await viewModel.refreshOperations()
        default:
            break
        }
    }
}

// MARK: - Reusable card section

private struct WorkspaceCardSection<Content: View>: View {
    let title: String
    let source: String?
    let ageMs: Int?
    let error: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.sm) {
            HStack {
                Text(title)
                    .font(LumoFonts.caption.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(LumoColors.labelTertiary)
                Spacer()
                if let source {
                    sourcePill(source)
                }
            }
            if let error, !error.isEmpty {
                Text(error)
                    .font(LumoFonts.caption)
                    .foregroundStyle(LumoColors.warning)
            }
            content()
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

    private func sourcePill(_ source: String) -> some View {
        let tint: Color = {
            switch source {
            case "live": return LumoColors.success
            case "cached": return LumoColors.cyan
            case "stale": return LumoColors.warning
            case "error": return LumoColors.warning
            default: return LumoColors.labelTertiary
            }
        }()
        return Text(label(for: source).uppercased())
            .font(LumoFonts.caption.weight(.semibold))
            .tracking(1.0)
            .foregroundStyle(tint)
            .padding(.horizontal, LumoSpacing.xs)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func label(for source: String) -> String {
        if source == "cached", let ms = ageMs, ms > 0 {
            let minutes = ms / 60_000
            if minutes > 0 { return "cached \(minutes)m" }
            let seconds = ms / 1000
            return "cached \(seconds)s"
        }
        return source
    }
}

// MARK: - Format helpers

enum WorkspaceFormat {
    static func timeRange(start: String, end: String?) -> String {
        guard let s = parseISO(start) else { return start }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let startLabel = formatter.string(from: s)
        if let endRaw = end, let e = parseISO(endRaw) {
            return "\(startLabel) – \(formatter.string(from: e))"
        }
        return startLabel
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "active": return LumoColors.success
        case "expired": return LumoColors.warning
        case "revoked", "error": return LumoColors.warning
        default: return LumoColors.labelTertiary
        }
    }

    private static func parseISO(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}
