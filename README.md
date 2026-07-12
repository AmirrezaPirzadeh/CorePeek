# Lightweight CPU Usage

A minimal, native macOS menu bar app for real-time system monitoring — CPU, memory, disk, and network — built entirely with SwiftUI and low-level Mach/BSD APIs. No Electron, no background daemons, just a lightweight `MenuBarExtra`.

## Features

- **CPU usage** — total and per-core load, sampled via `host_processor_info`, with a configurable refresh interval (1s / 2s / 5s / 10s)
- **Memory** — used vs. total system RAM via `host_statistics64`
- **Disk** — used vs. total capacity of the home volume
- **Network** — live download/upload throughput (KB/s), sampled from active network interfaces
- **Top processes** — top 5 CPU-consuming processes, refreshed every 5 seconds (via `ps`)
- **Menu bar display modes** — choose between:
  - Percentage (color-coded: green/orange/red by load)
  - Icon only
  - Mini sparkline graph of recent CPU history
- **High-usage alerts** — local notification when CPU usage crosses a configurable threshold (70–95%, or off), with a cooldown to avoid spam
- **Launch at login** — toggle via `ServiceManagement` (`SMAppService`)

## How it works

- `CPUMonitor` polls `host_processor_info` on a timer, diffing tick counts between samples to compute per-core and total utilization, and keeps a rolling history for the sparkline view.
- `DiskMonitor` and `NetworkMonitor` sample volume resource values and interface byte counters respectively.
- `ProcessMonitor` shells out to `ps -Aceo pcpu,comm -r` to list the top CPU consumers.
- `NotificationManager` posts local user notifications when usage exceeds the configured threshold.
- All settings (refresh interval, display style, alert threshold, top-process visibility) persist via `@AppStorage`.

## Requirements

- macOS 13 or later (uses `MenuBarExtra`)

## Installation

1. Download the latest `.app` from the [Releases](../../releases) page.
2. Move it to `/Applications`.
3. Open it. Since the app isn't notarized/signed by an Apple Developer ID, macOS Gatekeeper will likely block it on first launch — right-click the app and choose **Open**, or go to **System Settings → Privacy & Security** and allow it.
4. Grant notification permission when prompted (used for high-usage alerts).

The app lives entirely in the menu bar (`MenuBarExtra`) — no dock icon or main window.

## License

Add your license of choice here.
