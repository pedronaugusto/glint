// An import of the case's, not selected: one function loops on a predicate of another file, one does not loop.
const v = @import("v.zig");
pub fn spin(n: u64) u64 {
    var i: u64 = 0;
    var sum: u64 = 0;
    while (v.below(i, n)) : (i += 1) sum +%= i;
    return sum;
}
pub fn idle(n: u64) u64 {
    return n;
}
