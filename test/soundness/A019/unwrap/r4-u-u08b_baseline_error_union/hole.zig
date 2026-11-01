// review 4: u/u08b_baseline_error_union.zig
// baseline: the same callee returning an error union, its failure swallowed (expected flagged)
fn fill(p: *[4]u8, c: bool) !void {
    if (c) return error.Skipped;
    p.* = .{ 1, 2, 3, 4 };
}
pub fn main(c: bool) u8 {
    var buf: [4]u8 = undefined;
    fill(&buf, c) catch {};
    return buf[3];
}
