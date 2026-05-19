# Air Pollute Tracker — Issues & Solutions (Progress Log)

This document summarizes problems found during testing and the code changes made to address them, organized by theme.

---

## 1. Automatic sampling & Recent Samples

### Issues
- **Recent Samples** did not update on a regular schedule while tracking was on.
- **Stationary users** were sampled every ~30 min instead of every 15 min (when 15 min was selected).
- **Background refresh** could skip samples because it still went through the time gate.

### Root causes

| Bug | Location | What went wrong |
|-----|----------|-----------------|
| **A — Double-interval gate** | `ExposureTracker.shouldSample()` | If the user had not moved 150 m and less than `interval × 2` had passed, sampling was blocked even after the normal interval elapsed. |
| **B — BG task not forced** | `handleBackgroundRefresh()` | Used `forced: false`, so background samples could be blocked by `shouldSample()`. |

### Solutions (`ExposureTracker.swift`)
- Removed the extra stationary/distance gate; only **time since last sample** is checked.
- `handleBackgroundRefresh` uses **`forced: true`** (including when requesting a one-shot location with no cached fix).
- Replaced **continuous** `startUpdatingLocation()` with:
  - **Timer** → periodic `requestLocation()` (one-shot GPS),
  - **Significant location changes** (~500 m),
  - **BGAppRefreshTask** as fallback.
- **Two-phase timer** (`delayTimer` + `repeatTimer`): next sample is scheduled from **last sample time**, not from “now” when settings change.
- **UserDefaults observer** reschedules the timer when sampling interval changes (no need to stop/start tracking).
- **Race fix**: short delay before first sample + retry if `modelContext` is nil when `process()` runs before `.onAppear`.

### Wake triggers (after fix)

| Trigger | Role |
|---------|------|
| Timer (15 / 30 / 60 min) | Primary while stationary |
| Significant location change | Movement ~500 m |
| BGAppRefreshTask | iOS fallback; always forced sample |
| Sample Now | Manual; always forced |

### Overnight & stationary reliability (Always permission)

- **`beginTracking()`** sets **`pausesLocationUpdatesAutomatically = false`**. With it **true**, iOS commonly **pauses** location while the phone looks stationary (e.g. asleep overnight), which can **interrupt** periodic background sampling despite timers.
- **Trade-off**: slightly higher location-related battery use while tracking than with auto-pause on.
- Complements the timer: **`kCLLocationAccuracyThreeKilometers`** + **`startUpdatingLocation()`** delivers **low-precision** wakes between significant-location events and BG refreshes; **`shouldSample()` / `pendingPreciseFix`** still gate when a sample (and thus OpenAQ) actually runs — not every location callback hits the API.
- **UI hints** (“Reliable overnight sampling” in `ContentView`): Always location permission, Background App Refresh, avoiding force-quitting the app, Low Power Mode caveats.

---

## 2. Battery / overheating

### Issue
Phone became hot after a few hours of tracking.

### Root cause
**High-precision, effectively continuous** location updates (`startUpdatingLocation` with tight accuracy and **`pausesLocationUpdatesAutomatically = false`** at that precision) kept the GPS subsystem active far more than needed for coarse “where am I for a 10 km monitor search?” work.

### Solution
- **Do not drive sampling with continuous high-precision GPS.** Actual sample fixes use **`requestLocation()`** (one-shot “precise fix” path) when the timer demands a measurement.
- For **Always** tracking, a **deliberately coarse** continuous stream (**~3 km** accuracy) replaces the old always-on tight-GPS behavior; **`shouldSample()`** prevents OpenAQ on every jittery callback.
- **Idle / foreground-only / stopped tracking**: keep **`pausesLocationUpdatesAutomatically = true`** (`init()`, `stopTracking()`, `beginForegroundOnly()`) until full background mode starts again — see §1 overnight note for why **active** background mode turns auto-pause **off**.

---

## 3. Exposure report & tracking windows

### Issues
- Report looked empty or unchanged (often because samples were not being saved — fixed in §1).
- No short window for quick testing.

### Root cause
Report is a **live rolling window** (not a one-time report at end of period). Empty UI = no samples in window.

