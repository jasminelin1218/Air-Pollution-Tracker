<p align="center">
  <img width="256" height="256" alt="AppIcon" src="https://github.com/user-attachments/assets/75e5cbe2-4de4-4e6e-8178-55d7792178fb" />
</p>
<h1 align="center">Air Pollute Tracker</h1>

A native iOS app that estimates your personal PM2.5 exposure in real time by
continuously recording your GPS location, querying the
[OpenAQ](https://openaq.org) public monitor network, and blending nearby
station readings with Inverse Distance Weighting (IDW) interpolation. All
data stay on-device for privacy.

---

## Why this exists

Fixed air-quality monitors capture regional background pollution — not what
you personally breathe as you move through the day. This app follows *you*,
not a station, so you can see the difference between sitting at home and
going outside.

---

## Features

- **Real-time IDW interpolation** over the 3–5 nearest OpenAQ stations
  (p = 2, Haversine distances)
- **Background tracking** that runs overnight and through locked screens,
  using a hybrid of one-shot GPS fixes, significant-location-change events,
  and `BGAppRefreshTask` fallback — without keeping the GPS radio on
  continuously
- **Time-weighted average (TWA)** exposure report with configurable windows:
  1 hour, 6 hours, 1 day, 2 days, 4 days, or 7 days
- **Scrollable per-sample chart** with tappable callouts showing each
  contributing monitor's reported value and distance
- **Daily-average trend chart** for seeing exposure change over a week
- **Adjustable alert threshold** (slider, default 35.5 µg/m³) with a
  45-minute cooldown and a custom two-chime notification sound
- **Session report** sheet shown when you stop tracking (TWA, peak,
  tracked time, high-exposure time)
- **CSV export** with reverse-geocoded city/country and Pacific time
  columns — ready for offline analysis
- **Secure API key** entry with show/hide toggle; key never committed to
  source control

---

## Requirements

| Requirement | Version |
|---|---|
| iOS | 17.0+ |
| Xcode | 15.0+ |
| Swift | 5.9+ |
| OpenAQ API key | Free |

---

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/jasminelin1218/Air-Pollution-Tracker.git
cd Air-Pollution-Tracker
```

### 2. Add your OpenAQ API key

Copy the example secrets file and fill in your key:

```bash
cp Secrets.xcconfig.example Secrets.xcconfig
```

Open `Secrets.xcconfig` and replace the placeholder:

```
OPENAQ_API_KEY = your_key_here
```

> `Secrets.xcconfig` is listed in `.gitignore` and will never be committed.
> Alternatively, you can skip this step and paste your key directly in the
> app's Settings card at runtime.

### 3. Open and run

Open `Air_Pollute_Tracker.xcodeproj` in Xcode, select your target device or
simulator, and press **Run** (⌘R).

On first launch:
- Tap **Start Tracking** and grant **Always** location permission for
  background sampling (the app also works foreground-only with *While Using*).
- Enable **Settings → General → Background App Refresh** for this app.
- Do not force-quit the app from the app switcher — iOS will not relaunch it
  for background refreshes.

---

## Project structure

```
Air_Pollute_Tracker/
├── Air_Pollute_TrackerApp.swift   Entry point; registers BGTask, sets up
│                                  notification delegate
├── ContentView.swift              Main UI: status card, report, settings,
│                                  recent samples list, share sheet
├── ExposureTracker.swift          Core coordinator: location manager,
│                                  sampling pipeline, background scheduling
├── OpenAQClient.swift             OpenAQ v3 REST client (locations + latest)
├── IDWInterpolator.swift          IDW + Haversine; includes a debug self-test
├── AirQualityModels.swift         Data models: ExposureSample (SwiftData),
│                                  StationReading, TrackingDuration, etc.
├── WeeklyExposureReport.swift     TWA calculation, daily breakdown,
│                                  session report model
├── ExposureAlertService.swift     Local notification with cooldown and
│                                  custom ding-dong sound
├── TrackingHistoryExport.swift    Async CSV builder with reverse geocoding
│                                  and Excel-compatible UTF-8 BOM output
└── AirQualityFormatting.swift     Shared formatters (µg/m³, hours, distance)

Development log: bugs found and fixes applied

```

---

## How the sampling pipeline works

```
Timer fires (15 / 30 / 60 min)
     │
     ▼
requestLocation()  ─── one-shot precise GPS fix
     │
     ▼
OpenAQClient  ─── GET /v3/locations (10 km radius, PM2.5 only)
     │               GET /v3/locations/{id}/latest  (per station)
     │
     ▼
IDWInterpolator  ─── sort by Haversine distance
     │               weight = 1 / d²,  blend 3–5 nearest stations
     │
     ▼
ExposureSample  ─── saved to SwiftData (on-device)
     │               includes per-station snapshot for callouts
     │
     ├──► WeeklyExposureReport  ─── recompute TWA for UI
     └──► ExposureAlertService  ─── notify if ≥ threshold
```

Background execution is maintained by three complementary mechanisms:
1. **Repeating chained timer** — schedules the next `requestLocation()` call
   from the timestamp of the last successful sample.
2. **Significant-location-change** — fires ~500 m of movement; ensures
   transitions between places are captured immediately.
3. **BGAppRefreshTask** — iOS-managed periodic wakeup; acts as a fallback
   when the device is stationary for a long time.

## Demo Video
https://youtube.com/shorts/7sGxT79CNoU?feature=share






   


