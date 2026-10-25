#include "monitor.hpp"
#include "monitor_c.h"
#include "render.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>

void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}
int main() {
    try {
        require(render::bar(0, 4) == "    ", "Empty bar keeps its width");
        require(render::bar(100, 4) == "████", "Full bar");
        require(render::bar(50, 4) == "██  ", "Half bar");
        require(render::bar(12.5, 1) == "▏", "Eighth-block resolution");
        require(render::bar(250, 2) == "██", "Bar clamps above 100%");
        require(render::bar(std::nan(""), 3) == "   ", "NaN renders empty");
        require(render::bar(50, 0).empty(), "Zero-width bar");
        require(render::columns(render::bar(37, 9)) == 9, "Bar width in columns");
        require(render::level(10) == 0 && render::level(50) == 1 && render::level(80) == 2,
                "Usage levels");
        require(render::fit("abcdef", 3) == "abc", "Truncate");
        require(render::fit("ab", 4) == "ab  ", "Pad");
        require(render::fit("çğü", 2) == "çğ", "Truncate keeps UTF-8 sequences whole");
        require(render::pad_left("7", 3) == "  7", "Left pad");
        require(render::human(512.0 * 1024 * 1024) == "512 MiB", "MiB formatting");
        require(render::human(1.5 * 1024 * 1024 * 1024) == "1.5 GiB", "GiB formatting");
        require(render::printable("a\x1b[2Jb") == "a?[2Jb", "Escape sequences neutralized");
        require(render::find_ci("Google Chrome", "chrome") == 7, "Case-insensitive search");
        require(render::find_ci("abc", "abcd") == std::string::npos, "Needle longer than text");
        require(render::matches("WindowServer", 412, "server"), "Name match");
        require(render::matches("WindowServer", 412, "41"), "PID match");
        require(!render::matches("WindowServer", 412, "chrome"), "No match");
        require(render::matches("anything", 1, ""), "Empty filter matches everything");
        std::string query = "aç";
        render::pop_char(query);
        require(query == "a", "Backspace removes a whole UTF-8 character");
        render::pop_char(query);
        render::pop_char(query);
        require(query.empty(), "Backspace on empty filter");
        const auto memory = monitor::collect_memory();
        require(memory.total == monitor::physical_memory(), "Memory total matches installed RAM");
        require(memory.used > 0 && memory.used == memory.app + memory.wired + memory.compressed,
                "Memory used accounting");
        const auto topology = monitor::collect_core_topology();
        const auto cores = monitor::collect_cpu_cores();
        // Intel Macs report no topology; when present it must cover every core exactly once.
        require(topology.empty() || topology.size() == cores.size(), "Topology covers all cores");
        for (std::size_t i = 0; i < topology.size(); ++i)
            require(topology[i].id == i && (topology[i].type == 'P' || topology[i].type == 'E'),
                    "Topology ids and types");
        // C bridge used by the Swift app.
        rv_core bridged[256];
        const auto core_count = rv_cpu_cores(bridged, 256);
        require(core_count == cores.size(), "Bridge reports every core");
        require(core_count > 0 && rv_cpu_cores(bridged, 1) == core_count,
                "Bridge returns the full count when capacity is short");
        for (std::size_t i = 0; i < topology.size(); ++i)
            require(bridged[i].type == topology[i].type, "Bridge carries core types");
        rv_memory bridged_memory{};
        require(rv_memory_stats(&bridged_memory) && bridged_memory.total == memory.total,
                "Bridge memory totals");
        rv_process one{};
        const auto process_count = rv_processes(&one, 1);
        require(process_count > 1 && one.pid > 0 && one.name[0] != '\0',
                "Bridge fills processes up to capacity");
        std::cout << "All visualizer tests passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAILED: " << error.what() << '\n';
        return 1;
    }
}
