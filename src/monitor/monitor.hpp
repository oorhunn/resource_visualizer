#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace monitor {
struct Process {
    int pid;
    std::string name;
    std::uint64_t start_id;
    std::uint64_t cpu_ns;
    std::uint64_t resident_bytes;
    std::uint64_t footprint_bytes;
    std::chrono::steady_clock::time_point sampled_at;
};
struct Snapshot {
    std::vector<Process> processes;
    std::size_t skipped = 0;
};
struct CpuCore {
    unsigned int id;
    std::uint32_t user, system, nice, idle;
};
struct CoreUsage {
    double busy, user, system, nice, idle;
};
// Unsigned subtraction accounts for one wrap of the kernel's 32-bit tick counters.
inline std::optional<CoreUsage> core_usage(const CpuCore &before, const CpuCore &after) {
    if (before.id != after.id)
        return std::nullopt;
    const auto user = static_cast<std::uint32_t>(after.user - before.user);
    const auto system = static_cast<std::uint32_t>(after.system - before.system);
    const auto nice = static_cast<std::uint32_t>(after.nice - before.nice);
    const auto idle = static_cast<std::uint32_t>(after.idle - before.idle);
    const double total = static_cast<double>(user) + system + nice + idle;
    if (total == 0)
        return std::nullopt;
    return CoreUsage{100.0 * (static_cast<double>(user) + system + nice) / total,
                     100.0 * user / total, 100.0 * system / total, 100.0 * nice / total,
                     100.0 * idle / total};
}
struct Gpu {
    std::string name;
    std::optional<double> utilization;
    std::optional<double> renderer;
    std::optional<double> tiler;
    std::optional<double> used_bytes;
    std::optional<double> allocated_bytes;
    std::optional<double> core_count;
};
// System-wide memory in bytes; used = app + wired + compressed, as in Activity Monitor.
struct Memory {
    std::uint64_t total = 0, used = 0, app = 0, wired = 0, compressed = 0, cached = 0;
    std::uint64_t swap_used = 0, swap_total = 0;
};
// Core cluster from the device tree: 'P' performance, 'E' efficiency, '?' unknown.
struct CoreTopology {
    unsigned int id;
    char type;
    int cluster; // -1 when unknown
};
// Platform boundary: implement these functions for a future Linux backend.
Snapshot collect_processes();
Memory collect_memory();
std::vector<CpuCore> collect_cpu_cores();
// Empty where the platform does not describe core types (e.g. Intel Macs).
std::vector<CoreTopology> collect_core_topology();
std::vector<Gpu> collect_gpus();
std::uint64_t physical_memory();

inline std::optional<double> cpu_percent(const Process &before, const Process &after) {
    const auto elapsed =
        std::chrono::duration<double>(after.sampled_at - before.sampled_at).count();
    if (before.pid != after.pid || before.start_id != after.start_id ||
        after.cpu_ns < before.cpu_ns || elapsed <= 0) {
        return std::nullopt;
    }
    return static_cast<double>(after.cpu_ns - before.cpu_ns) / (elapsed * 1e9) * 100.0;
}
} // namespace monitor
