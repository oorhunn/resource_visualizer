#include "monitor.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <cmath>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <sys/sysctl.h>

#include <algorithm>
#include <stdexcept>

namespace monitor {
Snapshot collect_processes() {
    int needed = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    if (needed <= 0)
        throw std::runtime_error("Cannot enumerate processes");
    std::vector<int> pids;
    int bytes = 0;
    // Allow headroom and retry if the process list grew during enumeration.
    for (;;) {
        pids.resize(static_cast<std::size_t>(needed) / sizeof(int) + 256);
        bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.data(),
                              static_cast<int>(pids.size() * sizeof(int)));
        if (bytes <= 0)
            throw std::runtime_error("Cannot read process list");
        if (static_cast<std::size_t>(bytes) < pids.size() * sizeof(int))
            break;
        needed = bytes + 1024;
    }
    pids.resize(static_cast<std::size_t>(bytes) / sizeof(int));
    mach_timebase_info_data_t timebase{};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0)
        throw std::runtime_error("Cannot read Mach timebase");
    Snapshot result;
    for (int pid : pids) {
        if (pid <= 0)
            continue;
        rusage_info_v2 usage{};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, reinterpret_cast<rusage_info_t *>(&usage)) != 0) {
            ++result.skipped;
            continue;
        }
        const auto timestamp = std::chrono::steady_clock::now();
        char name[PROC_PIDPATHINFO_MAXSIZE]{};
        if (proc_name(pid, name, sizeof(name)) <= 0)
            name[0] = '\0';
        result.processes.push_back(
            {pid, name[0] ? name : "[unknown]", usage.ri_proc_start_abstime,
             static_cast<std::uint64_t>(
                 (static_cast<long double>(usage.ri_user_time) + usage.ri_system_time) *
                 timebase.numer / timebase.denom),
             usage.ri_resident_size, usage.ri_phys_footprint, timestamp});
    }
    return result;
}

std::uint64_t physical_memory() {
    std::uint64_t bytes = 0;
    std::size_t size = sizeof(bytes);
    if (sysctlbyname("hw.memsize", &bytes, &size, nullptr, 0) != 0)
        throw std::runtime_error("Cannot read physical memory size");
    return bytes;
}

Memory collect_memory() {
    vm_statistics64_data_t vm{};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&vm),
                          &count) != KERN_SUCCESS)
        throw std::runtime_error("Cannot read virtual memory statistics");
    const std::uint64_t page = vm_kernel_page_size;
    Memory memory;
    memory.total = physical_memory();
    // Purgeable pages can be reclaimed instantly, so count them as cache rather than app memory.
    memory.app = page * (vm.internal_page_count > vm.purgeable_count
                             ? vm.internal_page_count - vm.purgeable_count
                             : 0);
    memory.wired = page * vm.wire_count;
    memory.compressed = page * vm.compressor_page_count;
    memory.cached = page * (static_cast<std::uint64_t>(vm.external_page_count) + vm.purgeable_count);
    memory.used = memory.app + memory.wired + memory.compressed;
    xsw_usage swap{};
    std::size_t size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, nullptr, 0) == 0) {
        memory.swap_used = swap.xsu_used;
        memory.swap_total = swap.xsu_total;
    }
    return memory;
}

std::vector<CpuCore> collect_cpu_cores() {
    natural_t count = 0;
    processor_info_array_t info = nullptr;
    mach_msg_type_number_t size = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &size) !=
        KERN_SUCCESS)
        throw std::runtime_error("Cannot read CPU core counters");
    // Release the Mach-allocated array even if vector allocation throws.
    struct Buffer {
        processor_info_array_t data;
        mach_msg_type_number_t size;
        ~Buffer() {
            vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(data),
                          size * sizeof(integer_t));
        }
    } buffer{info, size};
    if (size / PROCESSOR_CPU_LOAD_INFO_COUNT < count)
        throw std::runtime_error("Incomplete CPU core counters");
    std::vector<CpuCore> cores;
    for (unsigned int i = 0; i < count; ++i) {
        const auto ticks = reinterpret_cast<processor_cpu_load_info_t>(info)[i].cpu_ticks;
        cores.push_back({i, ticks[CPU_STATE_USER], ticks[CPU_STATE_SYSTEM], ticks[CPU_STATE_NICE],
                         ticks[CPU_STATE_IDLE]});
    }
    return cores;
}

