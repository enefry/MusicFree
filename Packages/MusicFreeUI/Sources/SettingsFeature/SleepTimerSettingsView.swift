import AppServices
import DesignSystem
import Foundation
import SettingsAPI
import SwiftUI

struct SleepTimerSettingsView: View {
    @Bindable var settingsViewModel: SettingsViewModel
    let serving: (any SleepTimerServing)?

    @State private var oneTimeDurationMinutes = 20
    @State private var runtimeSnapshot = SleepTimerSnapshot.inactive

    var body: some View {
        Form {
            oneTimeSection
            automaticSchedulesSection
        }
        .navigationTitle(L("Sleep timer"))
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
        .task {
            guard let serving else { return }
            runtimeSnapshot = serving.snapshot
            for await snapshot in serving.makeSnapshotStream() {
                guard !Task.isCancelled else { return }
                runtimeSnapshot = snapshot
            }
        }
    }

    private var oneTimeSection: some View {
        Section(L("One-time timer")) {
            if runtimeSnapshot.isActive {
                activeTimerStatus

                Button(role: .destructive) {
                    serving?.cancel()
                } label: {
                    Label(L("Cancel timer"), systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("settings.sleepTimer.cancel")
            } else {
                Stepper(
                    value: $oneTimeDurationMinutes,
                    in: (
                        SleepTimerSchedule.minimumDurationMinutes
                            ... SleepTimerSchedule.maximumDurationMinutes
                    ),
                    step: 1
                ) {
                    LabeledContent(L("Timer duration")) {
                        Text(minutesText(oneTimeDurationMinutes))
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("settings.sleepTimer.oneTime.duration")

                Button {
                    serving?.startOneTime(durationMinutes: oneTimeDurationMinutes)
                } label: {
                    Label(L("Start timer"), systemImage: "timer")
                }
                .disabled(serving == nil)
                .accessibilityIdentifier("settings.sleepTimer.oneTime.start")
            }
        }
    }

    private var activeTimerStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                LabeledContent(sourceTitle) {
                    Text(remainingText(at: context.date))
                        .monospacedDigit()
                }
                if let deadline = runtimeSnapshot.deadline {
                    LabeledContent(L("Ends at")) {
                        Text(deadline.formatted(date: .omitted, time: .shortened))
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.sleepTimer.active")
    }

    private var automaticSchedulesSection: some View {
        Section {
            let schedules = settingsViewModel.settings.playbackPreferences.sleepTimer.schedules
            ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                scheduleEditor(schedule, number: index + 1)
            }

            Button {
                settingsViewModel.addSleepTimerSchedule()
            } label: {
                Label(L("Add schedule"), systemImage: "plus")
            }
            .disabled(settingsViewModel.isSaving)
            .accessibilityIdentifier("settings.sleepTimer.schedule.add")
        } header: {
            Text(L("Automatic schedules"))
        }
    }

    private func scheduleEditor(_ schedule: SleepTimerSchedule, number: Int) -> some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
            Toggle(isOn: enabledBinding(for: schedule)) {
                Text("\(L("Schedule")) \(number)")
            }
            .accessibilityIdentifier("settings.sleepTimer.schedule.\(schedule.id).enabled")

            DatePicker(
                L("From"),
                selection: timeBinding(for: schedule, isStart: true),
                displayedComponents: .hourAndMinute
            )
            .disabled(!schedule.isEnabled || settingsViewModel.isSaving)

            DatePicker(
                L("To"),
                selection: timeBinding(for: schedule, isStart: false),
                displayedComponents: .hourAndMinute
            )
            .disabled(!schedule.isEnabled || settingsViewModel.isSaving)

            Stepper(
                value: durationBinding(for: schedule),
                in: (
                    SleepTimerSchedule.minimumDurationMinutes
                        ... SleepTimerSchedule.maximumDurationMinutes
                ),
                step: 1
            ) {
                LabeledContent(L("Timer duration")) {
                    Text(minutesText(schedule.durationMinutes))
                        .monospacedDigit()
                }
            }
            .disabled(!schedule.isEnabled || settingsViewModel.isSaving)

            Button(role: .destructive) {
                settingsViewModel.deleteSleepTimerSchedule(id: schedule.id)
            } label: {
                Label(L("Delete schedule"), systemImage: "trash")
            }
            .disabled(settingsViewModel.isSaving)
        }
        .padding(.vertical, MusicFreeSpacingTokens.xSmall)
    }

    private func enabledBinding(for schedule: SleepTimerSchedule) -> Binding<Bool> {
        Binding(
            get: { schedule.isEnabled },
            set: { settingsViewModel.setSleepTimerScheduleEnabled($0, id: schedule.id) }
        )
    }

    private func durationBinding(for schedule: SleepTimerSchedule) -> Binding<Int> {
        Binding(
            get: { schedule.durationMinutes },
            set: { settingsViewModel.setSleepTimerScheduleDuration($0, id: schedule.id) }
        )
    }

    private func timeBinding(
        for schedule: SleepTimerSchedule,
        isStart: Bool
    ) -> Binding<Date> {
        Binding(
            get: {
                let minute = isStart ? schedule.startMinute : schedule.endMinute
                return Calendar.autoupdatingCurrent.date(
                    byAdding: .minute,
                    value: minute,
                    to: Calendar.autoupdatingCurrent.startOfDay(for: Date())
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.autoupdatingCurrent.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                guard let hour = components.hour, let minute = components.minute else { return }
                let minuteOfDay = hour * 60 + minute
                if isStart {
                    settingsViewModel.setSleepTimerScheduleStartMinute(
                        minuteOfDay,
                        id: schedule.id
                    )
                } else {
                    settingsViewModel.setSleepTimerScheduleEndMinute(
                        minuteOfDay,
                        id: schedule.id
                    )
                }
            }
        )
    }

    private var sourceTitle: String {
        switch runtimeSnapshot.source {
        case .oneTime: L("One-time timer")
        case .automatic: L("Automatic timer")
        case nil: L("Sleep timer")
        }
    }

    private func remainingText(at date: Date) -> String {
        guard let deadline = runtimeSnapshot.deadline else { return "0:00" }
        let totalSeconds = max(0, Int(deadline.timeIntervalSince(date).rounded(.up)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func minutesText(_ minutes: Int) -> String {
        L("%lld min", Int64(minutes))
    }
}
