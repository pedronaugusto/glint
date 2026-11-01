// review 5: a20/c18_callee_leaves.zig
const std = @import("std");
fn tick(io: std.Io, x: bool) !void {
    if (x) return;
    try io.checkCancel();
}
pub fn spin(io: std.Io, x: bool) !void {
    var n: u64 = 0;
    while (true) {
        try tick(io, x);
        n +%= 1;
    }
}
