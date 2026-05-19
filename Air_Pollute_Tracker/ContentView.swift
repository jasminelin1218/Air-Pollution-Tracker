//
//  ContentView.swift
//  Air_Pollute_Tracker
//
//  Created by Jasmine Lin on 5/9/26.
//

import SwiftUI
import SwiftData
import Charts
import CoreLocation

private struct TrackingExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExposureSample.timestamp, order: .reverse) private var samples: [ExposureSample]
    @ObservedObject var sharedTracker: ExposureTracker
    @AppStorage(SettingsKeys.openAQAPIKey) private var openAQAPIKey = ""
    @AppStorage(SettingsKeys.alertThreshold) private var alertThreshold = Defaults.alertThreshold
    @AppStorage(SettingsKeys.sampleIntervalSeconds) private var sampleIntervalSeconds = Defaults.sampleIntervalSeconds
    @AppStorage(SettingsKeys.trackingDays) private var trackingDays = TrackingDuration.sevenDays.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOpenAQAPIKeyVisible = false
    @State private var trackingExportShareItem: TrackingExportShareItem?
    @State private var trackingExportErrorMessage: String?

    private var tracker: ExposureTracker { sharedTracker }

    private var activeDuration: TrackingDuration {
        TrackingDuration(rawValue: trackingDays) ?? .sevenDays
    }

    private var windowSamples: [ExposureSample] {
        let cutoff = Date().addingTimeInterval(-activeDuration.windowInterval)
        return samples.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    WeeklyReportView(samples: windowSamples, threshold: alertThreshold, duration: activeDuration)
                    settingsCard
                    recentSamplesCard
                }
                .padding()
            }
            .navigationTitle("Air Exposure")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportTrackingHistoryToShare()
                    } label: {
                        Label("Export history", systemImage: "square.and.arrow.up")
                    }
                    .disabled(samples.isEmpty)
                    .accessibilityHint("Exports all stored samples as a spreadsheet file from oldest to newest.")
                }
            }
            .onAppear {
                tracker.configure(modelContext: modelContext)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                tracker.appDidEnterBackground()
            case .active:
                tracker.appWillEnterForeground()
            default:
                break
            }
        }
        .sheet(item: Binding(
            get: { sharedTracker.stopReportSheet },
            set: { sharedTracker.stopReportSheet = $0 }
        )) { report in
            NavigationStack {
                StopTrackingReportSheetContent(report: report)
                    .navigationTitle("Session report")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                sharedTracker.stopReportSheet = nil
                            }
                        }
                    }
            }
        }
        .sheet(item: $trackingExportShareItem) { item in
            ActivityView(activityItems: [item.url])
                .ignoresSafeArea()
                .onDisappear {
                    try? FileManager.default.removeItem(at: item.url)
                }
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { trackingExportErrorMessage != nil },
                set: { if !$0 { trackingExportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { trackingExportErrorMessage = nil }
        } message: {
            Text(trackingExportErrorMessage ?? "")
        }
    }

    /// Read-only export of every sample currently in the store (oldest → newest). Does not affect tracking.
    private func exportTrackingHistoryToShare() {
        let sortedAscending = samples.sorted { $0.timestamp < $1.timestamp }
        do {
            let url = try TrackingHistoryCSVExport.writeTempCSVFile(allSamplesSortedAscending: sortedAscending)
            trackingExportShareItem = TrackingExportShareItem(url: url)
        } catch {
            trackingExportErrorMessage = error.localizedDescription
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live PM2.5 Exposure")
                        .font(.headline)
                    Text(tracker.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: tracker.isTracking ? "location.fill" : "location")
                    .font(.title2)
                    .foregroundStyle(tracker.isTracking ? .green : .secondary)
            }

            if let latest = tracker.lastSample ?? windowSamples.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text(latest.pm25.formattedPM25)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("Last sample: \(latest.timestamp.shortDateTimeString) from \(latest.stationCount) station(s)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Start tracking to collect the first exposure sample.")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = tracker.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(tracker.isTracking ? "Stop Tracking" : "Start Tracking") {
                    tracker.isTracking ? tracker.stopTracking() : tracker.startTracking()
                }
                .buttonStyle(.borderedProminent)

                Button("Sample Now") {
                    tracker.sampleCurrentLocationNow()
                }
                .buttonStyle(.bordered)
                .disabled(tracker.isSampling)

                if tracker.isSampling {
                    ProgressView()
                }
            }

            if tracker.isTracking {
                overnightTrackingTips
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var overnightTrackingTips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reliable overnight sampling")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if tracker.authorizationStatus != .authorizedAlways {
                Text("Use location permission Always (Settings → Air Pollute Tracker → Location). “While Using” does not run in the background.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Turn on Settings → General → Background App Refresh for this app. Don’t swipe the app away from the app switcher.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("iOS may still stretch intervals in Low Power Mode or with a very low battery. The blue bar or pill means location is active.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenAQ API Key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .trailing) {
                    Group {
                        if isOpenAQAPIKeyVisible {
                            TextField("Paste key here", text: $openAQAPIKey)
                        } else {
                            SecureField("Paste key here", text: $openAQAPIKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textFieldStyle(.roundedBorder)
                    .padding(.trailing, 36)

                    Button {
                        isOpenAQAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isOpenAQAPIKeyVisible ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                    .accessibilityLabel(isOpenAQAPIKeyVisible ? "Hide OpenAQ API key" : "Show OpenAQ API key")
                }
                Text("Get a free key at openaq.org/developers/api-keys")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Alert threshold")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(alertThreshold.formattedPM25)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                Slider(
                    value: $alertThreshold,
                    in: 0.1...150,
                    step: 0.1,
                    onEditingChanged: { editing in
                        if !editing {
                            alertThreshold = alertThreshold.rounded(toPlaces: 1)
                            ExposureAlertService.shared.resetCooldown()
                        }
                    }
                )
                Text("Default is 35.5 ug/m3, near the PM2.5 unhealthy-for-sensitive-groups threshold. Releasing the slider resets the alert cooldown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sampling interval")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Sampling interval", selection: $sampleIntervalSeconds) {
                    Text("15 min").tag(15.0 * 60.0)
                    Text("30 min").tag(30.0 * 60.0)
                    Text("60 min").tag(60.0 * 60.0)
                }
                .pickerStyle(.segmented)
                Text("How often a new PM2.5 reading is taken while tracking is on. This is separate from the report window below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tracking window")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Tracking window", selection: $trackingDays) {
                    ForEach(TrackingDuration.allCases) { duration in
                        Text(duration.label).tag(duration.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("How far back the report and recent samples list look. Raw samples are kept at least 7 days so short windows do not delete older data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var recentSamplesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Samples")
                .font(.headline)

            if windowSamples.isEmpty {
                Text("No samples stored yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(windowSamples.prefix(8))) { sample in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.timestamp.shortDateTimeString)
                                .font(.subheadline.weight(.semibold))
                            Text("Accuracy \(sample.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))) m · \(sample.sourceSummary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(sample.pm25.formattedPM25)
                            .font(.subheadline.weight(.semibold))
                    }
                    Divider()
                }
            }
        }
        .cardStyle()
    }
}

#Preview {
    ContentView(sharedTracker: ExposureTracker())
        .modelContainer(for: ExposureSample.self, inMemory: true)
}

struct WeeklyReportView: View {
    let samples: [ExposureSample]
    let threshold: Double
    var duration: TrackingDuration = .sevenDays
    @AppStorage(SettingsKeys.sampleIntervalSeconds) private var sampleIntervalSeconds = Defaults.sampleIntervalSeconds
    @State private var selectedDate: Date?

    private var summary: WeeklyExposureSummary {
        WeeklyExposureReport.summarize(
            samples: samples,
            threshold: threshold,
            maxGapSeconds: min(sampleIntervalSeconds.nonZero(defaultValue: Defaults.sampleIntervalSeconds) * 2, duration.windowInterval / 4)
        )
    }

    private var orderedSamples: [ExposureSample] {
        samples.sorted { $0.timestamp < $1.timestamp }
    }

    /// Width of the visible x-domain when the chart is scrollable (in seconds).
    /// Matches the 6-hour tracking window chart (¼ of 6 h ≈ 1.5 h visible) so dot spacing
    /// is the same for 1-hour, 6-hour, and multi-day windows. Capped by the current window
    /// when it is shorter (e.g. 1-hour mode shows the full hour).
    private var visibleDomainSeconds: Int {
        let sixHourQuarter = max(Int(TrackingDuration.sixHours.windowInterval) / 4, 900)
        let window = Int(duration.windowInterval)
        return min(sixHourQuarter, window)
    }

    /// Fewer ticks keeps abbreviated date labels from crowding on narrow phones.
    private var axisTickCount: Int {
        duration.windowInterval < 24 * 60 * 60 ? 5 : 4
    }

    /// X-axis label density matches how much time is visible while scrolling.
    private var axisDateFormat: Date.FormatStyle {
        if visibleDomainSeconds > 86_400 {
            .dateTime.month(.abbreviated).day()
        } else {
            .dateTime.hour().minute()
        }
    }

    /// Sample closest to the touched x position.
    private var selectedSample: ExposureSample? {
        guard let date = selectedDate else { return nil }
        return orderedSamples.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(duration.reportTitle)
                .font(.headline)

            if samples.isEmpty {
                Text("After samples are collected, this report will show a \(duration.reportWindowDescription) time-weighted PM2.5 average, peak exposure, and time spent above your alert threshold.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                    ReportMetric(title: "TWA PM2.5", value: summary.timeWeightedAveragePM25.formattedPM25)
                    ReportMetric(title: "Peak PM2.5", value: summary.peakPM25.formattedPM25)
                    ReportMetric(title: "Tracked time", value: summary.trackedSeconds.formattedDurationHours)
                    ReportMetric(title: "High exposure", value: summary.highExposureSeconds.formattedDurationHours)
                }

                VStack(alignment: .leading, spacing: 6) {
                    let maxY = max(summary.peakPM25, threshold) * 1.2
                    Chart {
                        ForEach(orderedSamples, id: \.id) { sample in
                            LineMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("PM2.5", sample.pm25)
                            )
                            .interpolationMethod(.catmullRom)
                            PointMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("PM2.5", sample.pm25)
                            )
                            .symbolSize(220)
                            .foregroundStyle(.clear)
                            PointMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("PM2.5", sample.pm25)
                            )
                            .symbolSize(selectedSample?.id == sample.id ? 200 : 120)
                        }
                        // EPA breakpoint reference lines
                        RuleMark(y: .value("Good", 12.0))
                            .foregroundStyle(.green.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Moderate", 35.4))
                            .foregroundStyle(.yellow.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("USG", 55.4))
                            .foregroundStyle(.orange.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .frame(height: 200)
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: visibleDomainSeconds)
                    .chartYScale(domain: 0...maxY)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: axisTickCount)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: axisDateFormat)
                                .font(.caption2)
                        }
                    }
                    .chartXSelection(value: $selectedDate)

                    if let sample = selectedSample {
                        SampleCallout(sample: sample)
                    } else {
                        Text("Tap a dot to see sample details; scroll horizontally to explore earlier readings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 44)
                    }

                    PM25LegendView()
                }

                if !summary.dailyBreakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Chart(summary.dailyBreakdown) { day in
                            BarMark(
                                x: .value("Day", day.date, unit: .day),
                                y: .value("Average PM2.5", day.averagePM25)
                            )
                        }
                        .frame(height: 140)

                        Text("Each bar is the average PM2.5 for all samples on that calendar day within your tracking window.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cardStyle()
    }
}

