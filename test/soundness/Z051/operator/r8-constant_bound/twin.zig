// Z051 (review 8, m11): the bound is a constant a u8 holds: the counter never overflows.
const n: usize = 10;
pub fn sum(xs: *const [10]u32) u32 {
    var total: u32 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) total +%= xs[i];
    return total;
}
