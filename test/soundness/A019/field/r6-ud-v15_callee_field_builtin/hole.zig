// review 6: ud/v15_callee_field_builtin.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
// The callee gives a field undefined through @field.
fn kill(w: *W) void {
    @field(w, "data") = undefined;
}
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    kill(&w);
    return w.data[0];
}
