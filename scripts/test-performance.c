#include "../tweak/Sources/Diagnostics/SGPerformanceMath.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    SGPerfPoint points[35];
    for (size_t i = 0; i < 35; i++) points[i] = (SGPerfPoint){20, 100, (double)i};
    SGPerfSummary base = SGPerfSummarize(points, 30);
    assert(base.count == 30 && base.cpu == 20 && base.memory == 100 && base.p95 == 28);
    SGPerfSummary tail = SGPerfSummarize(points, 35);
    assert(tail.count == 30 && tail.p95 == 33);
    assert(!SGPerfRegressed(base, base));
    SGPerfSummary high = base;
    high.cpu = 31; assert(SGPerfRegressed(high, base));
    high.cpu = 29; assert(!SGPerfRegressed(high, base));
    high = base; high.memory = 131; assert(SGPerfRegressed(high, base));
    high.memory = 129; assert(!SGPerfRegressed(high, base));
    high = base; high.p95 = 79; assert(SGPerfRegressed(high, base));
    high.p95 = 77; assert(!SGPerfRegressed(high, base));
    high.count = 29; assert(!SGPerfRegressed(high, base));
    points[0].cpu = NAN; points[1].memory = 0; points[2].delay = -1;
    assert(SGPerfSummarize(points, 30).count == 27);
    assert(SGPerfSummarize(points, 0).count == 0);
    puts("PASS: percentile, bounded window, invalid counters, relative/absolute regression limits");
}
