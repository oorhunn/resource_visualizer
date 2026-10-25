# Resource Visualizer

A native macOS resource monitor that lives in the notch. CPU and memory sit on either
side of the notch; hover over it to expand a compact panel with per-core load, memory,
GPU, and the busiest processes. A full dashboard window has history charts, a memory
breakdown, and a sortable process table.

The data layer is a small C++17 backend that reads Mach host statistics, `libproc`,
`sysctl`, and IOKit directly; the app is SwiftUI/AppKit on top of a thin C bridge.
A terminal UI built on the same backend is included as well.

## Build and run

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode is not needed).

```sh
scripts/bundle.sh                 # → build/ResourceVisualizer.app
open build/ResourceVisualizer.app
```

`swift run ResourceVisualizer` also works for quick iteration, without the app bundle.

### Notch

- The wings show average CPU (left) and memory used (right), colored green below 50%,
  yellow below 80%, red above.
- Hover the notch to expand it; move away to collapse. **Open Dashboard** brings up the
  window, **Quit** exits.
- On displays without a notch it appears as a small pill in the middle of the menu bar.
- Toggle it with **Resource Visualizer → Show in Notch** (⇧⌘N). It hides itself in
  full-screen apps.

### Dashboard

- **Tiles** for CPU, memory, GPU, and swap.
- **Last 2 minutes**: CPU and memory history.
- **Memory**: app, wired, compressed, and cached breakdown.
- **Cores**: one bar per core split into user (blue) and system (orange) time, grouped
  into Performance and Efficiency cores on Apple Silicon.
- **Processes**: filter by name or PID; click a column header to sort.

Closing the window keeps the notch running; reopen it from the Dock icon or with ⌘1.

## Terminal UI

```sh
cmake -S . -B build
cmake --build build -j 4
ctest --test-dir build --output-on-failure
./build/resource-visualizer --interval 0.5 --sort mem
```

| Key   | Action                                      |
|-------|---------------------------------------------|
| `q`   | Quit (Ctrl+C also works)                    |
| `/`   | Filter processes by name or PID (live as you type) |
| `Enter` / `Esc` | Keep the filter / clear it        |
| `c` `m` `p` | Sort processes by CPU, memory (RSS), or PID |
| `+` `-` | Change refresh interval (0.25–10 s)       |

## What the numbers mean

- **CPU** is the average busy time across logical cores; each core is 0–100%.
  Process CPU% counts one full core as 100%, so it can exceed 100%.
- **Memory used** = app + wired + compressed (Activity Monitor's "Memory Used"). Cached
  covers file-backed and purgeable pages the system can reclaim.
- **Process memory** is resident set size; shared pages are counted in every process.
- **GPU** values are optional IOAccelerator driver statistics. On Apple Silicon, GPU
  memory is shared with system RAM.
- Core types come from the IORegistry device tree (`cluster-type`); Intel Macs show a
  single "Cores" group.

## Layout

- `src/monitor/` — macOS data collection (`monitor.hpp` is the platform boundary,
  `include/monitor_c.h` + `bridge.cpp` expose it to Swift)
- `app/ResourceVisualizer/` — the SwiftUI app: sampling (`Monitor.swift`), notch panel
  (`Notch.swift`), dashboard window (`DashboardView.swift`)
- `src/visualizer/` — the terminal UI
- `scripts/bundle.sh` — builds the `.app` bundle
- `tests/cpp/` — unit tests for the backend, bridge, and text helpers
