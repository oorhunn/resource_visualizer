#include "include/monitor_c.h"
#include "monitor.hpp"

#include <cmath>
#include <cstring>
#include <exception>

namespace {
void copy_name(char (&target)[64], const std::string &source) {
    std::strncpy(target, source.c_str(), sizeof(target) - 1);
    target[sizeof(target) - 1] = '\0';
}
double or_nan(const std::optional<double> &value) { return value ? *value : std::nan(""); }
} // namespace

extern "C" {
size_t rv_cpu_cores(rv_core *out, size_t capacity) {
    try {
        const auto cores = monitor::collect_cpu_cores();
        // Topology never changes while running, so read the device tree once.
        static const auto topology = monitor::collect_core_topology();
        for (std::size_t i = 0; i < cores.size() && i < capacity; ++i) {
            const auto &core = cores[i];
            rv_core item{core.id, core.user, core.system, core.nice, core.idle, '?', -1};
            for (const auto &t : topology)
                if (t.id == core.id) {
                    item.type = t.type;
                    item.cluster = t.cluster;
                }
            out[i] = item;
        }
        return cores.size();
    } catch (const std::exception &) {
        return 0;
    }
}

size_t rv_processes(rv_process *out, size_t capacity) {
    try {
        const auto snapshot = monitor::collect_processes();
        const auto &processes = snapshot.processes;
        for (std::size_t i = 0; i < processes.size() && i < capacity; ++i) {
            const auto &p = processes[i];
            rv_process item{};
            item.pid = p.pid;
            copy_name(item.name, p.name);
            item.start_id = p.start_id;
            item.cpu_ns = p.cpu_ns;
            item.resident_bytes = p.resident_bytes;
            item.footprint_bytes = p.footprint_bytes;
            out[i] = item;
        }
        return processes.size();
    } catch (const std::exception &) {
        return 0;
    }
}

size_t rv_gpus(rv_gpu *out, size_t capacity) {
    try {
        const auto gpus = monitor::collect_gpus();
        for (std::size_t i = 0; i < gpus.size() && i < capacity; ++i) {
            const auto &g = gpus[i];
            rv_gpu item{};
            copy_name(item.name, g.name);
            item.utilization = or_nan(g.utilization);
            item.renderer = or_nan(g.renderer);
            item.tiler = or_nan(g.tiler);
            item.used_bytes = or_nan(g.used_bytes);
            item.allocated_bytes = or_nan(g.allocated_bytes);
            item.core_count = or_nan(g.core_count);
            out[i] = item;
        }
        return gpus.size();
    } catch (const std::exception &) {
        return 0;
    }
}

bool rv_memory_stats(rv_memory *out) {
    try {
        const auto m = monitor::collect_memory();
        *out = {m.total,      m.used,   m.app,       m.wired,
                m.compressed, m.cached, m.swap_used, m.swap_total};
        return true;
    } catch (const std::exception &) {
        return false;
    }
}
}
