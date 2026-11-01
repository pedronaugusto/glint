// matrix A007: an inline for over the cells a dependency makes: each unrolled variable holds std's atomic.Value.
const dep = @import("dep.zig");
pub fn total() u64 {
    var sum: u64 = 0;
    inline for (.{ dep.Cell(u32), dep.Cell(u64) }) |Cell| {
        var hits: Cell = .init(1);
        sum += hits.fetchAdd(1, .monotonic);
    }
    return sum;
}
