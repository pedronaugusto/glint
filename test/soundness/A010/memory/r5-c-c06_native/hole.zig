// review 5: c/c06_native.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const bytes = try r.takeArray(8);
    var x: u64 = 0;
    @memcpy(std.mem.asBytes(&x), bytes);
    return x * 2;
}
