//
//  ContentView.swift
//  Air_Pollute_Tracker
//
//  Created by Jasmine Lin on 5/9/26.
//

import SwiftUI
import SwiftData
import Charts

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExposureSample.timestamp, order: .reverse) private var samples: [ExposureSample]
    @ObservedObject var sharedTracker: ExposureTracker
    @AppStorage(SettingsKeys.openAQAPIKey) private var openAQAPIKey = ""
    @AppStorage(SettingsKeys.alertThreshold) private var alertThreshold = Defaults.alertThreshold
    @AppStorage(SettingsKeys.sampleIntervalSeconds) private var sampleIntervalSeconds = Defaults.sampleIntervalSeconds
    @AppStorage(SettingsKeys.trackingDays) private var trackingDays = TrackingDuration.sevenDays.rawValue
    @State private var isOpenAQAPIKeyVisible = false

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
            .onAppear {
                tracker.configure(modelContext: modelContext)
            }
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
        }
        .cardStyle()
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
                .pickerStyle(.segmented)
                Text("How far back the report and recent samples look.")
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
                    Chart(orderedSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("PM2.5", sample.pm25)
                        )
                        PointMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("PM2.5", sample.pm25)
                        )
                    }
                    .frame(height: 180)
                    .chartYScale(domain: 0...(max(summary.peakPM25, threshold) * 1.2))

                    Text("Each point is one estimated PM2.5 reading at the time it was sampled (automatic or manual).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

private extension View {
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}
