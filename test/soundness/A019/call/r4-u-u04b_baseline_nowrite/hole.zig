// review 4: u/u04b_baseline_nowrite.zig
// baseline: the callee hands the part on without writing it at all (expected flagged at the caller)
fn sink(s: []const u8) u8 {
    return s[0];
}
fn fill(p: *[8]u8) u8 {
    return sink(p[0..4]);
}
pub fn main() u8 {
    var buf: [8]u8 = undefined;
    return fill(&buf);
}
