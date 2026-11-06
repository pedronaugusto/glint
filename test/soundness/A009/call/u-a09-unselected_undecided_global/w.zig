// An import of the case's, not selected: a loop bounded through a predicate of another file by a container-level variable.
const v = @import("v.zig");
pub var limit: u64 = 0;
pub fn spin(n: u64) u64 {
    _ = n;
    var i: u64 = 0;
    var sum: u64 = 0;
    while (v.below(i, limit)) : (i += 1) sum +%= i;
    return sum;
}
