// review 5: a19/st01_memset_undefined.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
pub fn s() void {
    var out: [32]u8 = undefined;
    for (0..4) |i| @memset(out[8 * i ..][0..8], undefined);
    use(&out);
}
