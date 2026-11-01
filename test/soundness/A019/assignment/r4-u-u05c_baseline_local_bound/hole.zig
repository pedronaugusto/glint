// review 4: u/u05c_baseline_local_bound.zig
// baseline: the bound is a local reassigned by name (expected flagged)
fn fill(p: []u8, k: usize, src: []const u8) []u8 {
    var n = k;
    @memcpy(p[0..n], src[0..n]);
    n += 4;
    return p[0..n];
}
pub fn main(src: []const u8) u8 {
    var buf: [16]u8 = undefined;
    const s = fill(&buf, 4, src);
    return s[7];
}
