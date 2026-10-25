#pragma once

// C interface over the C++ backend so the Swift app can call it without C++ interop.
// Every function returns 0 / false on failure instead of throwing.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned int id;
    uint32_t user, system, nice, idle;
    char type;   // 'P' performance, 'E' efficiency, '?' unknown
    int cluster; // -1 when unknown
} rv_core;

typedef struct {
    uint64_t total, used, app, wired, compressed, cached, swap_used, swap_total;
} rv_memory;

typedef struct {
    int pid;
    char name[64];
    uint64_t start_id, cpu_ns, resident_bytes, footprint_bytes;
} rv_process;

// Optional values are NaN when the driver does not report them.
typedef struct {
    char name[64];
    double utilization, renderer, tiler, used_bytes, allocated_bytes, core_count;
} rv_gpu;

// Each list function returns the number of items available and fills at most `capacity`.
size_t rv_cpu_cores(rv_core *out, size_t capacity);
size_t rv_processes(rv_process *out, size_t capacity);
size_t rv_gpus(rv_gpu *out, size_t capacity);
bool rv_memory_stats(rv_memory *out);

#ifdef __cplusplus
}
#endif