### Solutions (`AirQualityModels.swift`, `ContentView.swift`, `WeeklyExposureReport.swift`)
- Added **`TrackingDuration.oneHour`** (1 Hour / 1 Day / 7 Days).
- Added **`windowInterval`** (3600 s / 86400 s / 604800 s) for filtering Recent Samples and report data.
- **`windowSamples`** uses `Date().addingTimeInterval(-windowInterval)` instead of calendar “days”.
- **`pruneOldSamples()`** uses the same interval.
- **`maxGapSeconds`** in summarize: `min(sampleInterval × 2, windowInterval / 4)` for fair TWA on short windows.
- Gray **chart captions** under line chart (per-sample PM2.5) and bar chart (daily average).

---

## 4. Alert threshold UI & logic

### Issues
- Could not set threshold below **5** (Stepper: 5…150, step 5).
- **0.2 vs 0.2** did not alert (floating-point: e.g. 0.19985 < 0.2).
- Changing threshold did not allow a new alert within the **45-minute cooldown**.

### Solutions

| Change | File |
|--------|------|
| **− / value / +** controls, step **0.1**, range **0.1–150** | `ContentView.swift` |
| Compare after **`rounded(toPlaces: 1)`** on pm25 and threshold | `ExposureAlertService.swift` |
| **`resetCooldown()`** on threshold ± buttons | `ExposureAlertService` + `ContentView` |
| **`rounded(toPlaces:)`** helper | `AirQualityFormatting.swift` |

**Alert rules (unchanged intent):** notify only if `pm25 ≥ threshold` (after rounding); max **one alert per 45 minutes** unless cooldown reset.

---

## 5. Notifications (banner + sound)

### Issues
- No banner/sound while app was open.
- Permission asked at alert time (easy to miss/deny).
- Banner auto-dismissed quickly.
- Single default ding only.

### Solutions (`Air_Pollute_TrackerApp.swift`, `ExposureAlertService.swift`)
- **`NotificationDelegate`**: `willPresent` returns `[.banner, .sound, .badge]` for foreground.
- **`requestAuthorization`** once at app launch.
- **`notifyIfNeeded`**: checks authorization status only (no mid-session prompt).
- **`interruptionLevel = .timeSensitive`** for more prominent banners.
- **`ding_ding.caf`** (two-chime) in bundle; fallback to `.default` if missing.

---

## 6. OpenAQ API key field

### Issue
API key visible in plain text.

### Solution (`ContentView.swift`)
- **`SecureField`** by default; **eye** button toggles visible `TextField`.

---

## 7. Station search radius (added, then removed)

### Issues
- Default **25 km** made mobility-sensitive estimates weak (same distant stations dominate).
- User saw **unstable PM2.5** when switching 5 / 10 / 25 km while not moving (5 → 5 stations, 10 → 1, 25 → 5).
- **`order_by=distance`** caused **HTTP 422** (OpenAQ v3 only supports **`order_by=id`** for locations).
- API does **not** guarantee nearest-first; results are limited (50) and many locations lack PM2.5.

### Changes made (then reverted for UI)
- Added `SettingsKeys.searchRadiusMeters`, picker 5 / 10 / 25 km, default **10 km**.
- Wired radius into `fetchPM25Readings`.
- Removed client `min(radius, 25_000)` cap.
- Raised fetch **limit to 50**; sort readings by `distanceMeters` client-side.
- Status line: **nearest X.X km** + station count.

### Final decision
- **Removed radius picker**; locked **`Defaults.searchRadiusMeters = 10_000`** in `ExposureTracker.swift` only.
- Avoids accidental radius changes that change which random API page of stations is used.

### Research note (Cerasti et al. / mobility)
- App records **GPS + time + IDW PM2.5** per sample → supports **mobility-based** exposure.
- **In-app static vs dynamic comparison** was discussed but **not implemented** (analysis is external).
- IDW uses your **real GPS**; accuracy depends on **which stations** OpenAQ returns, not a personal sensor.

---

## 8. Per-station PM2.5 & distance (chart callout)

### Issue
The chart **callout** for a selected sample only had **station names** (from `sourceSummary`, comma-separated). **IDW** already computes haversine distance from the device to each contributing station during blending, but **`InterpolationResult.usedReadings`** is `[StationReading]` without the distances used at interpolation time—and OpenAQ’s own `distanceMeters` on a reading may not match IDW geometry.