private struct ReportMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Shown when the user taps Stop Tracking — summarizes samples from session start through stop time.
private struct StopTrackingReportSheetContent: View {
    let report: StopTrackingReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session: \(report.sessionStart.shortDateTimeString) → \(report.sessionEnd.shortDateTimeString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Duration: \(report.sessionDurationDescription) · Sampling: \(report.sampleIntervalSeconds.formattedSamplingIntervalLabel) · Alert bar: \(report.alertThreshold.formattedPM25)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if report.summary.sampleCount == 0 {
                    Text("No samples were recorded during this session.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                        ReportMetric(title: "TWA PM2.5", value: report.summary.timeWeightedAveragePM25.formattedPM25)
                        ReportMetric(title: "Peak PM2.5", value: report.summary.peakPM25.formattedPM25)
                        ReportMetric(title: "Tracked time", value: report.summary.trackedSeconds.formattedDurationHours)
                        ReportMetric(title: "High exposure", value: report.summary.highExposureSeconds.formattedDurationHours)
                    }
                    Text("\(report.summary.sampleCount) sample(s). “High exposure” counts time when PM2.5 was at or above \(report.alertThreshold.formattedPM25), with the same gap caps as TWA.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("TWA weights gaps between samples by at most \(report.twaMaxGapDescription) each (min of 2× sampling interval and session length ÷ 4), ending at stop time.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This summary is not saved separately.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Chart callout

private struct SampleCallout: View {
    let sample: ExposureSample

    private var stations: [String] {
        sample.sourceSummary.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    /// Non-empty only when JSON decodes to at least one snapshot (new samples).
    private var contributorSnapshots: [ContributingStationSnapshot] {
        guard !sample.contributorSnapshotsJSON.isEmpty,
              let data = sample.contributorSnapshotsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ContributingStationSnapshot].self, from: data),
              !decoded.isEmpty
        else { return [] }
        return decoded
    }

    private var showContributors: Bool {
        !contributorSnapshots.isEmpty || !stations.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sample.timestamp.shortDateTimeString)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(sample.pm25.formattedPM25)
                .font(.subheadline.weight(.bold))
            if showContributors {
                Divider()
                Text("\(sample.stationCount) contributing station\(sample.stationCount == 1 ? "" : "s"):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !contributorSnapshots.isEmpty {
                    ForEach(Array(contributorSnapshots.prefix(5).enumerated()), id: \.offset) { _, snap in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(snap.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(snap.pm25.formattedPM25), \(snap.distanceMeters.formattedStationDistance)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if contributorSnapshots.count > 5 {
                        Text("+ \(contributorSnapshots.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(stations.prefix(5), id: \.self) { station in
                        Text("• \(station)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if stations.count > 5 {
                        Text("+ \(stations.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 72)
    }
}

// MARK: - PM2.5 legend

private struct PM25LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PM2.5 reference levels (µg/m³):")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            LegendRow(color: .green,  label: "Good",                           range: "0–12")
            LegendRow(color: .yellow, label: "Moderate",                       range: "12.1–35.4")
            LegendRow(color: .orange, label: "Unhealthy for Sensitive Groups", range: "35.5–55.4")
            LegendRow(color: .red,    label: "Unhealthy",                      range: "55.5–150.4")
            LegendRow(color: .purple, label: "Very Unhealthy / Hazardous",     range: "150.5+")
            Text("At Moderate and above, sensitive groups — children, older adults, and those with heart or lung conditions — should reduce prolonged outdoor activity.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let label: String
    let range: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(range)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
