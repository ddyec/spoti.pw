#pragma once
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>

typedef struct { double cpu, memory, delay; } SGPerfPoint;
typedef struct { double cpu, memory, p95; size_t count; } SGPerfSummary;
static inline int SGPerfCompare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
// A fixed one-minute window. Reject invalid counters instead of reporting false improvements.
static inline SGPerfSummary SGPerfSummarize(const SGPerfPoint *points, size_t count) {
    SGPerfSummary result = {0};
    double delays[30];
    if (count > 30) { points += count - 30; count = 30; }
    for (size_t i = 0; i < count; i++) {
        SGPerfPoint p = points[i];
        if (!isfinite(p.cpu) || !isfinite(p.memory) || !isfinite(p.delay) ||
            p.cpu < 0 || p.memory <= 0 || p.delay < 0) continue;
        result.cpu += p.cpu;
        result.memory += p.memory;
        delays[result.count++] = p.delay;
    }
    if (result.count) {
        result.cpu /= result.count;
        result.memory /= result.count;
        qsort(delays, result.count, sizeof(double), SGPerfCompare);
        result.p95 = delays[(size_t)ceil(result.count * 0.95) - 1];
    }
    return result;
}
// Relative AND absolute floors prevent near-zero baselines producing noisy warnings.
static inline bool SGPerfRegressed(SGPerfSummary current, SGPerfSummary baseline) {
    return current.count >= 30 && baseline.count >= 30 &&
        ((current.cpu > baseline.cpu * 1.25 && current.cpu > baseline.cpu + 10) ||
         (current.memory > baseline.memory * 1.20 && current.memory > baseline.memory + 30) ||
         (current.p95 > baseline.p95 * 1.50 && current.p95 > baseline.p95 + 50));
}