namespace {
std::optional<double> number(CFDictionaryRef dictionary, CFStringRef key, bool percent = false) {
    auto value = CFDictionaryGetValue(dictionary, key);
    double result = 0;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
        !CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType, &result) ||
        !std::isfinite(result) || result < 0 || (percent && result > 100))
        return std::nullopt;
    return result;
}
// Device-tree integers appear either as CFNumber or as little-endian 32-bit CFData.
std::optional<std::uint32_t> registry_integer(io_registry_entry_t entry, CFStringRef key) {
    auto value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value)
        return std::nullopt;
    std::optional<std::uint32_t> result;
    std::int64_t number = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        if (CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt64Type, &number) &&
            number >= 0 && number <= UINT32_MAX)
            result = static_cast<std::uint32_t>(number);
    } else if (CFGetTypeID(value) == CFDataGetTypeID() &&
               CFDataGetLength(static_cast<CFDataRef>(value)) >= 4) {
        const UInt8 *bytes = CFDataGetBytePtr(static_cast<CFDataRef>(value));
        result = static_cast<std::uint32_t>(bytes[0]) | static_cast<std::uint32_t>(bytes[1]) << 8 |
                 static_cast<std::uint32_t>(bytes[2]) << 16 |
                 static_cast<std::uint32_t>(bytes[3]) << 24;
    }
    CFRelease(value);
    return result;
}
} // namespace

std::vector<CoreTopology> collect_core_topology() {
    std::vector<CoreTopology> result;
    io_registry_entry_t cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus");
    if (cpus == IO_OBJECT_NULL)
        return result;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS) {
        io_registry_entry_t cpu;
        while ((cpu = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            const auto id = registry_integer(cpu, CFSTR("logical-cpu-id"));
            const auto cluster = registry_integer(cpu, CFSTR("logical-cluster-id"));
            char type = '?';
            auto kind = IORegistryEntryCreateCFProperty(cpu, CFSTR("cluster-type"),
                                                        kCFAllocatorDefault, 0);
            if (kind) {
                if (CFGetTypeID(kind) == CFDataGetTypeID() &&
                    CFDataGetLength(static_cast<CFDataRef>(kind)) > 0) {
                    const auto c = CFDataGetBytePtr(static_cast<CFDataRef>(kind))[0];
                    if (c == 'P' || c == 'E')
                        type = static_cast<char>(c);
                }
                CFRelease(kind);
            }
            if (id)
                result.push_back({*id, type, cluster ? static_cast<int>(*cluster) : -1});
            IOObjectRelease(cpu);
        }
        IOObjectRelease(iterator);
    }
    IOObjectRelease(cpus);
    std::sort(result.begin(), result.end(),
              [](const CoreTopology &a, const CoreTopology &b) { return a.id < b.id; });
    return result;
}

std::vector<Gpu> collect_gpus() {
    std::vector<Gpu> result;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                     &iterator) != KERN_SUCCESS)
        return result;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name{};
        IORegistryEntryGetName(service, name);
        Gpu gpu{};
        gpu.name = name;
        auto cores = IORegistryEntryCreateCFProperty(service, CFSTR("gpu-core-count"),
                                                     kCFAllocatorDefault, 0);
        if (cores) {
            double count = 0;
            if (CFGetTypeID(cores) == CFNumberGetTypeID() &&
                CFNumberGetValue(static_cast<CFNumberRef>(cores), kCFNumberDoubleType, &count) &&
                std::isfinite(count) && count > 0)
                gpu.core_count = count;
            CFRelease(cores);
        }
        auto property = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"),
                                                        kCFAllocatorDefault, 0);
        if (property && CFGetTypeID(property) == CFDictionaryGetTypeID()) {
            auto dictionary = static_cast<CFDictionaryRef>(property);
            gpu.utilization = number(dictionary, CFSTR("Device Utilization %"), true);
            gpu.renderer = number(dictionary, CFSTR("Renderer Utilization %"), true);
            gpu.tiler = number(dictionary, CFSTR("Tiler Utilization %"), true);
            gpu.used_bytes = number(dictionary, CFSTR("In use system memory"));
            gpu.allocated_bytes = number(dictionary, CFSTR("Alloc system memory"));
        }
        if (property)
            CFRelease(property);
        result.push_back(gpu);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return result;
}
} // namespace monitor