### Solution
- Persist a small **`ContributingStationSnapshot`** per station at save time: `name`, `pm25`, `distanceMeters` (haversine from the **same user coordinate** as IDW, via `IDWInterpolator.haversineMeters`).
- **`ExposureSample.contributorSnapshotsJSON`** stores `JSONEncoder` output (nearest-first order, matches `usedReadings`). **`sourceSummary`** kept as comma-separated names for backward compatibility / one-line summaries.
- **`SampleCallout`**: decodes JSON; if non-empty, each row is an **`HStack`** (name leading, **`formattedPM25` + formatted distance** on the right); still caps at **5** with “+ N more”. Missing/invalid/old rows fall back to the original **bullet list** from `sourceSummary`.
- **`formattedStationDistance`** on `Double` (`AirQualityFormatting.swift`): **`450 m`** if under 1 km, else **`1.2 km`** style.

### Files
`AirQualityModels.swift`, `ExposureTracker.swift`, `ContentView.swift`, `AirQualityFormatting.swift` (`IDWInterpolator.swift`: existing static haversine, no visibility change).

---

## 9. Full tracking history export (Excel-friendly CSV)

### Issue / need
Ability to **share** all stored exposure samples in a spreadsheet-friendly form **without stopping** tracking or blocking sampling timers.

### Solution
- **Toolbar** trailing: **Export history** (`square.and.arrow.up`). **Read-only**: uses `@Query` samples, sorts **oldest → newest**, writes a **temporary `.csv`**; presents **`UIActivityViewController`** (`ActivityView`). No calls into `ExposureTracker` start/stop flow.
- **CSV** opens directly in Excel: **UTF‑8 BOM**, CRLF rows, RFC-style quoted fields where needed.
- Columns: `Sample_ID`, `Timestamp_UTC` (ISO 8601), lat/lon, horizontal accuracy, PM2.5, station count, `Source_Stations`, `Contributor_Snapshots_JSON`.
- **Retention**: export includes **everything still in SwiftData** (samples already pruned by retention policy are absent—same bounds as §3 prune).

### File
`TrackingHistoryExport.swift` (CSV builder + share wrapper); wiring in `ContentView.swift`.

---

## 10. Files touched (summary)

| File | Main changes |
|------|----------------|
| `ExposureTracker.swift` | Timer-based sampling, forced BG samples, prune by `windowInterval`, 10 km radius, nearest-station status, modelContext retry; **`contributorSnapshotsJSON` encoding** |
| `ContentView.swift` | 1 h window, threshold controls, secure API key, chart captions, removed radius picker; **`SampleCallout` snapshot rows**; **export toolbar + share sheet**; **overnight sampling tips** (Always / Background App Refresh) |
| `AirQualityModels.swift` | `TrackingDuration`, `windowInterval`; **`ContributingStationSnapshot`**, **`contributorSnapshotsJSON`** |
| `WeeklyExposureReport.swift` | Dynamic `maxGapSeconds` (via caller) |
| `ExposureAlertService.swift` | Auth check, time-sensitive, custom sound, rounded compare, `resetCooldown()` |
| `Air_Pollute_TrackerApp.swift` | Notification delegate + launch authorization |
| `OpenAQClient.swift` | limit 50, no invalid `order_by`, radius param only |
| `AirQualityFormatting.swift` | `Int.nonZero`, `rounded(toPlaces:)`, **`formattedStationDistance`** |
| `TrackingHistoryExport.swift` | **CSV export + `ActivityView`** |
| `ding_ding.caf` | Notification sound asset |

---

## 11. Current app behavior (for your write-up)

1. User starts **tracking** → periodic samples at chosen interval (15 / 30 / 60 min).
2. Each sample: GPS → OpenAQ within **10 km** → **IDW** (up to 5 nearest PM2.5 stations) → save **`ExposureSample`** (including **`contributorSnapshotsJSON`** when available).
3. UI: live PM2.5, **Recent Samples**, rolling **report** (TWA, peak, charts) for 1 h / 1 d / 7 d; chart callout shows **per-station PM2.5 and distance** for new samples (**name-only** bullets for legacy rows).
4. **Export history** writes a CSV of **all retained samples** and opens the share sheet (**does not** pause tracking).
5. Alerts if rounded PM2.5 ≥ threshold (45 min cooldown; cooldown resets when threshold is changed via ±).

---

## 12. Known limitations (document honestly)

- PM2.5 is **interpolated from fixed monitors**, not measured at the phone.
- OpenAQ location list is **not sorted by distance**; only PM2.5-capable stations among the returned set are used.
- **10 km** radius is fixed for consistency across a study session.
- **Foreground-only** tracking if location permission is “When In Use” only.
- **BGAppRefreshTask** timing is controlled by iOS, not exact intervals.
- **CSV export** is not a proprietary `.xlsx`; Excel opens CSV natively. Samples deleted by **retention pruning** cannot be exported.
