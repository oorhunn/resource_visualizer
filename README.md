# Resource Visualizer

A live, full-screen terminal dashboard for macOS showing per-core CPU, system memory,
GPU, and the busiest processes as colored bars. C++17, no dependencies beyond the
system frameworks.

It also ships a small local web dashboard (`resource-web`) with a per-core CPU
heatmap. The data backend (`src/monitor/`) reads everything through Mach host
statistics, `libproc`, `sysctl`, and IOKit.

## Build and run

Requires macOS 12+, Xcode Command Line Tools, and CMake 3.20+.

```sh
cmake -S . -B build
cmake --build build -j 4
ctest --test-dir build --output-on-failure
./build/resource-visualizer
./build/resource-visualizer --interval 0.5 --sort mem
```

| Key   | Action                                      |
|-------|---------------------------------------------|
| `q`   | Quit (Ctrl+C also works)                    |
| `/`   | Filter processes by name or PID (case-insensitive, live as you type) |
| `Enter` / `Esc` | Keep the filter / clear it (Backspace and Ctrl+U edit it) |
| `c` `m` `p` | Sort processes by CPU, memory (RSS), or PID |
| `+` `-` | Change refresh interval (0.25–10 s)       |

Bars are green below 50%, yellow below 80%, red above. The layout adapts to the
terminal size, and the process list fills the remaining rows. While filtering,
the header shows matches/total and the matched text is highlighted in each name.

## Web dashboard

`resource-web` serves a browser view of per-core CPU activity:

```sh
./build/resource-web                      # then open http://127.0.0.1:8765
./build/resource-web --port 9000 --interval 0.5
```

- **Tiles** show average busy % for all cores and for each core type.
- **Right now** shows one bar per core, split into user (blue) and system (orange) time,
  grouped into Performance and Efficiency cores.
- **Last 2 minutes** is a heatmap with one row per core and one column per sample;
  darker/lighter blue means busier depending on the color scheme (see the scale).
  Hover any cell or bar for exact values. A table view is at the bottom.

Core types come from the IORegistry device tree (`cluster-type`), so Apple Silicon
shows P/E groups; Intel Macs show a single "Cores" group. The server listens on
127.0.0.1 only, keeps history in memory, and exposes the data at `/api/stats` (JSON).
`web/index.html` is embedded into the binary at build time; rebuild after editing it.

## What the numbers mean

- **CPU** is the average busy time across logical cores; each core row is 0–100%.
  Process CPU% counts one full core as 100%, so it can exceed 100%. Values read `N/A`
  until the second sample.
- **MEM used** = app + wired + compressed (Activity Monitor's "Memory Used"). Cached
  covers file-backed and purgeable pages the system can reclaim.
- **Process RAM** is resident set size; shared pages are counted in every process.
- **GPU** values are optional IOAccelerator driver statistics. On Apple Silicon, GPU
  memory is shared with system RAM.

## Layout

- `src/monitor/` — macOS data collection (`monitor.hpp` is the platform boundary)
- `src/visualizer/render.hpp` — pure text helpers (bars, padding, formatting)
- `src/visualizer/main.cpp` — terminal handling, layout, and the refresh loop
- `src/web/` — local HTTP server for the dashboard (`http.hpp` holds the pure helpers)
- `web/index.html` — the dashboard page (no external dependencies)
- `tests/cpp/` — unit tests for the helpers and memory accounting
