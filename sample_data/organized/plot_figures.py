#!/usr/bin/env python3
"""
Generate report figures from the organized CSV packs.

Usage:
    pip install matplotlib
    python3 plot_figures.py

Reads the CSV files that live next to this script and writes PNGs into ./figures/.
Each finding is its own function so you can comment out any you do not need.
"""

import csv
import os

import matplotlib
matplotlib.use("Agg")  # no display needed; writes files
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
FIGDIR = os.path.join(HERE, "figures")
os.makedirs(FIGDIR, exist_ok=True)


def load(name):
    """Load a CSV (next to this script) as a list of dict rows."""
    with open(os.path.join(HERE, name), newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def save(fig, name):
    path = os.path.join(FIGDIR, name)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  wrote {os.path.relpath(path, HERE)}")


# ---------------------------------------------------------------- 1. Diurnal
def fig_diurnal():
    rows = load("08_diurnal_cycle.csv")
    hours = [int(r["Hour_Pacific"]) for r in rows]
    mean = [fnum(r["Mean_PM25"]) for r in rows]
    dorm = [fnum(r["Dorm_Mean_PM25"]) for r in rows]
    out = [fnum(r["Outside_Mean_PM25"]) for r in rows]

    fig, ax = plt.subplots(figsize=(8, 4.2))
    ax.plot(hours, mean, marker="o", label="All", linewidth=2)
    ax.plot(hours, dorm, marker="s", label="Dorm (static)", alpha=0.8)
    ax.plot(hours, out, marker="^", label="Outside (dynamic)", alpha=0.8)
    ax.set_xlabel("Hour of day (Pacific)")
    ax.set_ylabel("Mean PM2.5 (ug/m3)")
    ax.set_title("Diurnal PM2.5 cycle")
    ax.set_xticks(range(0, 24, 2))
    ax.grid(True, alpha=0.3)
    ax.legend()
    save(fig, "fig1_diurnal_cycle.png")


# ------------------------------------------------------- 2. Health / guideline
def fig_health():
    hist = load("09_health_pm25_histogram.csv")
    centers = [(fnum(r["Bin_Low"]) + fnum(r["Bin_High"])) / 2 for r in hist]
    counts = [int(r["Count"]) for r in hist]

    guides = load("09_health_guidelines.csv")
    glines = [(r["Guideline"], fnum(r["Value_ug_m3"]))
              for r in guides if fnum(r["Value_ug_m3"]) is not None]

    fig, ax = plt.subplots(figsize=(8, 4.2))
    ax.bar(centers, counts, width=0.9, alpha=0.75, label="Samples")
    for name, val in glines:
        ax.axvline(val, linestyle="--", linewidth=1.5)
        ax.text(val, max(counts) * 0.92, f" {name}\n {val:g}",
                rotation=90, va="top", fontsize=8)
    ax.set_xlabel("PM2.5 (ug/m3)")
    ax.set_ylabel("Sample count")
    ax.set_title("PM2.5 distribution vs health guidelines")
    ax.grid(True, axis="y", alpha=0.3)
    save(fig, "fig2_health_guidelines.png")


# ------------------------------------------------ 3. Method / data quality
def fig_station_quality():
    rows = load("10_station_quality.csv")
    names = [r["Station"] for r in rows]
    means = [fnum(r["Mean_PM25"]) for r in rows]
    rng = [fnum(r["Range_PM25"]) for r in rows]
    colors = ["#c0392b" if r["Is_Constant"] == "yes" else "#2c7fb8" for r in rows]

    fig, ax = plt.subplots(figsize=(8, 4.6))
    y = range(len(names))
    # bar = mean, error bar = full range (shows constant vs varying stations)
    ax.barh(list(y), means, color=colors, alpha=0.8)
    for i, r in enumerate(rng):
        ax.errorbar(means[i], i, xerr=r / 2, fmt="none", ecolor="black",
                    capsize=4, alpha=0.6)
    ax.set_yticks(list(y))
    ax.set_yticklabels(names, fontsize=8)
    ax.set_xlabel("Mean PM2.5 (ug/m3); bar color red = constant/stale reading")
    ax.set_title("Per-station PM2.5 (IDW inputs): variability & data quality")
    ax.grid(True, axis="x", alpha=0.3)
    save(fig, "fig3a_station_quality.png")


def fig_idw_spread():
    rows = load("10_idw_spread_histogram.csv")
    centers = [(fnum(r["Bin_Low"]) + fnum(r["Bin_High"])) / 2 for r in rows]
    counts = [int(r["Count"]) for r in rows]

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.bar(centers, counts, width=1.8, alpha=0.8)
    ax.set_xlabel("Max - min station PM2.5 within a sample (ug/m3)")
    ax.set_ylabel("Sample count")
    ax.set_title("IDW input spread (why multi-station matters)")
    ax.grid(True, axis="y", alpha=0.3)
    save(fig, "fig3b_idw_spread.png")


# ------------------------------------------------ 4. System performance
def fig_cadence():
    rows = load("11_sampling_cadence_histogram.csv")
    labels = []
    for r in rows:
        hi = fnum(r["Bin_High_min"])
        labels.append(f">{int(fnum(r['Bin_Low_min']))}" if hi >= 9999
                      else f"{int(fnum(r['Bin_Low_min']))}-{int(hi)}")
    counts = [int(r["Count"]) for r in rows]

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.bar(labels, counts, alpha=0.8, color="#2c7fb8")
    ax.set_xlabel("Inter-sample gap (minutes)")
    ax.set_ylabel("Count")
    ax.set_title("Sampling cadence reliability")
    ax.grid(True, axis="y", alpha=0.3)
    save(fig, "fig4a_sampling_cadence.png")


def fig_gps():
    rows = load("11_gps_accuracy_histogram.csv")
    labels = []
    for r in rows:
        hi = fnum(r["Bin_High_m"])
        labels.append(f">{int(fnum(r['Bin_Low_m']))}" if hi >= 9999
                      else f"{int(fnum(r['Bin_Low_m']))}-{int(hi)}")
    counts = [int(r["Count"]) for r in rows]

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.bar(labels, counts, alpha=0.8, color="#41ab5d")
    ax.set_xlabel("Horizontal GPS accuracy (m)")
    ax.set_ylabel("Count")
    ax.set_title("GPS fix quality")
    ax.grid(True, axis="y", alpha=0.3)
    save(fig, "fig4b_gps_accuracy.png")


def main():
    print("Generating figures...")
    fig_diurnal()
    fig_health()
    fig_station_quality()
    fig_idw_spread()
    fig_cadence()
    fig_gps()
    print(f"Done. PNGs in {os.path.relpath(FIGDIR, HERE)}/")


if __name__ == "__main__":
    main()
