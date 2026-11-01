// review 4: u/u13_typeof_unevaluated.zig
// A019: a call inside @TypeOf is never run, yet its fill counts as writing the local.
fn fill(p: *[4]u8) void {
    p.* = .{ 1, 2, 3, 4 };
}
pub fn main() u8 {
    var buf: [4]u8 = undefined;
    const T = @TypeOf(fill(&buf));
    if (T != void) return 0;
    return buf[3];
}
