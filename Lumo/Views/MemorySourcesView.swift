import EventKit
import SwiftUI

/// Settings → Memory Sources — iOS opt-in surface for Phase B
/// EventKit signal capture.
///
/// Two-state toggle per source (Calendar, Reminders). Tapping a
/// toggle to "on":
///   1. Requests EventKit OS permission if not yet granted.
///   2. Flips the in-app `MemorySourcesSettings.calendarEnabled`
///      (or reminders) flag.
///   3. Triggers an immediate sync against the backend.
///
/// Tapping to "off":
///   1. Flips the in-app flag.
///   2. **Does NOT** revoke the OS permission (only the user can do
///      that in iOS Settings → Privacy & Security).
///   3. Sync service self-gates on the flag, so writes stop.
///
/// "Forget all calendar memory" button:
///   - Wipes the per-install salt (so any re-enable mints fresh
///     hashes the backend can't correlate against the prior set).
///   - POSTs `/memory/calendar/forget` to delete the user's raw
///     signal rows. Derived behavioural facts persist per ADR-014
///     stance — the brain can keep what it learned even though the
///     raw observations are gone.
///
/// Mounted from the Profile / Settings drawer destination.
struct MemorySourcesView: View {
    @State private var calendarEnabled = MemorySourcesSettings.calendarEnabled
    @State private var remindersEnabled = MemorySourcesSettings.remindersEnabled
    @State private var mailEnabled = false
    @State private var mailLoading = true
    @State private var calendarPermissionAlert = false
    @State private var forgetConfirm = false
    @State private var forgetInFlight = false
    @State private var mailForgetConfirm = false
    @State private var mailForgetInFlight = false

    var body: some View {
        List {
            Section(header: header, footer: privacyFooter) {
                Toggle(isOn: $calendarEnabled) {
                    Label("Calendar", systemImage: "calendar")
                }
                .accessibilityIdentifier("settings.memory.calendar")
                .onChange(of: calendarEnabled) { _, newValue in
                    Task { await handleCalendarToggle(newValue) }
                }

                Toggle(isOn: $remindersEnabled) {
                    Label("Reminders", systemImage: "checklist")
                }
                .accessibilityIdentifier("settings.memory.reminders")
                .onChange(of: remindersEnabled) { _, newValue in
                    MemorySourcesSettings.remindersEnabled = newValue
                }

                Toggle(isOn: $mailEnabled) {
                    Label("Mail", systemImage: "envelope")
                }
                .accessibilityIdentifier("settings.memory.mail")
                .disabled(mailLoading)
                .onChange(of: mailEnabled) { _, newValue in
                    Task { await handleMailToggle(newValue) }
                }
            }

            Section {
                Button(role: .destructive) {
                    forgetConfirm = true
                } label: {
                    Label("Forget all calendar memory", systemImage: "trash")
                }
                .disabled(forgetInFlight)
                .accessibilityIdentifier("settings.memory.forget")

                Button(role: .destructive) {
                    mailForgetConfirm = true
                } label: {
                    Label("Forget all mail memory", systemImage: "trash")
                }
                .disabled(mailForgetInFlight)
                .accessibilityIdentifier("settings.memory.mail.forget")
            }
        }
        .navigationTitle("Memory Sources")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMailState() }
        .alert("Calendar access denied", isPresented: $calendarPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Orchet needs full Calendar access to remember your events. " +
                "Grant it in Settings → Privacy & Security → Calendars → Orchet."
            )
        }
        .confirmationDialog(
            "Forget calendar memory?",
            isPresented: $forgetConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget everything", role: .destructive) {
                Task { await handleForget() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Orchet will delete the calendar events it has stored. " +
                "Habits it has already learned stay — you can clear those " +
                "individually under Memory → Facts."
            )
        }
        .confirmationDialog(
            "Forget mail memory?",
            isPresented: $mailForgetConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget everything", role: .destructive) {
                Task { await handleMailForget() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Orchet will forget every email it has considered. " +
                "Facts it already learned (trips, orders, reservations) stay — " +
                "clear those individually under Memory → Facts."
            )
        }
    }

    private var header: some View {
        Text("Choose which sources Orchet may learn from. You stay in control — each toggle is independent and revocable.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var privacyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What Orchet stores")
                .font(.footnote.weight(.semibold))
            Text(
                "• Event title, location, time, attendee count, recurring flag.\n" +
                "• The event identifier is one-way hashed on your device before it leaves — Orchet never sees the raw EventKit id."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func handleCalendarToggle(_ newValue: Bool) async {
        if newValue {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .fullAccess {
                MemorySourcesSettings.calendarEnabled = true
                CalendarSignalService.shared.syncNow()
                return
            }
            // Either notDetermined or denied. Try the OS prompt;
            // if denied, show the route-to-Settings alert.
            let granted = await CalendarSignalService.shared.requestPermissionAndEnable()
            if !granted {
                calendarEnabled = false
                calendarPermissionAlert = true
            }
        } else {
            MemorySourcesSettings.calendarEnabled = false
        }
    }

    @MainActor
    private func handleForget() async {
        forgetInFlight = true
        defer { forgetInFlight = false }
        await CalendarSignalService.shared.forgetEverything()
        calendarEnabled = false
        remindersEnabled = false
    }

    @MainActor
    private func loadMailState() async {
        mailLoading = true
        defer { mailLoading = false }
        if let enabled = await MemoryMailService.shared.fetchEnabled() {
            mailEnabled = enabled
        }
    }

    @MainActor
    private func handleMailToggle(_ newValue: Bool) async {
        // Optimistic flip already happened via @State binding. If the
        // PATCH fails, roll back so the UI stays honest.
        let ok = await MemoryMailService.shared.setEnabled(newValue)
        if !ok {
            mailEnabled = !newValue
        }
    }

    @MainActor
    private func handleMailForget() async {
        mailForgetInFlight = true
        defer { mailForgetInFlight = false }
        await MemoryMailService.shared.forgetEverything()
        // Server-side flag is independent of the audit rows; we don't
        // flip mailEnabled here — the user may want to keep collecting
        // forward, just clear the past.
    }
}
