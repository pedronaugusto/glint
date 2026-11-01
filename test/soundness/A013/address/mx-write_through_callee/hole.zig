// matrix: a callee writes input through the pointer it is given, the local then asserted
const std = @import("std");
fn fill(out: *u8, r: *std.Io.Reader) !void {
    out.* = try r.takeByte();
}
pub fn f(r: *std.Io.Reader) !u8 {
    var kind: u8 = 0;
    try fill(&kind, r);
    std.debug.assert(kind < 4);
    return kind;
}
