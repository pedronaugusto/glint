// review 5: a19/st01b_memset_undefined_whole.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
pub fn s() void {
    var out: [32]u8 = undefined;
    @memset(out[0..32], undefined);
    use(&out);
}
