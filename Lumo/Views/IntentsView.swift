import SwiftUI

/// Standing routines list — mirrors web `/intents`. Lists active +
/// paused routines, toggles enabled state, deletes, and supports a
/// minimal create form (description + cron + timezone). The richer
/// schedule builder is a future pass.
struct IntentsView: View {
    @StateObject private var viewModel: IntentsScreenViewModel
    @State private var showCreateSheet = false

    init(viewModel: IntentsScreenViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                skeleton
            case .loaded(let intents) where intents.isEmpty:
                emptyState
            case .loaded(let intents):
                list(intents)
            case .error(let message):
                errorState(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumoColors.background.ignoresSafeArea())
        .navigationTitle("Routines")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityIdentifier("intents.create")
            }
        }
        .task { await viewModel.loadIfNeeded() }
        .refreshable { await viewModel.refresh() }
        .sheet(isPresented: $showCreateSheet) {
            IntentsCreateSheet(viewModel: viewModel) { showCreateSheet = false }
        }
    }

    // MARK: - States

    private var skeleton: some View {
        VStack(spacing: LumoSpacing.sm) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: LumoRadius.md)
                    .fill(LumoColors.surfaceElevated)
                    .frame(height: 78)
            }
        }
        .padding(LumoSpacing.md)
        .accessibilityIdentifier("intents.loading")
    }

    private var emptyState: some View {
        VStack(spacing: LumoSpacing.lg) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(LumoColors.labelTertiary)
            Text("No routines yet")
                .font(LumoFonts.title)
                .foregroundStyle(LumoColors.label)
            Text("Say things like \"every Friday at 6pm, book me a bike ride\" — Orchet will turn it into a routine and show it here.")
                .font(LumoFonts.body)
                .foregroundStyle(LumoColors.labelSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LumoSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("intents.empty")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("intents.error")
    }

    private func list(_ intents: [StandingIntent]) -> some View {
        ScrollView {
            LazyVStack(spacing: LumoSpacing.sm) {
                ForEach(intents) { intent in
                    row(intent)
                }
            }
            .padding(LumoSpacing.md)
        }
        .accessibilityIdentifier("intents.list")
    }

    private func row(_ intent: StandingIntent) -> some View {
        VStack(alignment: .leading, spacing: LumoSpacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(intent.description)
                        .font(LumoFonts.bodyEmphasized)
                        .foregroundStyle(LumoColors.label)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(LumoColors.labelTertiary)
                        Text(intent.schedule_cron)
                            .font(LumoFonts.caption.monospaced())
                            .foregroundStyle(LumoColors.labelSecondary)
                        Text("·")
                            .foregroundStyle(LumoColors.labelTertiary)
                        Text(intent.timezone)
                            .font(LumoFonts.caption)
                            .foregroundStyle(LumoColors.labelSecondary)
                    }
                    if let next = intent.next_fire_at {
                        Text("Next: \(relativeTime(next))")
                            .font(LumoFonts.caption)
                            .foregroundStyle(LumoColors.labelTertiary)
                    }
                }
                Spacer()
                if intent.enabled {
                    statusChip(label: "ACTIVE", tint: LumoColors.success)
                } else {
                    statusChip(label: "PAUSED", tint: LumoColors.labelTertiary)
                }
            }
            HStack(spacing: LumoSpacing.sm) {
                Button {
                    Task { await viewModel.toggle(intent) }
                } label: {
                    Text(intent.enabled ? "Pause" : "Resume")
                        .font(LumoFonts.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(LumoColors.label)
                        .padding(.horizontal, LumoSpacing.sm)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(LumoColors.surfaceElevated))
                }
                .disabled(viewModel.busyID == intent.id)
                .accessibilityIdentifier("intents.toggle.\(intent.id)")

                Button(role: .destructive) {
                    Task { await viewModel.delete(intent) }
                } label: {
                    Text("Delete")
                        .font(LumoFonts.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(LumoColors.warning)
                        .padding(.horizontal, LumoSpacing.sm)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(LumoColors.warning.opacity(0.12)))
                }
                .disabled(viewModel.busyID == intent.id)
                .accessibilityIdentifier("intents.delete.\(intent.id)")

                Spacer()
                if viewModel.busyID == intent.id {
                    ProgressView().controlSize(.mini)
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

    private func statusChip(label: String, tint: Color) -> some View {
        Text(label)
            .font(LumoFonts.caption.weight(.semibold))
            .tracking(1.0)
            .foregroundStyle(tint)
            .padding(.horizontal, LumoSpacing.sm)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
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

private struct IntentsCreateSheet: View {
    @ObservedObject var viewModel: IntentsScreenViewModel
    let onDismiss: () -> Void

    @State private var description: String = ""
    @State private var cron: String = "0 9 * * 1"
    @State private var timezone: String = TimeZone.current.identifier
    @State private var saving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What should Orchet do?") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("intents.create.description")
                }
                Section("Schedule") {
                    TextField("Cron expression", text: $cron)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .accessibilityIdentifier("intents.create.cron")
                    TextField("Timezone", text: $timezone)
                        .autocapitalization(.none)
                        .accessibilityIdentifier("intents.create.timezone")
                    Text("Standard 5-field cron: minute, hour, day, month, weekday. Example: `0 9 * * 1` = every Monday at 9am.")
                        .font(LumoFonts.footnote)
                        .foregroundStyle(LumoColors.labelSecondary)
                }
                if let error = viewModel.createError {
                    Section {
                        Text(error)
                            .font(LumoFonts.callout)
                            .foregroundStyle(LumoColors.warning)
                    }
                }
            }
            .navigationTitle("New routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            saving = true
                            let ok = await viewModel.createIntent(
                                description: description,
                                cron: cron,
                                timezone: timezone
                            )
                            saving = false
                            if ok { onDismiss() }
                        }
                    } label: {
                        if saving {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Create")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(saving || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("intents.create.save")
                }
            }
        }
    }
}
